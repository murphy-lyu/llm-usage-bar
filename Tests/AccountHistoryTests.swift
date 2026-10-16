import Foundation

@main
struct AccountHistoryTests {
    static func main() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("orb-account-history-\(UUID().uuidString).json")
        setenv("ORB_ACCOUNT_HISTORY_PATH", file.path, 1)
        defer {
            unsetenv("ORB_ACCOUNT_HISTORY_PATH")
            try? FileManager.default.removeItem(at: file)
        }

        let now = Date()
        let first = snapshot(
            id: "account-a",
            email: "first@example.com",
            plan: "plus",
            used: 20,
            reset: now.addingTimeInterval(3_600)
        )
        let second = snapshot(
            id: "account-b",
            email: "second@example.com",
            plan: "pro",
            used: 40,
            reset: now.addingTimeInterval(7_200)
        )
        assert(CodexAccountHistoryStore.record(first)?.id == "account-a")
        assert(CodexAccountHistoryStore.record(second)?.id == "account-b")
        assert(CodexAccountHistoryStore.accounts().count == 2)

        var updatedFirst = first
        updatedFirst.accountEmail = "FIRST@example.com"
        updatedFirst.fetchedAt = now.addingTimeInterval(60)
        updatedFirst.groups[0].primary?.usedPercent = 55
        CodexAccountHistoryStore.record(updatedFirst)

        let records = CodexAccountHistoryStore.accounts()
        assert(records.count == 2)
        assert(records.first?.id == "account-a")
        assert(records.first?.windows.first?.usedPercent == 55)
        assert(records.first?.windows.first?.kind == .fiveHour)

        // Personal and workspace accounts can share an email address; their
        // server-provided IDs must keep them as separate records.
        let sameEmailWorkspace = snapshot(
            id: "workspace-c",
            email: "FIRST@example.com",
            plan: "team",
            used: 10,
            reset: now.addingTimeInterval(10_800)
        )
        CodexAccountHistoryStore.record(sameEmailWorkspace)
        assert(CodexAccountHistoryStore.accounts().count == 3)

        var inactive = snapshot(
            id: "inactive-d",
            email: "inactive@example.com",
            plan: "plus",
            used: 5,
            reset: now.addingTimeInterval(3_600)
        )
        inactive.fetchedAt = now.addingTimeInterval(
            -CodexAccountHistoryStore.inactivityVisibilityInterval - 1
        )
        CodexAccountHistoryStore.record(inactive)
        assert(!CodexAccountHistoryStore.accounts(now: now).contains { $0.id == "inactive-d" })

        inactive.fetchedAt = now.addingTimeInterval(120)
        CodexAccountHistoryStore.record(inactive)
        assert(CodexAccountHistoryStore.accounts(now: now).contains { $0.id == "inactive-d" })
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        assert((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        let accountResponse: [String: Any] = [
            "result": [
                "account": [
                    "type": "chatgpt",
                    "email": "person@example.com",
                    "planType": "team"
                ],
                "requiresOpenaiAuth": true
            ]
        ]
        let identity = CodexAppServerClient.accountIdentity(from: accountResponse)
        assert(identity?.email == "person@example.com")
        assert(identity?.planType == "team")
        print("Account history tests passed.")
    }

    private static func snapshot(id: String,
                                 email: String,
                                 plan: String,
                                 used: Double,
                                 reset: Date) -> CodexRateLimitSnapshot {
        CodexRateLimitSnapshot(
            groups: [
                CodexRateLimitGroup(
                    id: "codex",
                    name: nil,
                    primary: CodexRateLimitWindow(
                        usedPercent: used,
                        windowMinutes: 300,
                        resetAt: reset
                    ),
                    secondary: CodexRateLimitWindow(
                        usedPercent: used / 2,
                        windowMinutes: 10_080,
                        resetAt: reset.addingTimeInterval(7 * 86_400)
                    ),
                    planType: plan
                )
            ],
            credits: nil,
            resetCredits: nil,
            fetchedAt: Date(),
            accountID: id,
            accountEmail: email,
            accountPlanType: plan
        )
    }
}
