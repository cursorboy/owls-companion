import Foundation

public struct OpenCodeUsageTotals: Sendable, Equatable {
    public let todayTokens: Double
    public let thirtyDayTokens: Double
    public let thirtyDaySpend: Double
    public let sessionSpend: Double?
    public let weeklySpend: Double?
    public let monthlySpend: Double?
    public let sessionResetsAt: Date?
    public let weeklyResetsAt: Date?
    public let monthlyResetsAt: Date?
    public let history: [UsageHistoryPoint]

    public init(
        todayTokens: Double,
        thirtyDayTokens: Double,
        thirtyDaySpend: Double,
        sessionSpend: Double?,
        weeklySpend: Double?,
        monthlySpend: Double?,
        sessionResetsAt: Date?,
        weeklyResetsAt: Date?,
        monthlyResetsAt: Date?,
        history: [UsageHistoryPoint] = []
    ) {
        self.todayTokens = todayTokens
        self.thirtyDayTokens = thirtyDayTokens
        self.thirtyDaySpend = thirtyDaySpend
        self.sessionSpend = sessionSpend
        self.weeklySpend = weeklySpend
        self.monthlySpend = monthlySpend
        self.sessionResetsAt = sessionResetsAt
        self.weeklyResetsAt = weeklyResetsAt
        self.monthlyResetsAt = monthlyResetsAt
        self.history = history
    }
}

