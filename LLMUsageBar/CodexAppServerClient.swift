import Foundation
import OSLog

struct CodexRateLimitWindow {
    var usedPercent: Double
    var windowMinutes: Double?
    var resetAt: Date?
}

struct CodexRateLimitGroup {
    var id: String
    var name: String?
    var primary: CodexRateLimitWindow?
    var secondary: CodexRateLimitWindow?
    var planType: String?
}

struct CodexCreditsSnapshot {
    var balance: String?
    var hasCredits: Bool
    var unlimited: Bool
}

struct CodexResetCreditSnapshot {
    var id: String
    var grantedAt: Date
    var expiresAt: Date?
    var title: String?
    var description: String?
}

struct CodexResetCreditsSnapshot {
    var availableCount: Int
    var credits: [CodexResetCreditSnapshot]?
}

struct CodexRateLimitSnapshot {
    var groups: [CodexRateLimitGroup]
    var credits: CodexCreditsSnapshot?
    var resetCredits: CodexResetCreditsSnapshot?
    var fetchedAt: Date
    var accountID: String?
    var accountEmail: String?
    var accountPlanType: String?
}

struct CodexAccountIdentity {
    var email: String?
    var planType: String?
}

/// Reads account-level limits through Codex's official local app-server API.
/// The app-server performs the authenticated account lookup, so usage from
/// another computer is visible without waiting for a local session write.
enum CodexAppServerClient {
    private static let logger = Logger(subsystem: "local.llmusagebar",
                                       category: "CodexAppServer")
    private static let connection = Connection()

    static func readRateLimits() -> CodexRateLimitSnapshot? {
        connection.readRateLimits()
    }

    static func invalidateConnection() {
        connection.invalidate()
    }

    static func setRateLimitsUpdateHandler(_ handler: (() -> Void)?) {
        connection.setRateLimitsUpdateHandler(handler)
    }

    /// Keeps one lightweight app-server process for Orb's lifetime. Starting a
    /// new server every minute also warms models and plugins every minute, so a
    /// persistent connection is both faster and substantially less wasteful.
    private final class Connection {
        private let lock = NSLock()
        private let handlerLock = NSLock()
        private var process: Process?
        private var inputHandle: FileHandle?
        private var reader: JSONLineResponseReader?
        private var nextRequestID = 2
        private var rateLimitsUpdateHandler: (() -> Void)?
        private var runningExecutable: ExecutableIdentity?
        private var runningAuthFile: FileIdentity?

        func setRateLimitsUpdateHandler(_ handler: (() -> Void)?) {
            handlerLock.lock()
            rateLimitsUpdateHandler = handler
            handlerLock.unlock()
        }

        func readRateLimits() -> CodexRateLimitSnapshot? {
            lock.lock()
            defer { lock.unlock() }
            let startedAt = Date()

            // Recover once before falling back to local session data. This
            // covers app updates, sleep/wake, broken pipes, and transient
            // initialization failures without repeatedly spawning processes.
            for attempt in 1...2 {
                if let snapshot = readRateLimitsOnce() {
                    let elapsed = Int(Date().timeIntervalSince(startedAt) * 1_000)
                    CodexAppServerClient.logger.info(
                        "Read succeeded attempt=\(attempt, privacy: .public) elapsed_ms=\(elapsed, privacy: .public)"
                    )
                    return snapshot
                }
                CodexAppServerClient.logger.notice(
                    "Read failed attempt=\(attempt, privacy: .public); restarting connection"
                )
                stop()
            }
            let elapsed = Int(Date().timeIntervalSince(startedAt) * 1_000)
            CodexAppServerClient.logger.error(
                "Read unavailable after retry elapsed_ms=\(elapsed, privacy: .public)"
            )
            return nil
        }

        func invalidate() {
            lock.lock()
            stop()
            lock.unlock()
        }

