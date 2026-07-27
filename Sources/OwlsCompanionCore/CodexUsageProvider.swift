import Foundation

@MainActor
public final class CodexUsageProvider: UsageProvider {
    public let id = UsageProviderID.codex

    private let homeDirectory: URL
    private let environment: [String: String]
    private let now: () -> Date

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: @escaping () -> Date = Date.init
    ) {
        self.homeDirectory = homeDirectory
        self.environment = environment
        self.now = now
    }

    public func hasLocalFootprint() -> Bool {
        authFiles().contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    public func refresh(
        allowCredentialInteraction: Bool
    ) async -> ProviderUsageSnapshot {
        let refreshDate = now()
        async let localHistory = LocalUsageHistoryScanner.codex(
            homeDirectory: homeDirectory,
            environment: environment,
            now: refreshDate
        )
        do {
            let auth = try loadAuth()
            let result = try await ProviderSupport.requestJSON(
                url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
                headers: usageHeaders(accessToken: auth.accessToken, accountID: auth.accountID)
            )
            return Self.mapUsage(result.body, now: now())
                .withHistory(await localHistory)
        } catch {
            return .failure(
                id: id,
                message: error.localizedDescription,
                source: "Codex subscription",
                history: await localHistory
            )
        }
    }

    public static func mapUsage(
        _ body: [String: Any],
        now: Date = Date()
    ) -> ProviderUsageSnapshot {
        var metrics: [UsageMetric] = []
        if let rateLimit = body["rate_limit"] as? [String: Any] {
            appendWindow(
                rateLimit["primary_window"],
                fallbackID: "session",
                fallbackLabel: "Session",
                metrics: &metrics,
                now: now
            )
            appendWindow(
                rateLimit["secondary_window"],
                fallbackID: "weekly",
                fallbackLabel: "Weekly",
                metrics: &metrics,
                now: now
            )
        }

        if let credits = body["credits"] as? [String: Any],
           let balance = ProviderSupport.number(credits["balance"]) {
            metrics.append(.value(
                id: "credits",
                label: "Credits",
                value: ProviderSupport.compactNumber(balance)
            ))
        }

        let plan = ProviderSupport.planName(ProviderSupport.string(body["plan_type"]))
        return ProviderUsageSnapshot(
            id: .codex,
            plan: plan,
            metrics: metrics,
            source: "Codex subscription"
        )
    }

    private static func appendWindow(
        _ value: Any?,
        fallbackID: String,
        fallbackLabel: String,
        metrics: inout [UsageMetric],
        now: Date
    ) {
        guard let window = value as? [String: Any],
              let used = ProviderSupport.number(window["used_percent"])
        else {
            return
        }
        let seconds = ProviderSupport.number(window["limit_window_seconds"])
        let isWeekly = seconds.map { $0 >= 6 * 24 * 60 * 60 } ?? (fallbackID == "weekly")
        metrics.append(.progress(
            id: isWeekly ? "weekly" : fallbackID,
            label: isWeekly ? "Weekly" : fallbackLabel,
            usedPercent: used,
            resetsAt: ProviderSupport.resetDate(window: window, now: now),
            windowDurationSeconds: seconds
        ))
    }

    private func loadAuth() throws -> (accessToken: String, accountID: String?) {
        for file in authFiles() {
            guard let auth = ProviderSupport.dictionary(at: file),
                  let tokens = auth["tokens"] as? [String: Any],
                  let accessToken = ProviderSupport.string(tokens["access_token"])
            else {
                continue
            }
            return (
                accessToken,
                ProviderSupport.string(tokens["account_id"])
            )
        }

        if let keychain = ProviderSupport.keychainPassword(service: "Codex Auth"),
           let data = keychain.data(using: .utf8),
           let auth = ProviderSupport.dictionary(from: data),
           let tokens = auth["tokens"] as? [String: Any],
           let accessToken = ProviderSupport.string(tokens["access_token"]) {
            return (
                accessToken,
                ProviderSupport.string(tokens["account_id"])
            )
        }
        throw UsageReadError.notConfigured("Sign in with Codex to show usage.")
    }

    private func authFiles() -> [URL] {
        if let configured = ProviderSupport.string(environment["CODEX_HOME"]) {
            return [URL(fileURLWithPath: configured).appendingPathComponent("auth.json")]
        }
        return [
            homeDirectory.appendingPathComponent(".codex/auth.json"),
            homeDirectory.appendingPathComponent(".config/codex/auth.json")
        ]
    }

    private func usageHeaders(accessToken: String, accountID: String?) -> [String: String] {
        var headers = [
            "Authorization": "Bearer \(accessToken)",
            "Accept": "application/json",
            "User-Agent": "OwlsCompanion"
        ]
        if let accountID {
            headers["ChatGPT-Account-Id"] = accountID
        }
        return headers
    }
}
