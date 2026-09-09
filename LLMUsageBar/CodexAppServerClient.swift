import Foundation

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

struct CodexRateLimitSnapshot {
    var groups: [CodexRateLimitGroup]
    var credits: CodexCreditsSnapshot?
    var resetCreditsAvailable: Int
    var fetchedAt: Date
}

/// Reads account-level limits through Codex's official local app-server API.
/// The app-server performs the authenticated account lookup, so usage from
/// another computer is visible without waiting for a local session write.
enum CodexAppServerClient {
    private static let connection = Connection()

    static func readRateLimits() -> CodexRateLimitSnapshot? {
        connection.readRateLimits()
    }

    static func setRateLimitsUpdateHandler(_ handler: (() -> Void)?) {
        connection.setRateLimitsUpdateHandler(handler)
    }

    /// Keeps one lightweight app-server process for Orb's lifetime. Starting a
    /// new server every minute also warms models and plugins every minute, so a
    /// persistent connection is both faster and substantially less wasteful.
    private final class Connection {
        private let lock = NSLock()
        private var process: Process?
        private var inputHandle: FileHandle?
        private var reader: JSONLineResponseReader?
        private var nextRequestID = 2
        private var rateLimitsUpdateHandler: (() -> Void)?

        func setRateLimitsUpdateHandler(_ handler: (() -> Void)?) {
            lock.lock()
            rateLimitsUpdateHandler = handler
            lock.unlock()
        }

        func readRateLimits() -> CodexRateLimitSnapshot? {
            lock.lock()
            defer { lock.unlock() }

            guard ensureStarted(),
                  let inputHandle,
                  let reader else { return nil }

            let requestID = nextRequestID
            nextRequestID += 1
            do {
                try write([
                    "method": "account/rateLimits/read",
                    "id": requestID,
                    "params": [:]
                ], to: inputHandle)
                guard let response = reader.waitForResponse(id: requestID, timeout: 7),
                      let snapshot = snapshot(from: response) else {
                    stop()
                    return nil
                }
                return snapshot
            } catch {
                stop()
                return nil
            }
        }

        private func ensureStarted() -> Bool {
            if process?.isRunning == true, inputHandle != nil, reader != nil {
                return true
            }
            stop()
            guard let executableURL = executableURL() else { return false }

            let process = Process()
            let inputPipe = Pipe()
            let outputPipe = Pipe()
            process.executableURL = executableURL
            process.arguments = ["app-server", "--stdio"]
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = FileHandle.nullDevice

            let reader = JSONLineResponseReader(
                handle: outputPipe.fileHandleForReading,
                notificationHandler: { [weak self] method in
                    guard method == "account/rateLimits/updated" else { return }
                    self?.notifyRateLimitsUpdated()
                }
            )
            self.process = process
            self.inputHandle = inputPipe.fileHandleForWriting
            self.reader = reader
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
                    stop()
                    return false
                }
                try write(["method": "initialized", "params": [:]],
                          to: inputPipe.fileHandleForWriting)
                return true
            } catch {
                stop()
                return false
            }
        }

        private func notifyRateLimitsUpdated() {
            lock.lock()
            let handler = rateLimitsUpdateHandler
            lock.unlock()
            handler?()
        }

        private func stop() {
            reader?.stop()
            try? inputHandle?.close()
            if process?.isRunning == true { process?.terminate() }
            reader = nil
            inputHandle = nil
            process = nil
        }
    }

    private static func executableURL() -> URL? {
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
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private static func write(_ object: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private static func snapshot(from response: [String: Any]) -> CodexRateLimitSnapshot? {
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
        let resetCredits = result["rateLimitResetCredits"] as? [String: Any]
        let resetCreditsAvailable = Int(number(resetCredits?["availableCount"]) ?? 0)

        return CodexRateLimitSnapshot(
            groups: groups,
            credits: credits,
            resetCreditsAvailable: max(0, resetCreditsAvailable),
            fetchedAt: Date()
        )
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
    }

    func waitForResponse(id: Int, timeout: TimeInterval) -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }

        while responses[id] == nil {
            guard condition.wait(until: deadline) else { return nil }
        }
        return responses.removeValue(forKey: id)
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else {
            condition.lock()
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
