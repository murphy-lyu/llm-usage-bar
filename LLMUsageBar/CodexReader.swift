import Foundation

/// Reads Codex session rollouts (~/.codex/sessions/YYYY/MM/DD/*.jsonl).
/// Codex persists OFFICIAL rate limits in `token_count` events
/// (rate_limits.primary/secondary = {used_percent, window_minutes, resets_at}),
/// so we surface those directly. If a local record is older than its reset
/// time and Codex has not written a newer token_count yet, we locally advance
/// that window so the menu bar does not stay stuck overnight.
struct CodexUsageProvider: UsageProviderAdapter {
    let providerID: UsageProviderID = .codex

    func read(config: Config, overrideFile: URL?) -> ProviderUsage {
        CodexReader.read(config: config, overrideFile: overrideFile)
    }
}

enum CodexReader {
    /// A new Codex rollout commonly starts with one `token_count` whose
    /// `rate_limits` is null. Give the session writer a short window to publish
    /// the first complete event before treating the missing limits as real.
    private static let initialRateLimitsGraceInterval: TimeInterval = 5 * 60

    static let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions", isDirectory: true)

    static func read(config: Config, overrideFile: URL? = nil) -> ProviderUsage {
        if overrideFile == nil,
           let snapshot = CodexAppServerClient.readRateLimits() {
            return provider(from: snapshot)
        }

        guard let latest = overrideFile.flatMap({ latestTokenCount(in: $0, sourceFile: $0) }) ?? newestTokenCount() else {
            return ProviderUsage(providerID: .codex, name: "Codex", short: "CX", available: false,
                                 windows: [], note: "codex.note.sessionsMissing".l10n)
        }

        var windows: [UsageWindow] = []
        for (key, label) in [("primary", "limit.primary".l10n), ("secondary", "limit.secondary".l10n)] {
            guard let rl = latest.rateLimits?[key] as? [String: Any],
                  let pct = num(rl["used_percent"]) else { continue }
            let win = num(rl["window_minutes"])
            let reset = num(rl["resets_at"]).map { Date(timeIntervalSince1970: $0) }
            windows.append(normalizedWindow(UsageWindow(
                kind: windowKind(minutes: win),
                label: windowLabel(minutes: win, fallback: label),
                percent: pct, resetAt: reset, detail: nil),
                windowMinutes: win,
                tokenTimestamp: latest.timestamp))
        }
        // Session files stopped reliably including plan_type in rate_limits; the
        // ChatGPT plan is also embedded in the auth token, which doesn't go stale
        // between session writes, so prefer that and fall back to the session data.
        let planFromAuth = authPlanType()
        let planFromSession = (latest.rateLimits?["plan_type"]).map { valueString($0) }
        let plan = (planFromAuth ?? planFromSession).flatMap(planName)
        let quotaID = (latest.rateLimits?["limit_id"] as? String) ?? "codex"
        let localQuota = UsageQuota(
            id: quotaID,
            name: "quota.general".l10n,
            shortName: "quota.general".l10n,
            windows: windows
        )

        if windows.isEmpty {
            // Provider didn't report limits — show local token total as a fallback.
            let detail = latest.totalTokens.map { tokenStr($0) } ?? "codex.detail.noOfficialLimits".l10n
            windows.append(UsageWindow(
                kind: .session,
                label: "codex.window.sessionUsage".l10n, percent: nil, resetAt: nil,
                detail: detail, rolling: true))
            return ProviderUsage(providerID: .codex, name: "Codex", short: "CX", available: true,
                                 windows: windows,
                                 quotas: [UsageQuota(id: quotaID,
                                                     name: "quota.general".l10n,
                                                     shortName: "quota.general".l10n,
                                                     windows: windows)],
                                 note: "codex.note.rateLimitsEmpty".l10n,
                                 lastActivity: latest.timestamp,
                                 sourceFile: latest.sourceFile,
                                 plan: plan)
        }

        return ProviderUsage(providerID: .codex, name: "Codex", short: "CX", available: true,
                             windows: windows, quotas: [localQuota], note: nil, lastActivity: latest.timestamp,
                             sourceFile: latest.sourceFile,
                             plan: plan)
    }

