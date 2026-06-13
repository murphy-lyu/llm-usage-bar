import Foundation

/// Reads Codex session rollouts (~/.codex/sessions/YYYY/MM/DD/*.jsonl).
/// Codex persists OFFICIAL rate limits in `token_count` events
/// (rate_limits.primary/secondary = {used_percent, window_minutes, resets_at}),
/// so we surface those directly — no estimation needed. When the provider
/// returns null limits (custom/relay providers), we fall back to token totals.
enum CodexReader {
    static let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions", isDirectory: true)

    static func read(config: Config, overrideFile: URL? = nil) -> ProviderUsage {
        guard let file = overrideFile ?? newestSessionFile() else {
            return ProviderUsage(name: "Codex", short: "CX", available: false,
                                 windows: [], note: "未找到 ~/.codex/sessions 数据")
        }
        guard let latest = latestTokenCount(in: file) else {
            return ProviderUsage(name: "Codex", short: "CX", available: false,
                                 windows: [], note: "会话中暂无 token 用量事件")
        }

        var windows: [UsageWindow] = []
        for (key, label) in [("primary", "主额度"), ("secondary", "次额度")] {
            guard let rl = latest.rateLimits?[key] as? [String: Any],
                  let pct = num(rl["used_percent"]) else { continue }
            let win = num(rl["window_minutes"])
            let reset = num(rl["resets_at"]).map { Date(timeIntervalSince1970: $0) }
            windows.append(UsageWindow(
                label: windowLabel(minutes: win, fallback: label),
                percent: pct, resetAt: reset, detail: nil))
        }

        if windows.isEmpty {
            // Provider didn't report limits — show local token total as a fallback.
            let detail = latest.totalTokens.map { tokenStr($0) } ?? "无官方额度数据"
            windows.append(UsageWindow(
                label: "本会话用量", percent: nil, resetAt: nil,
                detail: detail, rolling: true))
            return ProviderUsage(name: "Codex", short: "CX", available: true,
                                 windows: windows,
                                 note: "当前供应商未返回官方额度（rate_limits 为空）",
                                 lastActivity: latest.timestamp)
        }

        return ProviderUsage(name: "Codex", short: "CX", available: true,
                             windows: windows, note: nil, lastActivity: latest.timestamp)
    }

    private static func isoDate(_ s: String) -> Date? {
        let a = ISO8601DateFormatter(); a.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let b = ISO8601DateFormatter(); b.formatOptions = [.withInternetDateTime]
        return a.date(from: s) ?? b.date(from: s)
    }

    // MARK: - helpers

    private struct TokenInfo {
        var rateLimits: [String: Any]?
        var totalTokens: Double?
        var timestamp: Date?
    }

    /// Sessions are laid out as sessions/YYYY/MM/DD/*.jsonl. Descend to the
    /// newest day directory and pick the newest file there, instead of walking
    /// the entire tree (which can be thousands of files and stalls refresh).
    private static func newestSessionFile() -> URL? {
        let fm = FileManager.default
        func newestChildDir(_ dir: URL) -> URL? {
            guard let items = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
            return items
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
                .max { $0.lastPathComponent < $1.lastPathComponent }  // numeric names sort lexically
        }
        func mtime(_ u: URL) -> Date {
            (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
        }
        guard let year = newestChildDir(sessionsDir),
              let month = newestChildDir(year),
              let day = newestChildDir(month),
              let files = try? fm.contentsOfDirectory(
                at: day, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        return files.filter { $0.pathExtension == "jsonl" }.max { mtime($0) < mtime($1) }
    }

    /// Last `token_count` event in the file (chronological => last line wins).
    private static func latestTokenCount(in file: URL) -> TokenInfo? {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        var result: TokenInfo? = nil
        for line in content.split(separator: "\n") {
            guard line.contains("\"token_count\""),
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  (payload["type"] as? String) == "token_count" else { continue }
            var info = TokenInfo()
            info.rateLimits = payload["rate_limits"] as? [String: Any]
            if let i = payload["info"] as? [String: Any],
               let total = i["total_token_usage"] as? [String: Any] {
                info.totalTokens = num(total["total_tokens"])
            }
            if let ts = obj["timestamp"] as? String { info.timestamp = isoDate(ts) }
            result = info // keep overwriting; last one is newest
        }
        return result
    }

    private static func windowLabel(minutes: Double?, fallback: String) -> String {
        guard let m = minutes, m > 0 else { return fallback }
        switch Int(m) {
        case 43200: return "30天额度"
        case 10080: return "周额度"
        case 1440:  return "日额度"
        case 300:   return "5h窗口"
        default:
            if m >= 1440 { return "\(Int(m / 1440))天额度" }
            if m >= 60 { return "\(Int(m / 60))h窗口" }
            return "\(Int(m))分钟窗口"
        }
    }

    private static func num(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }

    private static func tokenStr(_ t: Double) -> String {
        if t >= 1_000_000 { return String(format: "%.1fM tokens", t / 1_000_000) }
        if t >= 1_000 { return String(format: "%.0fK tokens", t / 1_000) }
        return String(format: "%.0f tokens", t)
    }
}
