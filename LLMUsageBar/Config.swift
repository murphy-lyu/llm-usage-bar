import Foundation

/// User-editable settings. Lives at ~/.config/llm-usage-bar/config.json.
/// The Codex side reads official rate limits and needs none of this; the
/// Claude side has no official % on disk, so the budgets here are the
/// denominators used to turn local token counts into a percentage.
struct Config: Codable {
    /// Token budget for Claude's 5-hour rolling session window (in *weighted*
    /// tokens, see weights below). Default calibrated against an observed /usage
    /// reading (official 23% at ~21.6M weighted). Recalibrate:
    /// budget = your_weighted_tokens / (official_percent / 100).
    var claudeFiveHourTokenBudget: Double = 94_000_000

    /// Token budget for Claude's weekly (7-day) window. 0 disables the weekly row.
    /// Calibrated from an observed /usage reading (official 3% at ~383M weighted).
    var claudeWeeklyTokenBudget: Double = 12_800_000_000

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

    /// Which provider the menu bar shows: "auto" (the most recently used one),
    /// "claude", or "codex". The dropdown always lists every provider in full.
    var menuBarMode: String = "auto"

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
