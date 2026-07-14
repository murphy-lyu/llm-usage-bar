import Foundation

/// User-editable settings. Lives at ~/.config/llm-usage-bar/config.json.
/// Codex reports official rate limits directly, so there's little to tune here.
struct Config: Codable {
    /// How often to refresh, seconds.
    var refreshSeconds: Double = 60
    var providerID: UsageProviderID = .codex
    var menuBarDisplayMode: MenuBarDisplayMode = .weekly
    var percentDisplayMode: PercentDisplayMode = .remaining
    var thresholdAlertsEnabled: Bool = true
    var warningThreshold: Double = 80
    var criticalThreshold: Double = 95

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        refreshSeconds = try c.decodeIfPresent(Double.self, forKey: .refreshSeconds) ?? 60
        providerID = try c.decodeIfPresent(UsageProviderID.self, forKey: .providerID) ?? .codex
        menuBarDisplayMode = try c.decodeIfPresent(MenuBarDisplayMode.self, forKey: .menuBarDisplayMode) ?? .weekly
        percentDisplayMode = try c.decodeIfPresent(PercentDisplayMode.self, forKey: .percentDisplayMode) ?? .remaining
        thresholdAlertsEnabled = try c.decodeIfPresent(Bool.self, forKey: .thresholdAlertsEnabled) ?? true
        warningThreshold = try c.decodeIfPresent(Double.self, forKey: .warningThreshold) ?? 80
        criticalThreshold = try c.decodeIfPresent(Double.self, forKey: .criticalThreshold) ?? 95
    }

    enum MenuBarDisplayMode: String, Codable, CaseIterable, Identifiable {
        case fiveHour
        case weekly
        case highest

        var id: String { rawValue }
        static var settingsCases: [MenuBarDisplayMode] { [.weekly, .highest] }

        var titleKey: String {
            switch self {
            case .fiveHour: return "settings.menuBarMode.fiveHour"
            case .weekly: return "settings.menuBarMode.weekly"
            case .highest: return "settings.menuBarMode.highest"
            }
        }
    }

    enum PercentDisplayMode: String, Codable, CaseIterable, Identifiable {
        case remaining
        case used

        var id: String { rawValue }

        var titleKey: String {
            switch self {
            case .remaining: return "settings.percentMode.remaining"
            case .used: return "settings.percentMode.used"
            }
        }
    }

    static let path: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/llm-usage-bar", isDirectory: true)
        return dir.appendingPathComponent("config.json")
    }()

    static func load() -> Config {
        let url = Config.path
        guard let data = try? Data(contentsOf: url),
              var cfg = try? JSONDecoder().decode(Config.self, from: data) else {
            let def = Config()
            def.save()  // write defaults so the user has something to edit
            return def
        }
        if cfg.providerID == .codex && cfg.menuBarDisplayMode == .fiveHour {
            cfg.menuBarDisplayMode = .weekly
            cfg.save()
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
