import Foundation
import OSLog

@MainActor
public final class ClaudeUsageProvider: UsageProvider {
    public let id = UsageProviderID.claude

    private static let refreshURL = URL(
        string: "https://platform.claude.com/v1/oauth/token"
    )!
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let scopes = [
        "user:profile",
        "user:inference",
        "user:sessions:claude_code",
        "user:mcp_servers",
        "user:file_upload"
    ].joined(separator: " ")
    private static let logger = Logger(
        subsystem: "com.openworkloads.owls.companion",
        category: "claude"
    )

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
        FileManager.default.fileExists(atPath: credentialsFile().path)
            || ProviderSupport.keychainPassword(
                service: "Claude Code-credentials",
                account: currentUserAccount()
            ) != nil
            || ProviderSupport.keychainPassword(service: "Claude Code-credentials") != nil
    }

    public func refresh(
        allowCredentialInteraction: Bool
    ) async -> ProviderUsageSnapshot {
        let refreshDate = now()
        async let localHistory = LocalUsageHistoryScanner.claude(
            homeDirectory: homeDirectory,
            now: refreshDate
        )
        do {
            var oauth = try loadOAuth()
            var refreshed = false
            if needsRefresh(oauth) {
                oauth = try await refreshOAuth(oauth)
                refreshed = true
            }
            let result: (body: [String: Any], response: HTTPURLResponse)
            do {
                result = try await fetchUsage(oauth.accessToken)
            } catch let error as UsageReadError {
                guard case .requestFailed(let status) = error,
                      status == 401 || status == 403,
                      !refreshed
                else {
                    throw error
                }
                oauth = try await refreshOAuth(oauth)
                result = try await fetchUsage(oauth.accessToken)
            }
            return Self.mapUsage(
                result.body,
                subscriptionType: oauth.subscriptionType,
                rateLimitTier: oauth.rateLimitTier,
                now: now()
            ).withHistory(await localHistory)
        } catch {
            let primaryError = error
            Self.logger.error(
                "Claude Code usage failed: \(error.localizedDescription, privacy: .public)"
            )
            do {
                if let desktop = try await loadDesktopUsage(
                    allowCredentialInteraction: allowCredentialInteraction
                ) {
                    Self.logger.info(
                        "Claude usage is using the read-only Desktop credential fallback."
                    )
                    return desktop.withHistory(await localHistory)
                }
            } catch {
                Self.logger.error(
                    "Claude Desktop usage failed: \(error.localizedDescription, privacy: .public)"
                )
                return .failure(
                    id: id,
                    message: error.localizedDescription,
                    source: "Claude subscription",
                    history: await localHistory
                )
            }
            return .failure(
                id: id,
                message: primaryError.localizedDescription,
                source: "Claude subscription",
                history: await localHistory
            )
        }
    }

    public static func mapUsage(
        _ body: [String: Any],
        subscriptionType: String?,
        rateLimitTier: String?,
        now: Date = Date()
    ) -> ProviderUsageSnapshot {
        var metrics: [UsageMetric] = []
        appendWindow(
            body["five_hour"],
            id: "session",
            label: "Session",
            metrics: &metrics,
            now: now
        )
        appendWindow(
            body["seven_day"],
            id: "weekly",
            label: "Weekly",
            metrics: &metrics,
            now: now
        )
        appendWindow(
            body["seven_day_sonnet"],
            id: "sonnet",
            label: "Sonnet",
            metrics: &metrics,
            now: now
        )

        if let extra = body["extra_usage"] as? [String: Any],
           extra["is_enabled"] as? Bool == true,
           let used = ProviderSupport.number(extra["used_credits"]) {
            let usedDollars = used / 100
            let value: String
            if let limit = ProviderSupport.number(extra["monthly_limit"]), limit > 0 {
                value = String(format: "$%.2f of $%.2f", usedDollars, limit / 100)
            } else {
                value = String(format: "$%.2f", usedDollars)
            }
            metrics.append(.value(
                id: "extra-usage",
                label: "Extra usage spent",
                value: value
            ))
        }

        let basePlan = ProviderSupport.planName(subscriptionType)
        let multiplier = rateLimitTier?
            .split(separator: "_")
            .first { $0.hasSuffix("x") }
            .map(String.init)
        let plan = [basePlan, multiplier].compactMap { $0 }.joined(separator: " ")

        return ProviderUsageSnapshot(
            id: .claude,
            plan: plan.isEmpty ? nil : plan,
            metrics: metrics,
            source: "Claude subscription"
        )
    }

    private static func appendWindow(
        _ value: Any?,
        id: String,
        label: String,
        metrics: inout [UsageMetric],
        now: Date
    ) {
        guard let window = value as? [String: Any],
              let used = ProviderSupport.number(window["utilization"])
        else {
            return
        }
        metrics.append(.progress(
            id: id,
            label: label,
            usedPercent: used,
            resetsAt: ProviderSupport.resetDate(window["resets_at"], now: now),
            windowDurationSeconds: id == "session"
                ? 5 * 60 * 60
                : 7 * 24 * 60 * 60
        ))
    }

    private func loadOAuth() throws -> (
        source: OAuthSource,
        accessToken: String,
        refreshToken: String?,
        expiresAt: Double?,
        subscriptionType: String?,
        rateLimitTier: String?,
        document: [String: Any]
    ) {
        let service = "Claude Code-credentials"
        let account = currentUserAccount()
        if let keychain = ProviderSupport.keychainPassword(
            service: service,
            account: account
        ),
           let oauth = parseOAuth(
               keychain,
               source: .keychain(service: service, account: account)
           ) {
            Self.logger.info("Claude credential source is current-user Keychain.")
            return oauth
        }
        if let keychain = ProviderSupport.keychainPassword(service: service),
           let oauth = parseOAuth(
               keychain,
               source: .keychain(service: service, account: nil)
           ) {
            Self.logger.info("Claude credential source is legacy Keychain.")
            return oauth
        }
        if let data = try? Data(contentsOf: credentialsFile()),
           let text = String(data: data, encoding: .utf8),
           let oauth = parseOAuth(text, source: .file(credentialsFile())) {
            Self.logger.info("Claude credential source is the local credential file.")
            return oauth
        }
        throw UsageReadError.notConfigured("Sign in with Claude Code to show usage.")
    }

    private func parseOAuth(
        _ text: String,
        source: OAuthSource
    ) -> (
        source: OAuthSource,
        accessToken: String,
        refreshToken: String?,
        expiresAt: Double?,
        subscriptionType: String?,
        rateLimitTier: String?,
        document: [String: Any]
    )? {
        let decodedText: String
        if text.first == "{" {
            decodedText = text
        } else if let data = Data(hexEncoded: text),
                  let decoded = String(data: data, encoding: .utf8) {
            decodedText = decoded
        } else {
            return nil
        }
        guard let data = decodedText.data(using: .utf8),
              let object = ProviderSupport.dictionary(from: data),
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let accessToken = ProviderSupport.string(oauth["accessToken"])
        else {
            return nil
        }
        return (
            source,
            accessToken,
            ProviderSupport.string(oauth["refreshToken"]),
            ProviderSupport.number(oauth["expiresAt"]),
            ProviderSupport.string(oauth["subscriptionType"]),
            ProviderSupport.string(oauth["rateLimitTier"]),
            object
        )
    }

    private func needsRefresh(
        _ oauth: (
            source: OAuthSource,
            accessToken: String,
            refreshToken: String?,
            expiresAt: Double?,
            subscriptionType: String?,
            rateLimitTier: String?,
            document: [String: Any]
        )
    ) -> Bool {
        guard let expiresAt = oauth.expiresAt else { return false }
        return expiresAt - now().timeIntervalSince1970 * 1_000 <= 5 * 60 * 1_000
    }

    private func fetchUsage(
        _ accessToken: String
    ) async throws -> (body: [String: Any], response: HTTPURLResponse) {
        try await ProviderSupport.requestJSON(
            url: URL(string: "https://api.anthropic.com/api/oauth/usage")!,
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "Accept": "application/json",
                "Content-Type": "application/json",
                "anthropic-beta": "oauth-2025-04-20",
                "User-Agent": "claude-code/2.1.69"
            ]
        )
    }

    private func loadDesktopUsage(
        allowCredentialInteraction: Bool
    ) async throws -> ProviderUsageSnapshot? {
        let homeDirectory = homeDirectory
        let currentDate = now()
        let desktop = try await Task.detached(priority: .userInitiated) {
            try ClaudeDesktopCredentials.load(
                homeDirectory: homeDirectory,
                now: currentDate,
                allowInteraction: allowCredentialInteraction
            )
        }.value
        guard let desktop else {
            return nil
        }
        let result = try await fetchUsage(desktop.accessToken)
        return Self.mapUsage(
            result.body,
            subscriptionType: desktop.subscriptionType,
            rateLimitTier: desktop.rateLimitTier,
            now: now()
        )
    }

    private func refreshOAuth(
        _ current: (
            source: OAuthSource,
            accessToken: String,
            refreshToken: String?,
            expiresAt: Double?,
            subscriptionType: String?,
            rateLimitTier: String?,
            document: [String: Any]
        )
    ) async throws -> (
        source: OAuthSource,
        accessToken: String,
        refreshToken: String?,
        expiresAt: Double?,
        subscriptionType: String?,
        rateLimitTier: String?,
        document: [String: Any]
    ) {
        guard let refreshToken = current.refreshToken else {
            throw UsageReadError.notConfigured(
                "The Claude session expired. Run claude to sign in again."
            )
        }
        let requestBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID,
            "scope": Self.scopes
        ])
        let result: (body: [String: Any], response: HTTPURLResponse)
        do {
            result = try await ProviderSupport.requestJSON(
                url: Self.refreshURL,
                method: "POST",
                headers: ["Content-Type": "application/json"],
                body: requestBody
            )
        } catch let error as UsageReadError {
            guard case .requestFailed(let status) = error,
                  status == 400 || status == 401
            else {
                throw error
            }
            throw UsageReadError.notConfigured(
                "The Claude session expired. Run claude to sign in again."
            )
        }
        guard let accessToken = ProviderSupport.string(
            result.body["access_token"]
        ) else {
            throw UsageReadError.invalidResponse
        }
        let rotatedRefreshToken =
            ProviderSupport.string(result.body["refresh_token"]) ?? refreshToken
        let expiresAt = ProviderSupport.number(result.body["expires_in"])
            .map { now().timeIntervalSince1970 * 1_000 + $0 * 1_000 }

        var document = current.document
        var oauth = document["claudeAiOauth"] as? [String: Any] ?? [:]
        oauth["accessToken"] = accessToken
        oauth["refreshToken"] = rotatedRefreshToken
        if let expiresAt {
            oauth["expiresAt"] = expiresAt
        }
        document["claudeAiOauth"] = oauth
        try persistOAuth(
            document,
            source: current.source,
            expectedAccessToken: current.accessToken,
            expectedRefreshToken: current.refreshToken
        )
        return (
            current.source,
            accessToken,
            rotatedRefreshToken,
            expiresAt,
            current.subscriptionType,
            current.rateLimitTier,
            document
        )
    }

    private func persistOAuth(
        _ document: [String: Any],
        source: OAuthSource,
        expectedAccessToken: String,
        expectedRefreshToken: String?
    ) throws {
        let currentText: String?
        switch source {
        case .file(let path):
            currentText = try? String(contentsOf: path, encoding: .utf8)
        case .keychain(let service, let account):
            currentText = ProviderSupport.keychainPassword(
                service: service,
                account: account
            )
        }
        guard let currentText,
              let current = parseOAuth(currentText, source: source),
              current.accessToken == expectedAccessToken,
              current.refreshToken == expectedRefreshToken
        else {
            throw UsageReadError.localDataUnreadable(
                "The Claude login changed while usage was refreshing. Try again."
            )
        }
        let data = try JSONSerialization.data(
            withJSONObject: document,
            options: [.prettyPrinted, .sortedKeys]
        )
        guard let text = String(data: data, encoding: .utf8) else {
            throw UsageReadError.invalidResponse
        }
        switch source {
        case .file(let path):
            try data.write(to: path, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: path.path
            )
        case .keychain(let service, let account):
            try ProviderSupport.updateKeychainPassword(
                service: service,
                account: account,
                value: text
            )
        }
    }

    private func credentialsFile() -> URL {
        if let configured = ProviderSupport.string(environment["CLAUDE_CONFIG_DIR"]) {
            return URL(fileURLWithPath: configured).appendingPathComponent(".credentials.json")
        }
        return homeDirectory.appendingPathComponent(".claude/.credentials.json")
    }

    private func currentUserAccount() -> String {
        ProviderSupport.string(environment["USER"]) ?? NSUserName()
    }
}

private enum OAuthSource {
    case file(URL)
    case keychain(service: String, account: String?)
}

private extension Data {
    init?(hexEncoded value: String) {
        guard value.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = next
        }
        self = data
    }
}
