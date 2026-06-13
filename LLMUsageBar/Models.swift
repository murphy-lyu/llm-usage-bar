import Foundation

/// One usage window we want to show in the menu bar (a 5h block, a weekly/30d limit, etc.)
struct UsageWindow {
    var label: String          // e.g. "5 小时额度", "周额度 · 所有模型"
    var percent: Double?       // 0...100, nil if unknown
    var resetAt: Date?         // when this window resets, nil if rolling/unknown
    var detail: String?        // extra small text (rarely shown)
    var rolling: Bool = false  // true => no hard reset
    var estimate: Bool = false // true => % is a local estimate, not official

    /// Percent clamped to 0...100 for display; falls back to 0.
    var pct: Double { max(0, min(100, percent ?? 0)) }
}

/// Everything we know about one provider (Claude Code / Codex).
struct ProviderUsage {
    var name: String           // "Claude Code", "Codex"
    var short: String          // "CC", "CX" — menu bar abbreviation
    var available: Bool        // did we find any data at all
    var windows: [UsageWindow]
    var note: String?          // e.g. data source path or a caveat
    var lastActivity: Date?    // newest activity timestamp — drives "currently in use"

    /// The single most "urgent" percent — drives the menu bar. Windows with a
    /// real reset (5h, official limits) are preferred over rolling estimates so
    /// a guessed rolling budget can't skew the headline.
    var headlinePercent: Double? {
        let fixed = windows.filter { !$0.rolling }.compactMap { $0.percent }
        if let m = fixed.max() { return m }
        return windows.compactMap { $0.percent }.max()
    }

    /// Compact value for the menu bar: "88%" when we have a percent, else a
    /// token count like "8.6M" so the bar is never blank, else "–".
    var menuBarValue: String {
        if let p = headlinePercent { return "\(Int(p.rounded()))%" }
        if let d = windows.first(where: { $0.detail != nil })?.detail {
            return d.replacingOccurrences(of: " tokens", with: "")
        }
        return "–"
    }
}

extension Date {
    /// Human countdown like "2h13m" / "21d 4h" / "8m". Negative => "现在".
    func countdownString(from now: Date = Date()) -> String {
        let s = Int(self.timeIntervalSince(now))
        if s <= 0 { return "现在" }
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h\(m)m" }
        return "\(m)m"
    }

    /// Coarse countdown matching Claude's /usage style: "2h" / "2d" / "8m".
    func coarseCountdown(from now: Date = Date()) -> String {
        let s = Int(self.timeIntervalSince(now))
        if s <= 0 { return "现在" }
        if s >= 86400 { return "\(Int((Double(s) / 86400).rounded()))d" }
        if s >= 3600 { return "\(Int((Double(s) / 3600).rounded()))h" }
        return "\(max(1, s / 60))m"
    }
}

extension Double {
    /// 10-segment text progress bar: "██████░░░░"
    func progressBar(width: Int = 10) -> String {
        let filled = Int((max(0, min(100, self)) / 100 * Double(width)).rounded())
        return String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
    }
}
