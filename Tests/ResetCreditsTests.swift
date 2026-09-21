import Foundation

@main
struct ResetCreditsTests {
    static func main() {
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let response: [String: Any] = [
            "result": [
                "rateLimits": [
                    "limitId": "codex",
                    "primary": ["usedPercent": 90, "windowDurationMins": 300]
                ],
                "rateLimitResetCredits": [
                    "availableCount": 2,
                    "credits": [
                        ["id": "later", "status": "available", "grantedAt": 1_700_000_000,
                         "expiresAt": 1_900_000_000],
                        ["id": "next", "status": "available", "grantedAt": 1_700_000_001,
                         "expiresAt": expiry.timeIntervalSince1970],
                        ["id": "used", "status": "redeemed", "grantedAt": 1_700_000_002,
                         "expiresAt": 1_750_000_000]
                    ]
                ]
            ]
        ]
        let snapshot = CodexAppServerClient.snapshot(from: response)
        assert(snapshot?.resetCredits?.availableCount == 2)
        assert(snapshot?.resetCredits?.credits?.count == 2)

        let usage = UsageResetCredits(
            availableCount: snapshot!.resetCredits!.availableCount,
            credits: snapshot!.resetCredits!.credits!.map {
                UsageResetCredit(id: $0.id, grantedAt: $0.grantedAt,
                                 expiresAt: $0.expiresAt, title: $0.title,
                                 detail: $0.description)
            })
        assert(usage.nextExpiry == expiry)
        assert(!usage.creditsDoNotExpire)

        let nonExpiring = UsageResetCredits(
            availableCount: 2,
            credits: [
                UsageResetCredit(id: "one", grantedAt: Date(), expiresAt: nil,
                                 title: nil, detail: nil),
                UsageResetCredit(id: "two", grantedAt: Date(), expiresAt: nil,
                                 title: nil, detail: nil)
            ])
        assert(nonExpiring.nextExpiry == nil)
        assert(nonExpiring.creditsDoNotExpire)
        assert(!UsageResetCredits(availableCount: 2, credits: nil).creditsDoNotExpire)

        let countOnly: [String: Any] = [
            "result": [
                "rateLimits": ["primary": ["usedPercent": 10]],
                "rateLimitResetCredits": ["availableCount": 1, "credits": NSNull()]
            ]
        ]
        assert(CodexAppServerClient.snapshot(from: countOnly)?.resetCredits?.credits == nil)
        assert(!UsageCredits(balance: "0", hasCredits: false, unlimited: false).shouldDisplay)
        assert(!UsageCredits(balance: "0", hasCredits: true, unlimited: false).shouldDisplay)
        assert(UsageCredits(balance: "12.5", hasCredits: true, unlimited: false).shouldDisplay)
        assert(UsageCredits(balance: "12.5", hasCredits: false, unlimited: false).shouldDisplay)
        assert(UsageCredits(balance: nil, hasCredits: true, unlimited: false).shouldDisplay)
        assert(UsageCredits(balance: "0", hasCredits: false, unlimited: true).shouldDisplay)
        print("Reset credit tests passed.")
    }
}
