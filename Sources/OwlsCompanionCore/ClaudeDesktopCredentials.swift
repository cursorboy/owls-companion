import CommonCrypto
import CryptoKit
import Foundation

struct ClaudeDesktopCredential {
    let accessToken: String
    let expiresAt: Double
    let subscriptionType: String?
    let rateLimitTier: String?
}

enum ClaudeDesktopCredentials {
    private static let apiHost = "https://api.anthropic.com"
    private static let usageScope = "user:profile"
    private static let inferenceScope = "user:inference"
    private static let productionClientID =
        "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let expiryMarginMilliseconds = 2 * 60 * 1_000.0

    static func load(
        homeDirectory: URL,
        now: Date,
        allowInteraction: Bool
    ) throws -> ClaudeDesktopCredential? {
        let support = homeDirectory
            .appendingPathComponent("Library/Application Support/Claude")
        let config = support.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: config),
              let root = ProviderSupport.dictionary(from: data)
        else {
            return nil
        }
        guard let password = try ProviderSupport.protectedKeychainPassword(
            service: "Claude Safe Storage",
            account: "Claude Key",
            allowInteraction: allowInteraction
        ),
              let key = try? deriveKey(password: password),
              let organization = activeOrganization(
                  supportDirectory: support,
                  key: key
              )
        else {
            return nil
        }

