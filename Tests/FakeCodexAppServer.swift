import Foundation

// App-server double for the recovery smoke test. The first process exits while
// reading limits; the restarted process returns valid account-level data.
let statePath = ProcessInfo.processInfo.environment["FAKE_CODEX_STATE"]!

while let line = readLine(),
      let data = line.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
    guard let id = (object["id"] as? NSNumber)?.intValue else { continue }
    let method = object["method"] as? String

    if method == "initialize" {
        print("{\"id\":\(id),\"result\":{}}")
        fflush(stdout)
        continue
    }

    if method == "account/rateLimits/read" {
        if !FileManager.default.fileExists(atPath: statePath) {
            _ = FileManager.default.createFile(atPath: statePath, contents: Data())
            exit(1)
        }
        print("""
        {"id":\(id),"result":{"rateLimits":{"limitId":"codex","planType":"plus","primary":{"usedPercent":42,"windowDurationMins":300}},"rateLimitResetCredits":{"availableCount":3,"credits":null}}}
        """)
        fflush(stdout)
    }
}
