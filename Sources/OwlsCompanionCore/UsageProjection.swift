import Foundation

public enum UsagePaceStatus: String, Codable, Sendable {
    case onPace
    case close
    case mayRunOut
    case exhausted
}

public struct UsageProjection: Equatable, Sendable {
    public let status: UsagePaceStatus
    public let projectedUsedPercentAtReset: Double
    public let projectedExhaustionAt: Date?

    public init(
        status: UsagePaceStatus,
        projectedUsedPercentAtReset: Double,
        projectedExhaustionAt: Date?
    ) {
        self.status = status
        self.projectedUsedPercentAtReset = projectedUsedPercentAtReset
        self.projectedExhaustionAt = projectedExhaustionAt
    }
}

public enum UsageProjectionCalculator {
    public static func calculate(
        metric: UsageMetric,
        now: Date = Date()
    ) -> UsageProjection? {
        guard metric.kind == .progress,
              let usedPercent = metric.usedPercent,
              let resetsAt = metric.resetsAt,
              let duration = metric.windowDurationSeconds,
              duration > 0,
              now < resetsAt
        else {
            return nil
        }

        let windowStartedAt = resetsAt.addingTimeInterval(-duration)
        let elapsed = now.timeIntervalSince(windowStartedAt)
        let minimumElapsed = max(60, duration * 0.01)
        guard elapsed >= minimumElapsed, elapsed <= duration else {
            return nil
        }

        if usedPercent >= 100 {
            return UsageProjection(
                status: .exhausted,
                projectedUsedPercentAtReset: 100,
                projectedExhaustionAt: now
            )
        }

        guard usedPercent > 0 else {
            return UsageProjection(
                status: .onPace,
                projectedUsedPercentAtReset: 0,
                projectedExhaustionAt: nil
            )
        }

        let percentPerSecond = usedPercent / elapsed
        let projectedAtReset = percentPerSecond * duration
        let exhaustionAt = windowStartedAt.addingTimeInterval(
            100 / percentPerSecond
        )
        let runsOutBeforeReset = exhaustionAt < resetsAt
        if runsOutBeforeReset && usedPercent < 5 {
            return nil
        }

        let status: UsagePaceStatus
        if runsOutBeforeReset {
            status = .mayRunOut
        } else if projectedAtReset > 90 {
            status = .close
        } else {
            status = .onPace
        }

        return UsageProjection(
            status: status,
            projectedUsedPercentAtReset: projectedAtReset,
            projectedExhaustionAt: runsOutBeforeReset ? exhaustionAt : nil
        )
    }
}
