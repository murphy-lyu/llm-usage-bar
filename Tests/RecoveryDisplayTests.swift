import Foundation

// Compile with Models, Config, CodexReader, and CodexAppServerClient.
@main
struct RecoveryDisplayTests {
    static func main() {
        let now = Date()
        let soon = now.addingTimeInterval(60)
        let later = now.addingTimeInterval(7 * 86400)
        var provider = ProviderUsage(name: "Codex", short: "CX", available: true, windows: [
            UsageWindow(kind: .fiveHour, label: "5h", percent: 81, resetAt: soon),
            UsageWindow(kind: .weekly, label: "Weekly", percent: 50, resetAt: later)
        ])
        assert(provider.menuBarValue(for: .fiveHour, percentMode: .remaining) == "5h · 19%")
        assert(provider.menuBarValue(for: .fiveHour, percentMode: .used) == "5h · 81%")
        provider.windows[0].percent = 100
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate(
            Calendar.autoupdatingCurrent.isDateInToday(soon) ? "jm" : "Md")
        let expected = "5h ↻ \(formatter.string(from: soon))"
        assert(provider.menuBarValue(for: .weekly, percentMode: .used) == expected)
        assert(provider.menuBarValue(for: .fiveHour, percentMode: .remaining) == expected)
        provider.windows[1].percent = 100
        assert(provider.recoveryWindow(now: now)?.kind == .weekly)
        formatter.setLocalizedDateFormatFromTemplate("Md")
        assert(provider.menuBarValue(for: .fiveHour, percentMode: .remaining)
               == "W ↻ \(formatter.string(from: later))")
        provider.windows[1].resetAt = nil
        assert(provider.recoveryWindow(now: now)?.kind == .fiveHour)
        provider.windows[0].resetAt = now.addingTimeInterval(-60)
        assert(provider.recoveryWindow(now: now) == nil)
        provider.windows[0].resetAt = soon
        provider.windows[0].rolling = true
        assert(provider.recoveryWindow(now: now) == nil)
        provider.quotas = [
            UsageQuota(id: "selected", name: "Selected", shortName: "S", windows: []),
            UsageQuota(id: "other", name: "Other", shortName: "O", windows: [
                UsageWindow(kind: .weekly, label: "Weekly", percent: 100, resetAt: later)
            ])
        ]
        assert(provider.recoveryWindow(quotaID: "selected", now: now) == nil)
        print("Recovery display tests passed (\(Locale.current.identifier)).")
    }
}
