import Foundation
import LocalAuthentication
import OSLog
import Security

enum ProviderSupport {
    private static let logger = Logger(
        subsystem: "com.openworkloads.owls.companion",
        category: "credentials"
    )

    static func dictionary(from data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func dictionary(at path: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: path) else { return nil }
        return dictionary(from: data)
    }

    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string)
        }
        return nil
    }

    static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func resetDate(_ value: Any?, now: Date = Date()) -> Date? {
        if let value = number(value) {
            let seconds = abs(value) > 10_000_000_000 ? value / 1_000 : value
            return Date(timeIntervalSince1970: seconds)
        }
        guard let text = string(value) else { return nil }
        return ISO8601DateFormatter().date(from: text)
    }

    static func resetDate(window: [String: Any], now: Date = Date()) -> Date? {
        if let resetAt = resetDate(window["reset_at"], now: now) {
            return resetAt
        }
        if let seconds = number(window["reset_after_seconds"]) {
            return now.addingTimeInterval(seconds)
        }
        return nil
    }

    static func keychainPassword(
        service: String,
        account: String? = nil
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        var arguments = ["find-generic-password"]
        if let account {
            arguments.append(contentsOf: ["-a", account])
        }
        arguments.append(contentsOf: ["-s", service, "-w"])
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            logger.error(
                "Keychain command failed to start for service \(service, privacy: .public)."
            )
            return nil
        }
        guard process.terminationStatus == 0 else {
            logger.info(
                "Keychain read missed service \(service, privacy: .public), account \(account ?? "legacy", privacy: .public), status \(process.terminationStatus)."
            )
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        logger.info(
            "Keychain read succeeded for service \(service, privacy: .public), account \(account ?? "legacy", privacy: .public)."
        )
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func updateKeychainPassword(
        service: String,
        account: String? = nil,
        value: String
    ) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8)
        ]
        let status = SecItemUpdate(
            query as CFDictionary,
            attributes as CFDictionary
        )
        guard status == errSecSuccess else {
            throw UsageReadError.localDataUnreadable(
                "The refreshed client login could not be saved."
            )
        }
    }

    static func protectedKeychainPassword(
        service: String,
        account: String,
        allowInteraction: Bool
    ) throws -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        if !allowInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let password = String(data: data, encoding: .utf8),
                  !password.isEmpty
            else {
                throw UsageReadError.localDataUnreadable(
                    "The protected macOS credential could not be decoded."
                )
            }
            return password
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            throw UsageReadError.credentialPermissionRequired
        default:
            throw UsageReadError.localDataUnreadable(
                "macOS Keychain returned status \(status)."
            )
        }
    }

    static func requestJSON(
        url: URL,
        method: String = "GET",
        headers: [String: String],
        body: Data? = nil
    ) async throws -> (body: [String: Any], response: HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 12
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UsageReadError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw UsageReadError.requestFailed(httpResponse.statusCode)
        }
        guard let body = dictionary(from: data) else {
            throw UsageReadError.invalidResponse
        }
        return (body, httpResponse)
    }

    static func compactNumber(_ value: Double) -> String {
        let absolute = abs(value)
        if absolute >= 1_000_000_000 {
            return String(format: "%.1fB", value / 1_000_000_000)
        }
        if absolute >= 1_000_000 {
            return String(format: "%.1fM", value / 1_000_000)
        }
        if absolute >= 1_000 {
            return String(format: "%.1fK", value / 1_000)
        }
        return String(format: "%.0f", value)
    }

    static func planName(_ value: String?) -> String? {
        guard let value else { return nil }
        return value
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }
}

enum UsageReadError: LocalizedError {
    case notConfigured(String)
    case credentialPermissionRequired
    case requestFailed(Int)
    case invalidResponse
    case localDataUnreadable(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let instruction):
            instruction
        case .credentialPermissionRequired:
            "Press Refresh to allow read-only access to the current Claude Desktop session."
        case .requestFailed(let status):
            status == 401 || status == 403
                ? "The local login cannot read usage. Sign in again with the client."
                : "The usage service returned HTTP \(status)."
        case .invalidResponse:
            "The usage response could not be read."
        case .localDataUnreadable(let detail):
            "Local usage data could not be read: \(detail)"
        }
    }
}