        private func readRateLimitsOnce() -> CodexRateLimitSnapshot? {
            guard ensureStarted(),
                  let inputHandle,
                  let reader else {
                CodexAppServerClient.logger.error("Connection initialization failed")
                return nil
            }

            let accountRequestID = requestAccount(using: inputHandle)
            let requestID = nextRequestID
            nextRequestID += 1
            do {
                try write([
                    "method": "account/rateLimits/read",
                    "id": requestID,
                    "params": [:]
                ], to: inputHandle)
                guard let response = reader.waitForResponse(id: requestID, timeout: 7) else {
                    CodexAppServerClient.logger.error(
                        "Rate-limit request ended without a response request_id=\(requestID, privacy: .public)"
                    )
                    return nil
                }
                guard var snapshot = snapshot(from: response) else {
                    CodexAppServerClient.logger.error(
                        "Rate-limit response was missing usable windows request_id=\(requestID, privacy: .public)"
                    )
                    return nil
                }
                let account = accountRequestID.flatMap {
                    accountResponse(id: $0, reader: reader)
                }
                snapshot.accountEmail = account?.email
                snapshot.accountPlanType = account?.planType
                return snapshot
            } catch {
                CodexAppServerClient.logger.error(
                    "Rate-limit request write failed: \(error.localizedDescription, privacy: .private)"
                )
                return nil
            }
        }

        private func requestAccount(using inputHandle: FileHandle) -> Int? {
            let requestID = nextRequestID
            nextRequestID += 1
            do {
                try write([
                    "method": "account/read",
                    "id": requestID,
                    "params": ["refreshToken": false]
                ], to: inputHandle)
                return requestID
            } catch {
                return nil
            }
        }

        private func accountResponse(id: Int,
                                     reader: JSONLineResponseReader) -> CodexAccountIdentity? {
            guard let response = reader.waitForResponse(id: id, timeout: 0.5) else { return nil }
            return CodexAppServerClient.accountIdentity(from: response)
        }

        private func ensureStarted() -> Bool {
            guard let executable = executable() else {
                CodexAppServerClient.logger.error("No executable Codex CLI was found")
                stop()
                return false
            }
            let currentAuthFile = authFileIdentity()
            if process?.isRunning == true,
               inputHandle != nil,
               reader != nil,
               runningExecutable == executable.identity,
               runningAuthFile == currentAuthFile {
                return true
            }
            if process?.isRunning == true, runningExecutable != executable.identity {
                CodexAppServerClient.logger.notice(
                    "Codex CLI changed on disk; replacing the running app-server"
                )
            }
            stop()

            let process = Process()
            let inputPipe = Pipe()
            let outputPipe = Pipe()
            process.executableURL = executable.url
            process.arguments = ["app-server", "--stdio"]
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self, weak process] terminated in
                guard let self, let process, process === terminated else { return }
                self.processDidTerminate(process)
            }

            let reader = JSONLineResponseReader(
                handle: outputPipe.fileHandleForReading,
                notificationHandler: { [weak self] method in
                    guard method == "account/rateLimits/updated"
                            || method == "account/updated"
                            || method == "account/login/completed" else { return }
                    self?.notifyRateLimitsUpdated()
                }
            )
            self.process = process
            self.inputHandle = inputPipe.fileHandleForWriting
            self.reader = reader
            runningExecutable = executable.identity
            runningAuthFile = currentAuthFile
            nextRequestID = 2

