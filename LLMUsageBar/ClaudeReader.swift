import Foundation

/// Reads Claude Code transcripts (~/.claude/projects/*/*.jsonl) and derives
/// rolling-window usage. There is no official rate-limit % on disk, so we
/// aggregate token counts locally and divide by configurable budgets.
enum ClaudeReader {
    struct Entry { let time: Date; let tokens: Double }

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

        // ---- 5-hour rolling session block ----
        if let block = activeFiveHourBlock(entries, now: now) {
            let pct = config.claudeFiveHourTokenBudget > 0
                ? block.tokens / config.claudeFiveHourTokenBudget * 100 : nil
            windows.append(UsageWindow(
                label: "5h 会话窗口",
                percent: pct,
                resetAt: block.start.addingTimeInterval(5 * 3600),
                detail: tokenStr(block.tokens)))
        } else {
            windows.append(UsageWindow(
                label: "5h 会话窗口", percent: 0, resetAt: nil,
                detail: "当前空闲", rolling: false))
        }

        // ---- Weekly (7-day) window ----
        if config.claudeWeeklyTokenBudget > 0 {
            let (used, resetAt, rolling) = weeklyUsage(entries, now: now, config: config)
            let pct = used / config.claudeWeeklyTokenBudget * 100
            windows.append(UsageWindow(
                label: rolling ? "7天滚动用量" : "周额度",
                percent: pct, resetAt: resetAt,
                detail: tokenStr(used), rolling: rolling))
        }

        return ProviderUsage(name: "Claude Code", short: "CC", available: true,
                             windows: windows, note: nil, lastActivity: entries.last?.time)
    }

    // MARK: - parsing

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
        var entries: [Entry] = []
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()
        isoNoFrac.formatOptions = [.withInternetDateTime]

        for file in files {
            let mod = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if mod < cutoff { continue }
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in content.split(separator: "\n") {
                guard line.contains("\"usage\""),
                      let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let ts = obj["timestamp"] as? String,
                      let msg = obj["message"] as? [String: Any],
                      let usage = msg["usage"] as? [String: Any] else { continue }
                let time = iso.date(from: ts) ?? isoNoFrac.date(from: ts)
                guard let time, time >= cutoff else { continue }
                let tokens = num(usage["input_tokens"]) * config.claudeWeightInput
                    + num(usage["output_tokens"]) * config.claudeWeightOutput
                    + num(usage["cache_creation_input_tokens"]) * config.claudeWeightCacheCreation
                    + num(usage["cache_read_input_tokens"]) * config.claudeWeightCacheRead
                if tokens > 0 { entries.append(Entry(time: time, tokens: tokens)) }
            }
        }
        return entries.sorted { $0.time < $1.time }
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
