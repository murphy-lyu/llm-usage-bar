import Foundation

extension String {
    var l10n: String { NSLocalizedString(self, comment: "") }
}

enum UsageProviderID: String, Codable, CaseIterable, Identifiable {
    case codex
    case claude
    case gemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        }
    }

    var shortName: String {
        switch self {
        case .codex: return "CX"
        case .claude: return "CL"
        case .gemini: return "GM"
        }
    }
}

protocol UsageProviderAdapter {
    var providerID: UsageProviderID { get }
    func read(config: Config, overrideFile: URL?) -> ProviderUsage
}

extension UsageProviderAdapter {
    func read(config: Config) -> ProviderUsage {
        read(config: config, overrideFile: nil)
    }
}

enum UsageProviderRegistry {
    static func adapter(for id: UsageProviderID) -> UsageProviderAdapter {
        switch id {
        case .codex:
            return CodexUsageProvider()
        case .claude, .gemini:
            return UnsupportedUsageProvider(providerID: id)
        }
    }
}

private struct UnsupportedUsageProvider: UsageProviderAdapter {
    let providerID: UsageProviderID

    func read(config: Config, overrideFile: URL?) -> ProviderUsage {
        ProviderUsage(providerID: providerID,
                      name: providerID.displayName,
                      short: providerID.shortName,
                      available: false,
                      windows: [],
                      note: "provider.unsupported".l10n)
    }
}

enum UsageWindowKind: String {
    case fiveHour
    case daily
    case weekly
    case monthly
    case custom
    case session
}

/// One usage window we want to show in the menu bar (a 5h block, a weekly/30d limit, etc.)
struct UsageWindow {
    var kind: UsageWindowKind = .custom
    var label: String          // e.g. "5-hour limit", "Weekly limit"
    var percent: Double?       // 0...100, nil if unknown
    var resetAt: Date?         // when this window resets, nil if rolling/unknown
    var detail: String?        // extra small text (rarely shown)
    var rolling: Bool = false  // true => no hard reset
    var estimate: Bool = false // true => % is a local estimate, not official

    /// Percent clamped to 0...100 for display; falls back to 0.
    var pct: Double { max(0, min(100, percent ?? 0)) }

    func displayPercent(for mode: Config.PercentDisplayMode) -> Double {
        switch mode {
        case .used: return pct
        case .remaining: return 100 - pct
        }
    }
}

/// One official allowance bucket within a provider. Codex can expose a
/// general allowance and additional model-specific buckets, each with its own
/// reset windows. `id` is the server's stable limit_id and is persisted in
/// Config so Orb never silently switches what the menu bar represents.
struct UsageQuota {
    var id: String
    var name: String
    var shortName: String
    var windows: [UsageWindow]
}

struct UsageCredits {
    var balance: String?
    var hasCredits: Bool
    var unlimited: Bool

    var shouldDisplay: Bool { unlimited || hasCredits }
}

/// Everything we know about one provider (Claude Code / Codex).
struct ProviderUsage {
    var providerID: UsageProviderID = .codex
    var name: String           // "Claude Code", "Codex"
    var short: String          // "CC", "CX" — menu bar abbreviation
    var available: Bool        // did we find any data at all
    var windows: [UsageWindow]
    var quotas: [UsageQuota] = []
    var note: String?          // e.g. data source path or a caveat
    var lastActivity: Date?    // newest activity timestamp — drives "currently in use"
    var sourceFile: URL?
    var plan: String?          // e.g. "Plus" — shown as auxiliary text in the header row
    var credits: UsageCredits?
    var resetCreditsAvailable: Int = 0

    var effectiveQuotas: [UsageQuota] {
        if !quotas.isEmpty { return quotas }
        return [UsageQuota(id: providerID.rawValue, name: name, shortName: name, windows: windows)]
    }

    func selectedQuota(preferredID: String?) -> UsageQuota {
        let available = effectiveQuotas
        if let preferredID, let selected = available.first(where: { $0.id == preferredID }) {
            return selected
        }
        return available.first(where: { $0.id == providerID.rawValue }) ?? available[0]
    }

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

    func availableDisplayModes(quotaID: String? = nil) -> [Config.MenuBarDisplayMode] {
        let quotaWindows = selectedQuota(preferredID: quotaID).windows
        var modes: [Config.MenuBarDisplayMode] = []
        if quotaWindows.contains(where: { $0.kind == .weekly }) { modes.append(.weekly) }
        if quotaWindows.contains(where: { $0.kind == .fiveHour }) { modes.append(.fiveHour) }
        let fixedWindows = quotaWindows.filter { !$0.rolling && $0.percent != nil }
        if fixedWindows.count > 1 { modes.append(.highest) }
        if modes.isEmpty { modes.append(.highest) }
        return modes
    }

    func effectiveDisplayMode(for preferred: Config.MenuBarDisplayMode,
                              quotaID: String? = nil) -> Config.MenuBarDisplayMode {
        let modes = availableDisplayModes(quotaID: quotaID)
        if modes.contains(preferred) { return preferred }
        if modes.contains(.weekly) { return .weekly }
        if modes.contains(.fiveHour) { return .fiveHour }
        return .highest
    }

    func window(for mode: Config.MenuBarDisplayMode, quotaID: String? = nil) -> UsageWindow? {
        let quotaWindows = selectedQuota(preferredID: quotaID).windows
        switch mode {
        case .highest:
            return quotaWindows.filter { !$0.rolling }.max { $0.pct < $1.pct }
                ?? quotaWindows.max { $0.pct < $1.pct }
        case .fiveHour:
            return quotaWindows.first { $0.kind == .fiveHour }
        case .weekly:
            return quotaWindows.first { $0.kind == .weekly }
        }
    }

    func menuBarValue(for mode: Config.MenuBarDisplayMode) -> String {
        menuBarValue(for: mode, percentMode: .used)
    }

    func menuBarValue(for mode: Config.MenuBarDisplayMode,
                      percentMode: Config.PercentDisplayMode,
                      quotaID: String? = nil) -> String {
        let mode = effectiveDisplayMode(for: mode, quotaID: quotaID)
        guard let w = window(for: mode, quotaID: quotaID) else { return menuBarValue }
        if let p = w.percent {
            let display = percentMode == .remaining ? 100 - p : p
            let text = "\(Int(display.rounded()))%"
            return "\(w.menuBarPrefix) \(text)"
        }
        return menuBarValue
    }

}

private extension UsageWindow {
    var menuBarPrefix: String {
        switch kind {
        case .fiveHour: return "5h"
        case .weekly: return "W"
        case .daily: return "D"
        case .monthly: return "30d"
        default: return label
        }
    }
}

extension Date {
    /// Human countdown like "2h13m" / "21d 4h" / "8m".
    func countdownString(from now: Date = Date()) -> String {
        let s = Int(self.timeIntervalSince(now))
        if s <= 0 { return "time.now".l10n }
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h\(m)m" }
        return "\(m)m"
    }

    /// Coarse countdown matching Claude's /usage style: "2h" / "2d" / "8m".
    func coarseCountdown(from now: Date = Date()) -> String {
        let s = Int(self.timeIntervalSince(now))
        if s <= 0 { return "time.now".l10n }
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