@MainActor
public final class OpenCodeUsageProvider: UsageProvider {
    public let id = UsageProviderID.opencode

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
        !databaseFiles().isEmpty
    }

    public func refresh(
        allowCredentialInteraction: Bool
    ) async -> ProviderUsageSnapshot {
        let paths = databaseFiles()
        guard !paths.isEmpty else {
            return .failure(
                id: id,
                message: "Use OpenCode locally to show activity.",
                source: "Local OpenCode history"
            )
        }
        do {
            let totals = try await Self.scan(paths: paths, now: now())
            return Self.mapUsage(totals)
        } catch {
            return .failure(
                id: id,
                message: error.localizedDescription,
                source: "Local OpenCode history"
            )
        }
    }

    public static func mapUsage(_ totals: OpenCodeUsageTotals) -> ProviderUsageSnapshot {
        var metrics: [UsageMetric] = []
        if let session = totals.sessionSpend {
            metrics.append(.progress(
                id: "session",
                label: "Go session",
                usedPercent: session / 12 * 100,
                resetsAt: totals.sessionResetsAt,
                detail: String(format: "$%.2f of $12", session)
            ))
        }
        if let weekly = totals.weeklySpend {
            metrics.append(.progress(
                id: "weekly",
                label: "Go weekly",
                usedPercent: weekly / 30 * 100,
                resetsAt: totals.weeklyResetsAt,
                detail: String(format: "$%.2f of $30", weekly)
            ))
        }
        if let monthly = totals.monthlySpend {
            metrics.append(.progress(
                id: "monthly",
                label: "Go monthly",
                usedPercent: monthly / 60 * 100,
                resetsAt: totals.monthlyResetsAt,
                detail: String(format: "$%.2f of $60", monthly)
            ))
        }
        metrics.append(.value(
            id: "today-tokens",
            label: "Today",
            value: "\(ProviderSupport.compactNumber(totals.todayTokens)) tokens"
        ))
        metrics.append(.value(
            id: "thirty-day-tokens",
            label: "Last 30 days",
            value: "\(ProviderSupport.compactNumber(totals.thirtyDayTokens)) tokens"
        ))
        if totals.thirtyDaySpend > 0 {
            metrics.append(.value(
                id: "thirty-day-spend",
                label: "Local spend",
                value: String(format: "$%.2f", totals.thirtyDaySpend),
                detail: "Recorded by OpenCode on this Mac"
            ))
        }
        return ProviderUsageSnapshot(
            id: .opencode,
            plan: totals.sessionSpend == nil ? nil : "Go",
            metrics: metrics,
            source: "Local OpenCode history",
            history: totals.history
        )
    }

    private static func scan(paths: [URL], now: Date) async throws -> OpenCodeUsageTotals {
        try await Task.detached(priority: .utility) {
            var allRows: [OpenCodeRow] = []
            for path in paths {
                allRows.append(contentsOf: try query(path: path, now: now))
            }
            guard !allRows.isEmpty else {
                return OpenCodeUsageTotals(
                    todayTokens: 0,
                    thirtyDayTokens: 0,
                    thirtyDaySpend: 0,
                    sessionSpend: nil,
                    weeklySpend: nil,
                    monthlySpend: nil,
                    sessionResetsAt: nil,
                    weeklyResetsAt: nil,
                    monthlyResetsAt: nil,
                    history: []
                )
            }
            return calculate(rows: allRows, now: now)
        }.value
    }

    private struct OpenCodeRow: Decodable, Sendable {
        let timeCreated: Double
        let cost: Double?
        let tokens: Double?
        let providerID: String?

        enum CodingKeys: String, CodingKey {
            case timeCreated = "time_created"
            case cost
            case tokens
            case providerID = "provider_id"
        }
    }

    nonisolated private static func query(path: URL, now: Date) throws -> [OpenCodeRow] {
        let cutoff = Int((now.timeIntervalSince1970 - 31 * 86_400) * 1_000)
        let sql = """
        SELECT time_created,
               json_extract(data,'$.cost') AS cost,
               COALESCE(json_extract(data,'$.tokens.total'),0) AS tokens,
               json_extract(data,'$.providerID') AS provider_id
        FROM message
        WHERE time_created >= \(cutoff)
          AND json_valid(data)
          AND json_extract(data,'$.role') = 'assistant';
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-json", path.path, sql]
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw UsageReadError.localDataUnreadable(error.localizedDescription)
        }
        guard process.terminationStatus == 0 else {
            let data = standardError.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "sqlite3 failed"
            throw UsageReadError.localDataUnreadable(detail)
        }
        let data = standardOutput.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty else { return [] }
        do {
            return try JSONDecoder().decode([OpenCodeRow].self, from: data)
        } catch {
            throw UsageReadError.localDataUnreadable(error.localizedDescription)
        }
    }

    nonisolated private static func calculate(
        rows: [OpenCodeRow],
        now: Date
    ) -> OpenCodeUsageTotals {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let startOfToday = calendar.startOfDay(for: now)
        let thirtyDaysAgo = now.addingTimeInterval(-30 * 86_400)
        let fiveHoursAgo = now.addingTimeInterval(-5 * 60 * 60)
        let weekday = calendar.component(.weekday, from: startOfToday)
        let daysSinceMonday = (weekday + 5) % 7
        let startOfWeek = calendar.date(
            byAdding: .day,
            value: -daysSinceMonday,
            to: startOfToday
        ) ?? startOfToday
        let startOfMonth = calendar.date(
            from: calendar.dateComponents([.year, .month], from: now)
        ) ?? startOfToday
        let endOfWeek = calendar.date(
            byAdding: .day,
            value: 7,
            to: startOfWeek
        )
        let endOfMonth = calendar.date(
            byAdding: .month,
            value: 1,
            to: startOfMonth
        )

        let normalized = rows.map { row in
            (
                date: Date(timeIntervalSince1970: row.timeCreated / 1_000),
                cost: max(row.cost ?? 0, 0),
                tokens: max(row.tokens ?? 0, 0),
                isGo: row.providerID == "opencode-go"
            )
        }
        let history = (0..<30).reversed().compactMap { offset
            -> UsageHistoryPoint? in
            guard let date = calendar.date(
                byAdding: .day,
                value: -offset,
                to: startOfToday
            ) else {
                return nil
            }
            let end = calendar.date(
                byAdding: .day,
                value: 1,
                to: date
            ) ?? date
            let dayRows = normalized.filter {
                $0.date >= date && $0.date < end
            }
            return UsageHistoryPoint(
                date: date,
                tokens: dayRows.reduce(0) { $0 + $1.tokens },
                costUSD: dayRows.isEmpty
                    ? nil
                    : dayRows.reduce(0) { $0 + $1.cost }
            )
        }
        let goRows = normalized.filter(\.isGo)
        let oldestSessionDate = goRows
            .filter { $0.date >= fiveHoursAgo && $0.date <= now }
            .map(\.date)
            .min()

        return OpenCodeUsageTotals(
            todayTokens: normalized
                .filter { $0.date >= startOfToday && $0.date <= now }
                .reduce(0) { $0 + $1.tokens },
            thirtyDayTokens: normalized
                .filter { $0.date >= thirtyDaysAgo && $0.date <= now }
                .reduce(0) { $0 + $1.tokens },
            thirtyDaySpend: normalized
                .filter { $0.date >= thirtyDaysAgo && $0.date <= now }
                .reduce(0) { $0 + $1.cost },
            sessionSpend: goRows.isEmpty ? nil : goRows
                .filter { $0.date >= fiveHoursAgo && $0.date <= now }
                .reduce(0) { $0 + $1.cost },
            weeklySpend: goRows.isEmpty ? nil : goRows
                .filter { $0.date >= startOfWeek && $0.date <= now }
                .reduce(0) { $0 + $1.cost },
            monthlySpend: goRows.isEmpty ? nil : goRows
                .filter { $0.date >= startOfMonth && $0.date <= now }
                .reduce(0) { $0 + $1.cost },
            sessionResetsAt: oldestSessionDate?.addingTimeInterval(5 * 60 * 60),
            weeklyResetsAt: endOfWeek,
            monthlyResetsAt: endOfMonth,
            history: history
        )
    }

    private func databaseFiles() -> [URL] {
        let directory: URL
        if let configured = ProviderSupport.string(environment["OPENCODE_DATA_DIR"]) {
            directory = URL(fileURLWithPath: configured)
        } else if let xdg = ProviderSupport.string(environment["XDG_DATA_HOME"]) {
            directory = URL(fileURLWithPath: xdg).appendingPathComponent("opencode")
        } else {
            directory = homeDirectory.appendingPathComponent(".local/share/opencode")
        }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return files
            .filter {
                $0.lastPathComponent.hasPrefix("opencode")
                    && $0.pathExtension == "db"
            }
            .sorted { $0.path < $1.path }
    }
}
