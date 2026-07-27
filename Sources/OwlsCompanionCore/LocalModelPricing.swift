import Foundation

struct LocalModelRates: Sendable {
    let inputPerMillion: Double
    let outputPerMillion: Double
    let cacheWritePerMillion: Double
    let cacheReadPerMillion: Double

    func cost(
        input: Double,
        output: Double,
        cacheWrite: Double,
        cacheRead: Double
    ) -> Double {
        (
            input * inputPerMillion
                + output * outputPerMillion
                + cacheWrite * cacheWritePerMillion
                + cacheRead * cacheReadPerMillion
        ) / 1_000_000
    }
}

final class LocalModelPricing: @unchecked Sendable {
    static let shared = LocalModelPricing()

    private struct AliasRule {
        let expression: NSRegularExpression
        let canonical: String
    }

    private let rates: [String: LocalModelRates]
    private let aliases: [AliasRule]

    private init(bundle: Bundle? = nil) {
        var loadedRates: [String: LocalModelRates] = [:]
        var loadedAliases: [AliasRule] = []
        let primaryBundle = bundle ?? .main

        func resourceURL(
            _ name: String
        ) -> URL? {
            if let url = primaryBundle.url(
                forResource: name,
                withExtension: "json"
            ) {
                return url
            }
            guard bundle == nil else { return nil }
            return Bundle.module.url(
                forResource: name,
                withExtension: "json",
                subdirectory: "Resources"
            )
        }

        if let url = resourceURL("pricing_litellm_snapshot"),
        let data = try? Data(contentsOf: url),
        let root = ProviderSupport.dictionary(from: data),
        let models = root["models"] as? [String: Any] {
            for (name, value) in models {
                guard let dictionary = value as? [String: Any],
                      let parsed = Self.shortRates(dictionary)
                else {
                    continue
                }
                loadedRates[name.lowercased()] = parsed
            }
        }

        if let url = resourceURL("pricing_supplement"),
        let data = try? Data(contentsOf: url),
        let root = ProviderSupport.dictionary(from: data) {
            if let pricing = root["pricing"] as? [String: Any] {
                for (name, value) in pricing {
                    guard let dictionary = value as? [String: Any],
                          let parsed = Self.longRates(dictionary)
                    else {
                        continue
                    }
                    loadedRates[name.lowercased()] = parsed
                }
            }
            if let rules = root["alias_rules"] as? [[String: Any]] {
                for rule in rules {
                    guard let pattern = ProviderSupport.string(rule["pattern"]),
                          let canonical = ProviderSupport.string(rule["canonical"]),
                          let expression = try? NSRegularExpression(
                              pattern: pattern,
                              options: [.caseInsensitive]
                          )
                    else {
                        continue
                    }
                    loadedAliases.append(AliasRule(
                        expression: expression,
                        canonical: canonical.lowercased()
                    ))
                }
            }
        }

        rates = loadedRates
        aliases = loadedAliases
    }

    func resolve(_ model: String) -> LocalModelRates? {
        let normalized = model
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return nil }

        let canonical = aliases.first { rule in
            let range = NSRange(normalized.startIndex..., in: normalized)
            return rule.expression.firstMatch(
                in: normalized,
                options: [],
                range: range
            ) != nil
        }?.canonical ?? normalized

        if let exact = rates[canonical] {
            return exact
        }

        let undated = canonical
            .replacingOccurrences(
                of: #"-\d{4}-\d{2}-\d{2}$"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"-\d{8}$"#,
                with: "",
                options: .regularExpression
            )
        if let exact = rates[undated] {
            return exact
        }

        return rates
            .filter { name, _ in
                name.hasSuffix("/\(undated)")
                    || name.hasSuffix(".\(undated)")
            }
            .min { $0.key.count < $1.key.count }?
            .value
    }

    private static func shortRates(
        _ dictionary: [String: Any]
    ) -> LocalModelRates? {
        guard let input = ProviderSupport.number(dictionary["i"]),
              let output = ProviderSupport.number(dictionary["o"])
        else {
            return nil
        }
        return LocalModelRates(
            inputPerMillion: input,
            outputPerMillion: output,
            cacheWritePerMillion:
                ProviderSupport.number(dictionary["cw"]) ?? input,
            cacheReadPerMillion:
                ProviderSupport.number(dictionary["cr"]) ?? input
        )
    }

    private static func longRates(
        _ dictionary: [String: Any]
    ) -> LocalModelRates? {
        guard let input = ProviderSupport.number(
            dictionary["input_per_million"]
        ),
        let output = ProviderSupport.number(
            dictionary["output_per_million"]
        )
        else {
            return nil
        }
        return LocalModelRates(
            inputPerMillion: input,
            outputPerMillion: output,
            cacheWritePerMillion:
                ProviderSupport.number(
                    dictionary["cache_write_per_million"]
                ) ?? input,
            cacheReadPerMillion:
                ProviderSupport.number(
                    dictionary["cache_read_per_million"]
                ) ?? input
        )
    }
}