    private static func provider(from snapshot: CodexRateLimitSnapshot) -> ProviderUsage {
        let quotas = snapshot.groups.map { group -> UsageQuota in
            let reportedWindows: [(String, CodexRateLimitWindow?)] = [
                ("limit.primary".l10n, group.primary),
                ("limit.secondary".l10n, group.secondary)
            ]
            let windows = reportedWindows.compactMap { fallback, rateLimit -> UsageWindow? in
                guard let rateLimit else { return nil }
                return UsageWindow(
                    kind: windowKind(minutes: rateLimit.windowMinutes),
                    label: windowLabel(minutes: rateLimit.windowMinutes, fallback: fallback),
                    percent: rateLimit.usedPercent,
                    resetAt: rateLimit.resetAt,
                    detail: nil
                )
            }
            let name = group.name ?? "quota.general".l10n
            return UsageQuota(id: group.id,
                              name: name,
                              shortName: compactQuotaName(name),
                              windows: windows)
        }
        let windows = quotas.flatMap(\.windows)
        let plan = (snapshot.groups.compactMap(\.planType).first ?? authPlanType()).flatMap(planName)

        return ProviderUsage(
            providerID: .codex,
            name: "Codex",
            short: "CX",
            available: !windows.isEmpty,
            windows: windows,
            quotas: quotas,
            note: nil,
            lastActivity: snapshot.fetchedAt,
            sourceFile: nil,
            plan: plan,
            credits: snapshot.credits.map {
                UsageCredits(balance: $0.balance,
                             hasCredits: $0.hasCredits,
                             unlimited: $0.unlimited)
            },
            resetCreditsAvailable: snapshot.resetCreditsAvailable
        )
    }

    private static func compactQuotaName(_ name: String) -> String {
        switch name.lowercased() {
        case "gpt-5.3-codex-spark": return "Codex Spark"
        default: return name
        }
    }

    /// The ChatGPT plan (e.g. "plus") is embedded as a claim in the id_token JWT
    /// stored in ~/.codex/auth.json, under the "https://api.openai.com/auth"
    /// namespace. We only need to base64url-decode the (unsigned-here) payload
    /// segment, not verify the signature — we're just reading our own account's
    /// locally-cached token, not trusting it for auth.
    private static func authPlanType() -> String? {
        let authFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: authFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let idToken = tokens["id_token"] as? String else { return nil }

        let segments = idToken.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }

