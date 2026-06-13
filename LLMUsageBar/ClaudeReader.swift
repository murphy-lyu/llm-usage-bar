import Foundation

/// Reads Claude Code transcripts (~/.claude/projects/*/*.jsonl) and derives
/// rolling-window usage. There is no official rate-limit % on disk, so we
/// aggregate token counts locally and divide by configurable budgets.
enum ClaudeReader {
    struct Entry { let time: Date; let tokens: Double }
    /// Raw per-message token components, before weighting. Cached per file so a
    /// weight change doesn't invalidate the cache.
    struct RawEntry { let time: Date; let input, output, cacheCreate, cacheRead: Double }

    private struct FileCache { let mtime: Date; let entries: [RawEntry] }
    private static var cache: [String: FileCache] = [:]

    static let projectsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects", isDirectory: true)

    static func read(config: Config) -> ProviderUsage {
        let entries = loadEntries(config: config)
        guard !entries.isEmpty else {
            return ProviderUsage(name: "Claude Code", short: "CC", available: false,
                                 windows: [], note: "未找到 ~/.claude/projects 数据")
        }
        let now = Date()
        var windows: [UsageWindow] = []

        // ---- 5-hour rolling session block (reset accurate, % is an estimate) ----
        if let block = activeFiveHourBlock(entries, now: now) {
            let pct = config.claudeFiveHourTokenBudget > 0
                ? block.tokens / config.claudeFiveHourTokenBudget * 100 : nil
            windows.append(UsageWindow(
                label: "5 小时额度",
                percent: pct,
                resetAt: block.start.addingTimeInterval(5 * 3600),
                detail: tokenStr(block.tokens),  // not shown in menu; --once uses it for calibration
                estimate: true))
        } else {
            windows.append(UsageWindow(
                label: "5 小时额度", percent: 0, resetAt: nil, estimate: true))
        }

        // ---- Weekly (7-day) window ----
        if config.claudeWeeklyTokenBudget > 0 {
            let (used, resetAt, rolling) = weeklyUsage(entries, now: now, config: config)
            let pct = used / config.claudeWeeklyTokenBudget * 100
            windows.append(UsageWindow(
                label: "周额度 · 所有模型",
                percent: pct, resetAt: resetAt,
                detail: tokenStr(used),  // not shown in menu; --once uses it for calibration
                rolling: rolling, estimate: true))
        }

        return ProviderUsage(name: "Claude Code", short: "CC", available: true,
                             windows: windows, note: nil, lastActivity: entries.last?.time)
    }

    // MARK: - parsing

    private static let pInput = Data("\"input_tokens\":".utf8)

    private static func loadEntries(config: Config) -> [Entry] {
        guard let projects = try? FileManager.default.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: nil) else { return [] }
        var files: [URL] = []
        for p in projects {
            if let fs = try? FileManager.default.contentsOfDirectory(
                at: p, includingPropertiesForKeys: [.contentModificationDateKey]) {
                files += fs.filter { $0.pathExtension == "jsonl" }
            }
        }
        // Only files touched in the last 8 days matter for 5h + weekly windows.
        let cutoff = Date().addingTimeInterval(-8 * 86400)
        var raws: [RawEntry] = []
        var livePaths = Set<String>()

        for file in files {
            let mod = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if mod < cutoff { continue }
            let path = file.path
            livePaths.insert(path)
            // Reuse cached parse if the file hasn't changed since last refresh —
            // historical transcripts (tens of MB) are then parsed only once.
            if let c = cache[path], c.mtime == mod {
                raws += c.entries
            } else {
                let parsed = parseFile(file)
                cache[path] = FileCache(mtime: mod, entries: parsed)
                raws += parsed
            }
        }
        // Drop cache entries for files that rolled out of the window.
        cache.keys.filter { !livePaths.contains($0) }.forEach { cache.removeValue(forKey: $0) }

