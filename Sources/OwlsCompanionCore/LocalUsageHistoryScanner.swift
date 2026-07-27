import Foundation

enum LocalUsageHistoryScanner {
    private struct DailyTotal {
        var tokens = 0.0
        var costUSD = 0.0
        var hasCost = false

        mutating func add(tokens: Double, costUSD: Double?) {
            self.tokens += max(tokens, 0)
            if let costUSD {
                self.costUSD += max(costUSD, 0)
                hasCost = true
            }
        }
    }

    static func claude(
        homeDirectory: URL,
        now: Date
    ) async -> [UsageHistoryPoint] {
        await Task.detached(priority: .utility) {
            scanClaude(homeDirectory: homeDirectory, now: now)
        }.value
    }

    static func codex(
        homeDirectory: URL,
        environment: [String: String],
        now: Date
    ) async -> [UsageHistoryPoint] {
        await Task.detached(priority: .utility) {
            scanCodex(
                homeDirectory: homeDirectory,
                environment: environment,
                now: now
            )
        }.value
    }

    private static func scanClaude(
        homeDirectory: URL,
        now: Date
    ) -> [UsageHistoryPoint] {
        let root = homeDirectory.appendingPathComponent(".claude/projects")
        let files = recentJSONLFiles(root: root, now: now)
        let pricing = LocalModelPricing.shared
        var totals: [Date: DailyTotal] = [:]
        var seen: Set<String> = []

        for file in files {
            guard let data = try? Data(contentsOf: file) else { continue }
            for line in data.split(separator: UInt8(ascii: "\n")) {
                guard line.range(of: Data(#""type":"assistant""#.utf8)) != nil,
                      let object = jsonObject(line),
                      let message = object["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any],
                      let timestamp = date(
                          ProviderSupport.string(object["timestamp"])
                      )
                else {
                    continue
                }

                let input = ProviderSupport.number(usage["input_tokens"]) ?? 0
                let output = ProviderSupport.number(usage["output_tokens"]) ?? 0
                let cacheWrite =
                    ProviderSupport.number(
                        usage["cache_creation_input_tokens"]
                    ) ?? 0
                let cacheRead =
                    ProviderSupport.number(
                        usage["cache_read_input_tokens"]
                    ) ?? 0
                let tokenTotal = input + output + cacheWrite + cacheRead
                guard tokenTotal > 0 else { continue }

                let model =
                    ProviderSupport.string(message["model"]) ?? "unknown"
                let identity = [
                    ProviderSupport.string(object["requestId"]) ?? "",
                    ProviderSupport.string(message["id"]) ?? "",
                    model,
                    String(input),
                    String(output),
                    String(cacheWrite),
                    String(cacheRead)
                ].joined(separator: "|")
                guard seen.insert(identity).inserted else { continue }

                let recordedCost =
                    ProviderSupport.number(object["costUSD"])
                    ?? ProviderSupport.number(message["costUSD"])
                let estimatedCost = pricing.resolve(model)?.cost(
                    input: input,
                    output: output,
                    cacheWrite: cacheWrite,
                    cacheRead: cacheRead
                )
                totals[day(for: timestamp), default: DailyTotal()].add(
                    tokens: tokenTotal,
                    costUSD: recordedCost ?? estimatedCost
                )
            }
        }
        return points(totals, now: now)
    }

    private static func scanCodex(
        homeDirectory: URL,
        environment: [String: String],
        now: Date
    ) -> [UsageHistoryPoint] {
        let homes: [URL]
        if let configured = ProviderSupport.string(environment["CODEX_HOME"]) {
            homes = configured
                .split(separator: ",")
                .map {
                    URL(fileURLWithPath: String($0))
                        .standardizedFileURL
                }
        } else {
            homes = [homeDirectory.appendingPathComponent(".codex")]
        }
        let roots = homes.flatMap { home in
            [
                home.appendingPathComponent("sessions"),
                home.appendingPathComponent("archived_sessions")
            ]
        }
        let files = roots.flatMap { recentJSONLFiles(root: $0, now: now) }
        let pricing = LocalModelPricing.shared
        var totals: [Date: DailyTotal] = [:]
        var seen: Set<String> = []

        for file in files {
            guard let data = try? Data(contentsOf: file) else { continue }
            var currentModel = "gpt-5"
            var previous: CodexTokens?
            var childCreatedAt: Date?
            var waitingForLiveChildTurn = false
            var sawSessionMeta = false

            for line in data.split(separator: UInt8(ascii: "\n")) {
                guard let object = jsonObject(line),
                      let type = ProviderSupport.string(object["type"])
                else {
                    continue
                }
                let payload = object["payload"] as? [String: Any]

                if type == "turn_context" {
                    if let model = modelName(payload) {
                        currentModel = model
                    }
                    continue
                }
                if type == "session_meta", !sawSessionMeta {
                    sawSessionMeta = true
                    if isChild(payload) {
                        waitingForLiveChildTurn = true
                        childCreatedAt = date(
                            ProviderSupport.string(object["timestamp"])
                        )
                    }
                    continue
                }
                guard type == "event_msg", let payload else { continue }

                if ProviderSupport.string(payload["type"]) == "task_started",
                   waitingForLiveChildTurn,
                   let startedAt = ProviderSupport.number(payload["started_at"]) {
                    let start = Date(timeIntervalSince1970: startedAt)
                    if childCreatedAt.map({ start >= $0 }) ?? true {
                        waitingForLiveChildTurn = false
                    }
                    continue
                }
                guard ProviderSupport.string(payload["type"]) == "token_count",
                      let timestamp = date(
                          ProviderSupport.string(object["timestamp"])
                      )
                else {
                    continue
                }
                let info = payload["info"] as? [String: Any]
                let total = (info?["total_token_usage"] as? [String: Any])
                    .map(CodexTokens.init)
                if waitingForLiveChildTurn {
                    if let total { previous = total }
                    continue
                }
                if let total, let previous, total == previous {
                    continue
                }
                let tokens: CodexTokens
                if let last = info?["last_token_usage"] as? [String: Any] {
                    tokens = CodexTokens(last)
                } else if let total {
                    tokens = total.subtracting(previous)
                } else {
                    continue
                }
                if let total { previous = total }
                guard tokens.total > 0 else { continue }

                if let model = modelName(payload) ?? modelName(info) {
                    currentModel = model
                }
                let identity = [
                    timestamp.ISO8601Format(),
                    currentModel,
                    String(tokens.input),
                    String(tokens.cached),
                    String(tokens.output),
                    String(tokens.reasoning),
                    String(tokens.total)
                ].joined(separator: "|")
                guard seen.insert(identity).inserted else { continue }

                let cost = pricing.resolve(currentModel)?.cost(
                    input: Double(max(0, tokens.input - tokens.cached)),
                    output: Double(tokens.output),
                    cacheWrite: 0,
                    cacheRead: Double(tokens.cached)
                )
                totals[day(for: timestamp), default: DailyTotal()].add(
                    tokens: Double(tokens.total),
                    costUSD: cost
                )
            }
        }
        return points(totals, now: now)
    }

    private struct CodexTokens: Equatable {
        let input: Int
        let cached: Int
        let output: Int
        let reasoning: Int
        let total: Int

        init(_ value: [String: Any]) {
            input = integer(value, keys: ["input_tokens", "prompt_tokens", "input"])
            cached = integer(
                value,
                keys: [
                    "cached_input_tokens",
                    "cache_read_input_tokens",
                    "cached_tokens"
                ]
            )
            output = integer(
                value,
                keys: ["output_tokens", "completion_tokens", "output"]
            )
            reasoning = integer(
                value,
                keys: ["reasoning_output_tokens", "reasoning_tokens"]
            )
            let reported = integer(value, keys: ["total_tokens"])
            total = reported > 0
                ? reported
                : input + output + reasoning
        }

        private init(
            input: Int,
            cached: Int,
            output: Int,
            reasoning: Int,
            total: Int
        ) {
            self.input = input
            self.cached = cached
            self.output = output
            self.reasoning = reasoning
            self.total = total
        }

        func subtracting(_ previous: CodexTokens?) -> CodexTokens {
            CodexTokens(
                input: max(0, input - (previous?.input ?? 0)),
                cached: max(0, cached - (previous?.cached ?? 0)),
                output: max(0, output - (previous?.output ?? 0)),
                reasoning: max(0, reasoning - (previous?.reasoning ?? 0)),
                total: max(0, total - (previous?.total ?? 0))
            )
        }
    }

    private static func recentJSONLFiles(
        root: URL,
        now: Date
    ) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .contentModificationDateKey
            ],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let cutoff = now.addingTimeInterval(-31 * 86_400)
        return enumerator.compactMap { item in
            guard let url = item as? URL,
                  url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(
                      forKeys: [.isRegularFileKey, .contentModificationDateKey]
                  ),
                  values.isRegularFile == true,
                  values.contentModificationDate.map({ $0 >= cutoff }) ?? true
            else {
                return nil
            }
            return url
        }
    }

    private static func jsonObject(
        _ line: Data.SubSequence
    ) -> [String: Any]? {
        try? JSONSerialization.jsonObject(
            with: Data(line)
        ) as? [String: Any]
    }

    private static func modelName(_ value: [String: Any]?) -> String? {
        guard let value else { return nil }
        for candidate in [
            value["model"],
            value["model_name"],
            (value["metadata"] as? [String: Any])?["model"]
        ] {
            if let model = ProviderSupport.string(candidate) {
                return model
            }
        }
        return nil
    }

    private static func isChild(_ payload: [String: Any]?) -> Bool {
        guard let payload else { return false }
        if hasValue(payload["forked_from_id"])
            || hasValue(payload["parent_thread_id"]) {
            return true
        }
        if ProviderSupport.string(payload["thread_source"]) == "subagent" {
            return true
        }
        if let source = payload["source"] as? [String: Any],
           hasValue(source["subagent"]) {
            return true
        }
        return false
    }

    private static func hasValue(_ value: Any?) -> Bool {
        switch value {
        case nil, is NSNull:
            false
        case let string as String:
            !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default:
            true
        }
    }

    private static func integer(
        _ value: [String: Any],
        keys: [String]
    ) -> Int {
        for key in keys {
            if let number = value[key] as? NSNumber {
                return max(number.intValue, 0)
            }
        }
        return 0
    }

    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        return try? Date(value, strategy: .iso8601)
    }

    private static func day(for date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    private static func points(
        _ totals: [Date: DailyTotal],
        now: Date
    ) -> [UsageHistoryPoint] {
        guard !totals.isEmpty else { return [] }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        return (0..<30).reversed().compactMap { offset in
            guard let date = calendar.date(
                byAdding: .day,
                value: -offset,
                to: today
            ) else {
                return nil
            }
            let value = totals[date] ?? DailyTotal()
            return UsageHistoryPoint(
                date: date,
                tokens: value.tokens,
                costUSD: value.hasCost ? value.costUSD : nil
            )
        }
    }
}
