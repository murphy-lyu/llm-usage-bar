import Foundation

struct CodexAccountWindowRecord: Codable, Equatable {
    var kind: UsageWindowKind
    var durationMinutes: Double?
    var usedPercent: Double
    var resetAt: Date?
}

struct CodexAccountRecord: Codable, Equatable {
    var id: String
    var email: String?
    var planType: String?
    var windows: [CodexAccountWindowRecord]
    var updatedAt: Date

    init?(snapshot: CodexRateLimitSnapshot) {
        let email = snapshot.accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedEmail = email.flatMap { $0.isEmpty ? nil : $0.lowercased() }
        guard let id = snapshot.accountID ?? normalizedEmail.map({ "email:\($0)" }) else {
            return nil
        }

        let group = snapshot.groups.first(where: { $0.id == "codex" }) ?? snapshot.groups.first
        guard let group else { return nil }
        self.id = id
        self.email = email
        self.planType = snapshot.accountPlanType ?? group.planType
        self.windows = [group.primary, group.secondary].compactMap { window in
            guard let window else { return nil }
            return CodexAccountWindowRecord(
                kind: Self.windowKind(minutes: window.windowMinutes),
                durationMinutes: window.windowMinutes,
                usedPercent: window.usedPercent,
                resetAt: window.resetAt
            )
        }
        self.updatedAt = snapshot.fetchedAt
    }

    var normalizedEmail: String? {
        email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func windowKind(minutes: Double?) -> UsageWindowKind {
        guard let minutes else { return .custom }
        switch Int(minutes.rounded()) {
        case 300: return .fiveHour
        case 1_440: return .daily
        case 10_080: return .weekly
        case 43_200, 44_640: return .monthly
        default: return .custom
        }
    }
}

enum CodexAccountHistoryStore {
    static let inactivityVisibilityInterval: TimeInterval = 30 * 24 * 60 * 60

    private struct Archive: Codable {
        var version: Int = 1
        var accounts: [CodexAccountRecord]
    }

    private static let lock = NSLock()

    static var path: URL {
        if let override = ProcessInfo.processInfo.environment["ORB_ACCOUNT_HISTORY_PATH"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return Config.path.deletingLastPathComponent()
            .appendingPathComponent("codex-accounts.json")
    }

    static func accounts(now: Date = Date()) -> [CodexAccountRecord] {
        lock.lock()
        defer { lock.unlock() }
        return readUnlocked(from: path).filter {
            now.timeIntervalSince($0.updatedAt) <= inactivityVisibilityInterval
        }
    }

    @discardableResult
    static func record(_ snapshot: CodexRateLimitSnapshot) -> CodexAccountRecord? {
        guard let incoming = CodexAccountRecord(snapshot: snapshot) else { return nil }
        lock.lock()
        defer { lock.unlock() }

        var records = readUnlocked(from: path)
        records.removeAll { existing in
            if existing.id == incoming.id { return true }
            // Email is only a fallback identity for older app-server builds
            // that omit accountId. Distinct workspaces can legitimately share
            // one email address, so never merge two real account IDs by email.
            let usesEmailFallback = existing.id.hasPrefix("email:")
                || incoming.id.hasPrefix("email:")
            return usesEmailFallback
                && incoming.normalizedEmail != nil
                && existing.normalizedEmail == incoming.normalizedEmail
        }
        records.append(incoming)
        records.sort { $0.updatedAt > $1.updatedAt }
        records = Array(records.prefix(20))
        writeUnlocked(records, to: path)
        return incoming
    }

    private static func readUnlocked(from url: URL) -> [CodexAccountRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let archive = try? decoder.decode(Archive.self, from: data),
              archive.version == 1 else { return [] }
        return archive.accounts.sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func writeUnlocked(_ records: [CodexAccountRecord], to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(Archive(accounts: records))
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: url.path
            )
        } catch {
            // Usage refresh must remain available even if account history
            // cannot be persisted, for example on a read-only home folder.
        }
    }
}