        return raws
            .filter { $0.time >= cutoff }
            .map { Entry(time: $0.time, tokens:
                $0.input * config.claudeWeightInput
                + $0.output * config.claudeWeightOutput
                + $0.cacheCreate * config.claudeWeightCacheCreation
                + $0.cacheRead * config.claudeWeightCacheRead) }
            .filter { $0.tokens > 0 }
            .sorted { $0.time < $1.time }
    }

    /// Parse one transcript by scanning raw UTF-8 bytes. Swift `String` search is
    /// Unicode-aware and far too slow on multi-MB files, so we split on newline
    /// bytes and only decode the few lines that actually carry token usage.
    private static func parseFile(_ file: URL) -> [RawEntry] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()
        isoNoFrac.formatOptions = [.withInternetDateTime]
        var out: [RawEntry] = []
        for slice in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard slice.range(of: pInput) != nil else { continue }  // byte search — fast
            let line = Substring(String(decoding: slice, as: UTF8.self))
            guard let ts = scanString(line, "\"timestamp\":\""),
                  let time = iso.date(from: ts) ?? isoNoFrac.date(from: ts) else { continue }
            // First occurrence of each key is the top-level usage value
            // (later duplicates live inside "iterations").
            out.append(RawEntry(
                time: time,
                input: scanInt(line, "\"input_tokens\":"),
                output: scanInt(line, "\"output_tokens\":"),
                cacheCreate: scanInt(line, "\"cache_creation_input_tokens\":"),
                cacheRead: scanInt(line, "\"cache_read_input_tokens\":")))
        }
        return out
    }

    /// Integer value following the first occurrence of `key` (e.g. `"output_tokens":`).
    private static func scanInt(_ line: Substring, _ key: String) -> Double {
        guard let r = line.range(of: key) else { return 0 }
        var i = r.upperBound
        while i < line.endIndex, !(line[i].isNumber || line[i] == "-") { i = line.index(after: i) }
        var j = i
        while j < line.endIndex, line[j].isNumber { j = line.index(after: j) }
        return i < j ? (Double(line[i..<j]) ?? 0) : 0
    }

    /// String value after `key` (which must end at the opening quote), up to the next quote.
    private static func scanString(_ line: Substring, _ key: String) -> String? {
        guard let r = line.range(of: key) else { return nil }
        guard let end = line[r.upperBound...].firstIndex(of: "\"") else { return nil }
        return String(line[r.upperBound..<end])
    }

    private static func num(_ v: Any?) -> Double {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        return 0
    }

    // MARK: - windows

    struct Block { let start: Date; let tokens: Double; let lastActivity: Date }

    /// ccusage-style 5h blocks; returns the block covering `now` if still active.
    private static func activeFiveHourBlock(_ entries: [Entry], now: Date) -> Block? {
        let five: TimeInterval = 5 * 3600
        var blockStart: Date? = nil
        var lastTime: Date? = nil
        var tokens = 0.0
        var blocks: [Block] = []

        func floorHour(_ d: Date) -> Date {
            let c = Calendar.current.dateComponents([.year, .month, .day, .hour], from: d)
            return Calendar.current.date(from: c) ?? d
        }
        func flush() {
            if let s = blockStart, let l = lastTime {
                blocks.append(Block(start: s, tokens: tokens, lastActivity: l))
            }
        }
        for e in entries {
            if let s = blockStart, let l = lastTime {
                if e.time.timeIntervalSince(s) >= five || e.time.timeIntervalSince(l) >= five {
                    flush(); blockStart = floorHour(e.time); tokens = 0
                }
            } else {
                blockStart = floorHour(e.time)
            }
            tokens += e.tokens
            lastTime = e.time
        }
        flush()

        guard let last = blocks.last else { return nil }
        // Active only if the 5h window from its start still contains `now`.
        if now.timeIntervalSince(last.start) < five { return last }
        return nil
    }

    private static func weeklyUsage(_ entries: [Entry], now: Date, config: Config)
        -> (used: Double, resetAt: Date?, rolling: Bool) {
        if let wd = config.claudeWeeklyResetWeekday, let hr = config.claudeWeeklyResetHour,
           let (start, end) = weekWindow(weekday: wd, hour: hr, now: now) {
            let used = entries.filter { $0.time >= start && $0.time < end }
                .reduce(0) { $0 + $1.tokens }
            return (used, end, false)
        }
        // Rolling 7-day: no meaningful reset countdown.
        let start = now.addingTimeInterval(-7 * 86400)
        let used = entries.filter { $0.time >= start }.reduce(0) { $0 + $1.tokens }
        return (used, nil, true)
    }

    /// Current [start, end) for a weekly anchor at the given ISO weekday/hour.
    private static func weekWindow(weekday: Int, hour: Int, now: Date) -> (Date, Date)? {
        var cal = Calendar.current
        cal.firstWeekday = 2 // Monday
        // Calendar weekday: 1=Sun..7=Sat. ISO 1=Mon..7=Sun -> map.
        let calWeekday = weekday == 7 ? 1 : weekday + 1
        var comps = DateComponents()
        comps.weekday = calWeekday
        comps.hour = hour; comps.minute = 0; comps.second = 0
        // Most recent past occurrence of the anchor.
        guard let next = cal.nextDate(after: now, matching: comps,
                                      matchingPolicy: .nextTime, direction: .forward)
        else { return nil }
        let start = next.addingTimeInterval(-7 * 86400)
        return (start, next)
    }

    private static func tokenStr(_ t: Double) -> String {
        if t >= 1_000_000 { return String(format: "%.1fM tokens", t / 1_000_000) }
        if t >= 1_000 { return String(format: "%.0fK tokens", t / 1_000) }
        return String(format: "%.0f tokens", t)
    }
}
