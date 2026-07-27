import Foundation

public enum UsageProviderID: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
    case opencode

    public var displayName: String {
        switch self {
        case .claude:
            "Claude Code"
        case .codex:
            "Codex"
        case .opencode:
            "OpenCode"
        }
    }
}

public enum UsageMetricKind: String, Codable, Sendable {
    case progress
    case value
}

public struct UsageHistoryPoint: Identifiable, Codable, Hashable, Sendable {
    public let date: Date
    public let tokens: Double
    public let costUSD: Double?

    public var id: Date { date }

    public init(date: Date, tokens: Double, costUSD: Double? = nil) {
        self.date = date
        self.tokens = tokens
        self.costUSD = costUSD
    }
}

public struct UsageMetric: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let kind: UsageMetricKind
    public let usedPercent: Double?
    public let value: String?
    public let resetsAt: Date?
    public let windowDurationSeconds: TimeInterval?
    public let detail: String?

    public init(
        id: String,
        label: String,
        kind: UsageMetricKind,
        usedPercent: Double? = nil,
        value: String? = nil,
        resetsAt: Date? = nil,
        windowDurationSeconds: TimeInterval? = nil,
        detail: String? = nil
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.usedPercent = usedPercent
        self.value = value
        self.resetsAt = resetsAt
        self.windowDurationSeconds = windowDurationSeconds
        self.detail = detail
    }

    public static func progress(
        id: String,
        label: String,
        usedPercent: Double,
        resetsAt: Date? = nil,
        windowDurationSeconds: TimeInterval? = nil,
        detail: String? = nil
    ) -> UsageMetric {
        UsageMetric(
            id: id,
            label: label,
            kind: .progress,
            usedPercent: min(max(usedPercent, 0), 100),
            resetsAt: resetsAt,
            windowDurationSeconds: windowDurationSeconds,
            detail: detail
        )
    }

    public static func value(
        id: String,
        label: String,
        value: String,
        detail: String? = nil
    ) -> UsageMetric {
        UsageMetric(
            id: id,
            label: label,
            kind: .value,
            value: value,
            detail: detail
        )
    }
}

public struct ProviderUsageSnapshot: Identifiable, Codable, Hashable, Sendable {
    public let id: UsageProviderID
    public let plan: String?
    public let metrics: [UsageMetric]
    public let fetchedAt: Date
    public let error: String?
    public let source: String
    public let history: [UsageHistoryPoint]?

    public init(
        id: UsageProviderID,
        plan: String? = nil,
        metrics: [UsageMetric],
        fetchedAt: Date = Date(),
        error: String? = nil,
        source: String,
        history: [UsageHistoryPoint]? = nil
    ) {
        self.id = id
        self.plan = plan
        self.metrics = metrics
        self.fetchedAt = fetchedAt
        self.error = error
        self.source = source
        self.history = history
    }

    public static func failure(
        id: UsageProviderID,
        message: String,
        source: String,
        history: [UsageHistoryPoint]? = nil
    ) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            id: id,
            metrics: [],
            error: message,
            source: source,
            history: history
        )
    }

    public func withHistory(
        _ history: [UsageHistoryPoint]
    ) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            id: id,
            plan: plan,
            metrics: metrics,
            fetchedAt: fetchedAt,
            error: error,
            source: source,
            history: history
        )
    }
}

@MainActor
public protocol UsageProvider: AnyObject {
    var id: UsageProviderID { get }
    func hasLocalFootprint() -> Bool
    func refresh(allowCredentialInteraction: Bool) async -> ProviderUsageSnapshot
}

public extension UsageProvider {
    func refresh() async -> ProviderUsageSnapshot {
        await refresh(allowCredentialInteraction: false)
    }
}
