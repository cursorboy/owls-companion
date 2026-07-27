import Foundation
import Testing
@testable import OwlsCompanionCore

@Suite("Usage mapping")
struct UsageMappingTests {
    @Test("Codex maps session, weekly, and credits")
    @MainActor
    func codexUsage() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = CodexUsageProvider.mapUsage([
            "plan_type": "pro",
            "rate_limit": [
                "primary_window": [
                    "used_percent": 34.0,
                    "limit_window_seconds": 18_000.0,
                    "reset_after_seconds": 300.0
                ],
                "secondary_window": [
                    "used_percent": 52.0,
                    "limit_window_seconds": 604_800.0,
                    "reset_after_seconds": 900.0
                ]
            ],
            "credits": ["balance": 1200.0]
        ], now: now)

        #expect(snapshot.plan == "Pro")
        #expect(snapshot.metrics.first(where: { $0.id == "session" })?.usedPercent == 34)
        #expect(snapshot.metrics.first(where: { $0.id == "weekly" })?.usedPercent == 52)
        #expect(snapshot.metrics.first(where: { $0.id == "credits" })?.value == "1.2K")
    }

    @Test("Claude maps plan and quota windows")
    @MainActor
    func claudeUsage() {
        let snapshot = ClaudeUsageProvider.mapUsage(
            [
                "five_hour": [
                    "utilization": 20.0,
                    "resets_at": "2026-07-28T12:00:00Z"
                ],
                "seven_day": [
                    "utilization": 45.0,
                    "resets_at": "2026-08-02T12:00:00Z"
                ],
                "extra_usage": [
                    "is_enabled": true,
                    "used_credits": 1_250.0,
                    "monthly_limit": 10_000.0
                ]
            ],
            subscriptionType: "team",
            rateLimitTier: "default_5x"
        )

        #expect(snapshot.plan == "Team 5x")
        #expect(snapshot.metrics.first(where: { $0.id == "session" })?.usedPercent == 20)
        #expect(snapshot.metrics.first(where: { $0.id == "weekly" })?.usedPercent == 45)
        #expect(snapshot.metrics.first(where: { $0.id == "extra-usage" })?.label == "Extra usage spent")
        #expect(snapshot.metrics.first(where: { $0.id == "extra-usage" })?.value == "$12.50 of $100.00")
    }

    @Test("OpenCode distinguishes local activity from Go quota")
    @MainActor
    func openCodeUsage() {
        let snapshot = OpenCodeUsageProvider.mapUsage(OpenCodeUsageTotals(
            todayTokens: 12_500,
            thirtyDayTokens: 1_500_000,
            thirtyDaySpend: 18.25,
            sessionSpend: 3,
            weeklySpend: 9,
            monthlySpend: 20,
            sessionResetsAt: nil,
            weeklyResetsAt: nil,
            monthlyResetsAt: nil
        ))

        #expect(snapshot.plan == "Go")
        #expect(snapshot.metrics.first(where: { $0.id == "session" })?.usedPercent == 25)
        #expect(snapshot.metrics.first(where: { $0.id == "today-tokens" })?.value == "12.5K tokens")
        #expect(snapshot.metrics.first(where: { $0.id == "thirty-day-spend" })?.value == "$18.25")
    }

    @Test("Claude local history deduplicates messages and estimates cost")
    func claudeLocalHistory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = root.appendingPathComponent(".claude/projects/test")
        try FileManager.default.createDirectory(
            at: projects,
            withIntermediateDirectories: true
        )
        let line = """
        {"type":"assistant","timestamp":"2026-07-27T12:00:00Z","requestId":"request-1","message":{"id":"message-1","model":"claude-opus-4-8","usage":{"input_tokens":100,"output_tokens":10,"cache_creation_input_tokens":20,"cache_read_input_tokens":50}}}
        """
        try Data("\(line)\n\(line)\n".utf8).write(
            to: projects.appendingPathComponent("session.jsonl")
        )

        let history = await LocalUsageHistoryScanner.claude(
            homeDirectory: root,
            now: try Date(
                "2026-07-27T18:00:00Z",
                strategy: .iso8601
            )
        )
        let used = try #require(history.last(where: { $0.tokens > 0 }))
        #expect(used.tokens == 180)
        #expect(abs((used.costUSD ?? 0) - 0.0009) < 0.000_001)
    }
}

@Suite("Companion paths")
struct CompanionPathTests {
    @Test("All app state shares the companion support directory")
    func companionSupportDirectory() {
        let support = CompanionPaths.applicationSupportDirectory()

        #expect(support.lastPathComponent == "owls Companion")
        #expect(
            CompanionPaths.connectionFile()
                .deletingLastPathComponent() == support
        )
        #expect(
            CompanionPaths.usageCacheFile()
                .deletingLastPathComponent() == support
        )
    }
}

@Suite("Companion updates")
struct CompanionUpdateTests {
    @Test("Semantic versions detect an available update")
    func detectsUpdate() {
        #expect(isNewerVersion("0.3.0", than: "0.2.9"))
        #expect(isNewerVersion("1.0.0", than: "0.99.99"))
        #expect(!isNewerVersion("0.3.0", than: "0.3.0"))
        #expect(!isNewerVersion("0.2.9", than: "0.3.0"))
    }
}
