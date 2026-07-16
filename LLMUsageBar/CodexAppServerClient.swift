import Foundation

struct CodexRateLimitWindow {
    var usedPercent: Double
    var windowMinutes: Double?
    var resetAt: Date?
}

struct CodexRateLimitSnapshot {
    var primary: CodexRateLimitWindow?
    var secondary: CodexRateLimitWindow?
    var planType: String?
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

    /// Keeps one lightweight app-server process for Orb's lifetime. Starting a
    /// new server every minute also warms models and plugins every minute, so a
    /// persistent connection is both faster and substantially less wasteful.
    private final class Connection {
        private let lock = NSLock()
        private var process: Process?
        private var inputHandle: FileHandle?
        private var reader: JSONLineResponseReader?
        private var nextRequestID = 2

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

            let reader = JSONLineResponseReader(handle: outputPipe.fileHandleForReading)
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
        let byID = (result["rateLimitsByLimitId"] as? [String: Any])?["codex"] as? [String: Any]
        guard let limits = direct ?? byID else { return nil }

        let primary = rateLimitWindow(from: limits["primary"])
        let secondary = rateLimitWindow(from: limits["secondary"])
        guard primary != nil || secondary != nil else { return nil }

        return CodexRateLimitSnapshot(
            primary: primary,
            secondary: secondary,
            planType: limits["planType"] as? String,
            fetchedAt: Date()
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

    init(handle: FileHandle) {
        self.handle = handle
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

        condition.lock()
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = (object["id"] as? NSNumber)?.intValue else { continue }
            responses[id] = object
        }
        condition.broadcast()
        condition.unlock()
    }
}