        guard let payloadData = Data(base64Encoded: base64),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let authClaim = payload["https://api.openai.com/auth"] as? [String: Any],
              let planType = authClaim["chatgpt_plan_type"] as? String else { return nil }
        return planType
    }

    private static func isoDate(_ s: String) -> Date? {
        let a = ISO8601DateFormatter(); a.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let b = ISO8601DateFormatter(); b.formatOptions = [.withInternetDateTime]
        return a.date(from: s) ?? b.date(from: s)
    }

    // MARK: - helpers

    private struct TokenInfo {
        var rateLimits: [String: Any]?
        var totalTokens: Double?
        var timestamp: Date?
        var sourceFile: URL?
    }

    private static func newestTokenCount() -> TokenInfo? {
        let candidates = recentSessionFiles(limit: 80)
            .compactMap { latestTokenCount(in: $0, sourceFile: $0) }
        guard let newest = candidates.max(by: isOlder) else { return nil }

        // An empty first event in a newly-created rollout must not immediately
        // blank the last official limits from another rollout. Keep the newest
        // usable value only during a bounded grace period; a provider that truly
        // never reports limits will still reach the normal token-total fallback.
        guard !hasUsableLimits(newest),
              let timestamp = newest.timestamp,
              Date().timeIntervalSince(timestamp) >= 0,
              Date().timeIntervalSince(timestamp) < initialRateLimitsGraceInterval else {
            return newest
        }
        return candidates.filter(hasUsableLimits).max(by: isOlder) ?? newest
    }

    private static func isOlder(_ lhs: TokenInfo, _ rhs: TokenInfo) -> Bool {
        (lhs.timestamp ?? .distantPast) < (rhs.timestamp ?? .distantPast)
    }

    private static func hasUsableLimits(_ info: TokenInfo) -> Bool {
        (info.rateLimits?["primary"] as? [String: Any]) != nil
            || (info.rateLimits?["secondary"] as? [String: Any]) != nil
    }

    /// Sessions are filed under the day the thread started, but a long-running
    /// thread can keep receiving fresh `token_count` events days later. Pick by
    /// file modification time across the whole session tree, then choose the
    /// newest token timestamp from that bounded candidate set.
    private static func recentSessionFiles(limit: Int) -> [URL] {
        let fm = FileManager.default
        func mtime(_ u: URL) -> Date {
            (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
        }

        guard let enumerator = fm.enumerator(
            at: sessionsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let files = enumerator.compactMap { item -> URL? in
            guard let url = item as? URL, url.pathExtension == "jsonl" else { return nil }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile == true ? url : nil
        }
        return Array(files.sorted { mtime($0) > mtime($1) }.prefix(limit))
    }

    /// Last `token_count` event in the file that carries usable rate limits
    /// (chronological => last line wins). Codex occasionally emits a trailing
    /// token_count with primary/secondary set to null (e.g. right after a limit
    /// is hit, while it briefly reports a credits/premium structure instead) —
    /// we don't want that to blank out the last known percent, so we prefer the
    /// newest event that actually has primary/secondary data, falling back to
    /// the newest event overall only if none do.
    private static func latestTokenCount(in file: URL, sourceFile: URL) -> TokenInfo? {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        var anyResult: TokenInfo? = nil
        var usableResult: TokenInfo? = nil
        for line in content.split(separator: "\n") {
            guard line.contains("\"token_count\""),
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  (payload["type"] as? String) == "token_count" else { continue }
            var info = TokenInfo()
            info.rateLimits = payload["rate_limits"] as? [String: Any]
            if let i = payload["info"] as? [String: Any],
               let total = i["total_token_usage"] as? [String: Any] {
                info.totalTokens = num(total["total_tokens"])
            }
            if let ts = obj["timestamp"] as? String { info.timestamp = isoDate(ts) }
            info.sourceFile = sourceFile
            anyResult = info // keep overwriting; last one is newest
            if hasUsableLimits(info) { usableResult = info }
        }
        return usableResult ?? anyResult
    }

    private static func windowKind(minutes: Double?) -> UsageWindowKind {
        guard let m = minutes else { return .custom }
        switch Int(m) {
        case 43200: return .monthly
        case 10080: return .weekly
        case 1440: return .daily
        case 300: return .fiveHour
        default: return .custom
        }
    }

    private static func normalizedWindow(_ window: UsageWindow,
                                         windowMinutes: Double?,
                                         tokenTimestamp: Date?) -> UsageWindow {
        guard let resetAt = window.resetAt,
              let windowMinutes,
              let tokenTimestamp,
              windowMinutes > 0,
              Date() >= resetAt,
              tokenTimestamp < resetAt else {
            return window
        }

        var normalized = window
        normalized.percent = 0
        normalized.resetAt = nextReset(after: resetAt, windowMinutes: windowMinutes)
        normalized.estimate = true
        return normalized
    }

    private static func nextReset(after resetAt: Date, windowMinutes: Double) -> Date {
        var nextReset = resetAt
        let interval = windowMinutes * 60
        while Date() >= nextReset {
            nextReset = nextReset.addingTimeInterval(interval)
        }
        return nextReset
    }

    private static func windowLabel(minutes: Double?, fallback: String) -> String {
        guard let m = minutes, m > 0 else { return fallback }
        switch Int(m) {
        case 43200: return "limit.monthly".l10n
        case 10080: return "limit.weekly".l10n
        case 1440:  return "limit.daily".l10n
        case 300:   return "limit.fiveHour".l10n
        default:
            if m >= 1440 { return String.localizedStringWithFormat("limit.days".l10n, Int(m / 1440)) }
            if m >= 60 { return String.localizedStringWithFormat("limit.hours".l10n, Int(m / 60)) }
            return String.localizedStringWithFormat("limit.minutes".l10n, Int(m))
        }
    }

    private static func num(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }


    private static func valueString(_ v: Any) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return numberString(n.doubleValue) }
        return String(describing: v)
    }

    private static func planName(_ value: String) -> String? {
        switch value.lowercased() {
        case "free": return "Free"
        case "go": return "Go"
        case "plus": return "Plus"
        case "pro", "prolite": return "Pro"
        case "team", "self_serve_business_prolite", "self_serve_business_usage_based", "business":
            return "Business"
        case "ent26", "enterprise_cbp_automation", "enterprise_cbp_usage_based", "enterprise":
            return "Enterprise"
        case "edu", "edu_plus", "edu_pro": return "Edu"
        case "unknown", "": return nil
        default:
            return value.split(separator: "_").map { $0.capitalized }.joined(separator: " ")
        }
    }

    private static func numberString(_ d: Double) -> String {
        if d.rounded() == d { return String(Int(d)) }
        return String(format: "%.1f", d)
    }

    private static func durationString(_ minutes: Double) -> String {
        let m = Int(minutes)
        if m % 1440 == 0 { return String.localizedStringWithFormat("duration.days".l10n, m / 1440) }
        if m % 60 == 0 { return String.localizedStringWithFormat("duration.hours".l10n, m / 60) }
        return String.localizedStringWithFormat("duration.minutes".l10n, m)
    }

    private static func tokenStr(_ t: Double) -> String {
        if t >= 1_000_000 { return String(format: "%.1fM tokens", t / 1_000_000) }
        if t >= 1_000 { return String(format: "%.0fK tokens", t / 1_000) }
        return String(format: "%.0f tokens", t)
    }
}