        let v2 = decodeCache(root["oauth:tokenCacheV2"], key: key)
        let v1 = decodeCache(root["oauth:tokenCache"], key: key)
        return selectCredential(
            organization: organization,
            v2: v2,
            v1: v1,
            now: now
        )
    }

    private static func activeOrganization(
        supportDirectory: URL,
        key: Data
    ) -> String? {
        let candidates = [
            supportDirectory.appendingPathComponent("Cookies"),
            supportDirectory.appendingPathComponent("Network/Cookies")
        ]
        for database in candidates
        where FileManager.default.fileExists(atPath: database.path) {
            for host in [".claude.ai", "claude.ai"] {
                let escapedHost = host.replacingOccurrences(
                    of: "'",
                    with: "''"
                )
                let sql = """
                SELECT CASE
                    WHEN length(value) > 0
                        THEN 'plain:' || hex(CAST(value AS BLOB))
                    ELSE 'encrypted:' || hex(encrypted_value)
                END
                FROM cookies
                WHERE name = 'lastActiveOrg'
                  AND host_key = '\(escapedHost)'
                ORDER BY last_update_utc DESC
                LIMIT 1;
                """
                guard let encoded = sqliteValue(
                    database: database,
                    sql: sql
                ),
                let separator = encoded.firstIndex(of: ":"),
                let stored = Data(
                    hexEncoded: String(
                        encoded[encoded.index(after: separator)...]
                    )
                )
                else {
                    continue
                }

                let mode = String(encoded[..<separator])
                let decoded: Data
                if mode == "plain" {
                    decoded = stored
                } else if mode == "encrypted",
                          let decrypted = try? decrypt(stored, key: key) {
                    let hostHash = Data(
                        SHA256.hash(data: Data(host.utf8))
                    )
                    guard decrypted.starts(with: hostHash) else {
                        continue
                    }
                    decoded = decrypted.dropFirst(hostHash.count)
                } else {
                    continue
                }
                guard let value = String(data: decoded, encoding: .utf8),
                      UUID(uuidString: value) != nil
                else {
                    continue
                }
                return value.lowercased()
            }
        }
        return nil
    }

    private static func decodeCache(
        _ stored: Any?,
        key: Data
    ) -> [String: Any]? {
        guard let base64 = stored as? String,
              let encrypted = Data(base64Encoded: base64),
              let plaintext = try? decrypt(encrypted, key: key)
        else {
            return nil
        }
        return ProviderSupport.dictionary(from: plaintext)
    }

    private static func selectCredential(
        organization: String,
        v2: [String: Any]?,
        v1: [String: Any]?,
        now: Date
    ) -> ClaudeDesktopCredential? {
        let v2Candidates = candidates(
            cache: v2,
            organization: organization,
            now: now
        )
        let v2Keys = Set(v2?.keys ?? Dictionary<String, Any>().keys)
        let remainingV1 = v1?.filter { !v2Keys.contains($0.key) }
        let all = v2Candidates + candidates(
            cache: remainingV1,
            organization: organization,
            now: now
        )
        return all.max(by: { isLowerRank($0, than: $1) })?.credential
    }

    private struct Candidate {
        let credential: ClaudeDesktopCredential
        let productionAndFullScope: Bool
        let fullScope: Bool
        let scopeCount: Int
    }

    private static func candidates(
        cache: [String: Any]?,
        organization: String,
        now: Date
    ) -> [Candidate] {
        guard let cache else { return [] }
        return cache.compactMap { key, value in
            guard let parsed = parseCacheKey(key),
                  parsed.organization == organization,
                  parsed.apiHost == apiHost,
                  parsed.scopes.contains(usageScope),
                  let entry = value as? [String: Any],
                  let token = ProviderSupport.string(entry["token"]),
                  let expiresAt = ProviderSupport.number(entry["expiresAt"]),
                  expiresAt > now.timeIntervalSince1970 * 1_000
                    + expiryMarginMilliseconds
            else {
                return nil
            }
            let fullScope = parsed.scopes.contains(usageScope)
                && parsed.scopes.contains(inferenceScope)
            return Candidate(
                credential: ClaudeDesktopCredential(
                    accessToken: token,
                    expiresAt: expiresAt,
                    subscriptionType: ProviderSupport.string(
                        entry["subscriptionType"]
                    ),
                    rateLimitTier: ProviderSupport.string(
                        entry["rateLimitTier"]
                    )
                ),
                productionAndFullScope:
                    parsed.clientID == productionClientID && fullScope,
                fullScope: fullScope,
                scopeCount: parsed.scopes.count
            )
        }
    }

    private static func isLowerRank(
        _ left: Candidate,
        than right: Candidate
    ) -> Bool {
        if left.productionAndFullScope != right.productionAndFullScope {
            return !left.productionAndFullScope
        }
        if left.fullScope != right.fullScope {
            return !left.fullScope
        }
        if left.scopeCount != right.scopeCount {
            return left.scopeCount < right.scopeCount
        }
        return left.credential.expiresAt < right.credential.expiresAt
    }

    private struct CacheKey {
        let clientID: String
        let organization: String
        let apiHost: String
        let scopes: [String]
    }

    private static func parseCacheKey(_ value: String) -> CacheKey? {
        let marker = ":\(apiHost):"
        guard let markerRange = value.range(of: marker) else {
            return nil
        }
        let prefix = value[..<markerRange.lowerBound]
        guard let separator = prefix.firstIndex(of: ":") else {
            return nil
        }
        let clientID = String(prefix[..<separator])
        let organization = String(
            prefix[prefix.index(after: separator)...]
        ).lowercased()
        guard UUID(uuidString: clientID) != nil,
              UUID(uuidString: organization) != nil
        else {
            return nil
        }
        let scopes = value[markerRange.upperBound...]
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        return CacheKey(
            clientID: clientID,
            organization: organization,
            apiHost: apiHost,
            scopes: scopes
        )
    }

    private static func sqliteValue(
        database: URL,
        sql: String
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            "-readonly",
            "-noheader",
            database.path,
            sql
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func deriveKey(password: String) throws -> Data {
        let passwordData = Data(password.utf8)
        let salt = Data("saltysalt".utf8)
        var key = Data(count: kCCKeySizeAES128)
        let keyCount = key.count
        let result = key.withUnsafeMutableBytes { keyBytes in
            passwordData.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(
                            to: Int8.self
                        ).baseAddress,
                        passwordData.count,
                        saltBytes.bindMemory(
                            to: UInt8.self
                        ).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        keyBytes.bindMemory(to: UInt8.self).baseAddress,
                        keyCount
                    )
                }
            }
        }
        guard result == kCCSuccess else {
            throw UsageReadError.localDataUnreadable(
                "Claude Desktop safe storage could not be opened."
            )
        }
        return key
    }

    private static func decrypt(
        _ encrypted: Data,
        key: Data
    ) throws -> Data {
        guard encrypted.count > 3,
              encrypted.prefix(3) == Data("v10".utf8),
              key.count == kCCKeySizeAES128
        else {
            throw UsageReadError.localDataUnreadable(
                "Claude Desktop credentials use an unsupported format."
            )
        }
        let payload = encrypted.dropFirst(3)
        let initializationVector = Data(
            repeating: 0x20,
            count: kCCBlockSizeAES128
        )
        var output = Data(count: payload.count + kCCBlockSizeAES128)
        var outputLength = 0
        let outputCapacity = output.count
        let status = output.withUnsafeMutableBytes { outputBytes in
            payload.withUnsafeBytes { payloadBytes in
                key.withUnsafeBytes { keyBytes in
                    initializationVector.withUnsafeBytes { vectorBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            vectorBytes.baseAddress,
                            payloadBytes.baseAddress,
                            payload.count,
                            outputBytes.baseAddress,
                            outputCapacity,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw UsageReadError.localDataUnreadable(
                "Claude Desktop credentials could not be decrypted."
            )
        }
        output.count = outputLength
        return output
    }
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