            do {
                try process.run()
                try write([
                    "method": "initialize",
                    "id": 1,
                    "params": [
                        "clientInfo": [
                            "name": "orb",
                            "title": "Orb",
                            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
                        ]
                    ]
                ], to: inputPipe.fileHandleForWriting)
                guard reader.waitForResponse(id: 1, timeout: 3) != nil else {
                    CodexAppServerClient.logger.error("App-server initialization timed out or closed")
                    stop()
                    return false
                }
                try write(["method": "initialized", "params": [:]],
                          to: inputPipe.fileHandleForWriting)
                return true
            } catch {
                CodexAppServerClient.logger.error(
                    "App-server launch failed: \(error.localizedDescription, privacy: .private)"
                )
                stop()
                return false
            }
        }

        private func processDidTerminate(_ terminated: Process) {
            lock.lock()
            guard process === terminated else {
                lock.unlock()
                return
            }
            reader?.stop()
            try? inputHandle?.close()
            reader = nil
            inputHandle = nil
            process = nil
            runningExecutable = nil
            runningAuthFile = nil
            lock.unlock()

            CodexAppServerClient.logger.notice(
                "App-server exited status=\(terminated.terminationStatus, privacy: .public)"
            )

            // Reconnect promptly instead of waiting for the polling timer.
            notifyRateLimitsUpdated()
        }

        private func notifyRateLimitsUpdated() {
            handlerLock.lock()
            let handler = rateLimitsUpdateHandler
            handlerLock.unlock()
            handler?()
        }

        private func stop() {
            reader?.stop()
            try? inputHandle?.close()
            if process?.isRunning == true { process?.terminate() }
            reader = nil
            inputHandle = nil
            process = nil
            runningExecutable = nil
            runningAuthFile = nil
        }
    }

    private struct ExecutableIdentity: Equatable {
        var path: String
        var fileNumber: UInt64?
        var size: UInt64?
        var modificationDate: Date?
    }

    private struct FileIdentity: Equatable {
        var fileNumber: UInt64?
        var size: UInt64?
        var modificationDate: Date?
    }

    private struct Executable {
        var url: URL
        var identity: ExecutableIdentity
    }

    private static func executable() -> Executable? {
        let fm = FileManager.default
        var candidates: [String] = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/usr/local/bin/codex",
            "/opt/homebrew/bin/codex"
        ]

        if let configured = ProcessInfo.processInfo.environment["CODEX_CLI_PATH"],
           !configured.isEmpty {
            candidates.insert(configured, at: 0)
        }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/codex" })
        }

        for path in candidates where fm.isExecutableFile(atPath: path) {
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            let attributes = try? fm.attributesOfItem(atPath: url.path)
            return Executable(
                url: url,
                identity: ExecutableIdentity(
                    path: url.path,
                    fileNumber: (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value,
                    size: (attributes?[.size] as? NSNumber)?.uint64Value,
                    modificationDate: attributes?[.modificationDate] as? Date
                )
            )
        }
        return nil
    }

    private static func authFileIdentity() -> FileIdentity? {
        let home: URL
        if let configured = ProcessInfo.processInfo.environment["CODEX_HOME"],
           !configured.isEmpty {
            home = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
        }
        let url = home.appendingPathComponent("auth.json")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return FileIdentity(
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
            size: (attributes[.size] as? NSNumber)?.uint64Value,
            modificationDate: attributes[.modificationDate] as? Date
        )
    }

    private static func write(_ object: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    static func snapshot(from response: [String: Any]) -> CodexRateLimitSnapshot? {
        guard let result = response["result"] as? [String: Any] else { return nil }

        let direct = result["rateLimits"] as? [String: Any]
        let byID = result["rateLimitsByLimitId"] as? [String: Any] ?? [:]
        var groups = byID.compactMap { id, value -> CodexRateLimitGroup? in
            guard let limits = value as? [String: Any] else { return nil }
            return rateLimitGroup(from: limits, fallbackID: id)
        }

        // Older app-server versions only return the direct rateLimits object.
        // Newer versions include the same general bucket in rateLimitsByLimitId;
        // add the direct object only when it is not already represented.
        if let direct,
           let group = rateLimitGroup(from: direct, fallbackID: "codex"),
           !groups.contains(where: { $0.id == group.id }) {
            groups.append(group)
        }
        guard !groups.isEmpty else { return nil }

        groups.sort {
            if $0.id == "codex", $1.id != "codex" { return true }
            if $1.id == "codex", $0.id != "codex" { return false }
            return ($0.name ?? $0.id).localizedCaseInsensitiveCompare($1.name ?? $1.id) == .orderedAscending
        }

        let credits = direct.flatMap(creditsSnapshot)
            ?? groups.compactMap { group in
                guard let raw = byID[group.id] as? [String: Any] else { return nil }
                return creditsSnapshot(raw)
            }.first
        let resetCredits = resetCreditsSnapshot(result["rateLimitResetCredits"])

        return CodexRateLimitSnapshot(
            groups: groups,
            credits: credits,
            resetCredits: resetCredits,
            fetchedAt: Date(),
            accountID: nonEmptyString(result["accountId"]),
            accountEmail: nil,
            accountPlanType: nil
        )
    }

    static func accountIdentity(from response: [String: Any]) -> CodexAccountIdentity? {
        guard let result = response["result"] as? [String: Any],
              let account = result["account"] as? [String: Any],
              account["type"] as? String == "chatgpt" else { return nil }
        return CodexAccountIdentity(
            email: nonEmptyString(account["email"]),
            planType: nonEmptyString(account["planType"])
        )
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func resetCreditsSnapshot(_ value: Any?) -> CodexResetCreditsSnapshot? {
        guard let object = value as? [String: Any],
              let count = number(object["availableCount"]) else { return nil }
        let credits: [CodexResetCreditSnapshot]?
        if object["credits"] == nil || object["credits"] is NSNull {
            credits = nil
        } else if let rows = object["credits"] as? [[String: Any]] {
            let available: [CodexResetCreditSnapshot] = rows.compactMap { row in
                guard (row["status"] as? String) == "available",
                      let id = row["id"] as? String,
                      let grantedAt = number(row["grantedAt"]) else { return nil }
                return CodexResetCreditSnapshot(
                    id: id,
                    grantedAt: Date(timeIntervalSince1970: grantedAt),
                    expiresAt: number(row["expiresAt"]).map(Date.init(timeIntervalSince1970:)),
                    title: row["title"] as? String,
                    description: row["description"] as? String
                )
            }
            credits = Array(available.prefix(max(0, Int(count))))
        } else {
            credits = nil
        }
        return CodexResetCreditsSnapshot(availableCount: max(0, Int(count)), credits: credits)
    }

    private static func rateLimitGroup(from limits: [String: Any],
                                       fallbackID: String) -> CodexRateLimitGroup? {
        let primary = rateLimitWindow(from: limits["primary"])
        let secondary = rateLimitWindow(from: limits["secondary"])
        guard primary != nil || secondary != nil else { return nil }
        return CodexRateLimitGroup(
            id: limits["limitId"] as? String ?? fallbackID,
            name: limits["limitName"] as? String,
            primary: primary,
            secondary: secondary,
            planType: limits["planType"] as? String
        )
    }

    private static func rateLimitWindow(from value: Any?) -> CodexRateLimitWindow? {
        guard let object = value as? [String: Any],
              let usedPercent = number(object["usedPercent"]) else { return nil }
        return CodexRateLimitWindow(
            usedPercent: usedPercent,
            windowMinutes: number(object["windowDurationMins"]),
            resetAt: number(object["resetsAt"]).map(Date.init(timeIntervalSince1970:))
        )
    }

    private static func creditsSnapshot(_ limits: [String: Any]) -> CodexCreditsSnapshot? {
        guard let object = limits["credits"] as? [String: Any],
              let hasCredits = object["hasCredits"] as? Bool,
              let unlimited = object["unlimited"] as? Bool else { return nil }
        return CodexCreditsSnapshot(
            balance: object["balance"] as? String,
            hasCredits: hasCredits,
            unlimited: unlimited
        )
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        return nil
    }
}

private final class JSONLineResponseReader {
    private let condition = NSCondition()
    private var buffer = Data()
    private var responses: [Int: [String: Any]] = [:]
    private var closed = false
    private let handle: FileHandle
    private let notificationHandler: (String) -> Void

    init(handle: FileHandle, notificationHandler: @escaping (String) -> Void) {
        self.handle = handle
        self.notificationHandler = notificationHandler
        handle.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData)
        }
    }

    func stop() {
        handle.readabilityHandler = nil
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }

    func waitForResponse(id: Int, timeout: TimeInterval) -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }

        while responses[id] == nil && !closed {
            guard condition.wait(until: deadline) else { return nil }
        }
        return responses.removeValue(forKey: id)
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else {
            condition.lock()
            closed = true
            condition.broadcast()
            condition.unlock()
            return
        }

        var notifications: [String] = []
        condition.lock()
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if let id = (object["id"] as? NSNumber)?.intValue {
                responses[id] = object
            } else if let method = object["method"] as? String {
                notifications.append(method)
            }
        }
        condition.broadcast()
        condition.unlock()
        notifications.forEach(notificationHandler)
    }
}
