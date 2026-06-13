import Foundation

/// User-editable settings. Lives at ~/.config/llm-usage-bar/config.json.
/// The Codex side reads official rate limits and needs none of this; the
/// Claude side has no official % on disk, so the budgets here are the
/// denominators used to turn local token counts into a percentage.
struct Config: Codable {
    /// Token budget for Claude's 5-hour rolling session window (in *weighted*
    /// tokens, see weights below). Calibrate against Claude Code's /usage.
    var claudeFiveHourTokenBudget: Double = 20_000_000

    /// Token budget for Claude's weekly (7-day) window. 0 disables the weekly row.
    var claudeWeeklyTokenBudget: Double = 500_000_000

    /// Per-component token weights. cache_read is cheap (~0.1x) and otherwise
    /// dwarfs everything, so it is down-weighted by default. Tune to make the
    /// percentage track what Claude Code's /usage reports for your plan.
    var claudeWeightInput: Double = 1.0
    var claudeWeightCacheCreation: Double = 1.0
    var claudeWeightCacheRead: Double = 0.1
    var claudeWeightOutput: Double = 1.0

    /// Optional weekly reset anchor so we can show a real countdown:
    /// ISO weekday (1=Mon ... 7=Sun) + hour (0-23), local time. nil => rolling 7d, no countdown.
    var claudeWeeklyResetWeekday: Int? = nil
    var claudeWeeklyResetHour: Int? = nil

    /// How often to refresh, seconds.
    var refreshSeconds: Double = 60

    static let path: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/llm-usage-bar", isDirectory: true)
        return dir.appendingPathComponent("config.json")
    }()

    static func load() -> Config {
        let url = Config.path
        guard let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(Config.self, from: data) else {
            let def = Config()
            def.save()  // write defaults so the user has something to edit
            return def
        }
        return cfg
    }

    func save() {
        let url = Config.path
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) { try? data.write(to: url) }
    }
}
