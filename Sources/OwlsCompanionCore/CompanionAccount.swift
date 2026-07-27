import Combine
import Foundation

public struct CompanionConnectionConfiguration: Codable, Sendable {
    public let authUrl: String
    public let credentialsPath: String
    public let cliVersion: String?

    public init(
        authUrl: String,
        credentialsPath: String,
        cliVersion: String? = nil
    ) {
        self.authUrl = authUrl
        self.credentialsPath = credentialsPath
        self.cliVersion = cliVersion
    }
}

public struct CompanionAccount: Equatable, Sendable {
    public let id: String
    public let name: String
    public let email: String
    public let imageURL: URL?
    public let emailVerified: Bool
    public let sessionID: String
    public let sessionExpiresAt: Date?
    public let authURL: URL

    public init(
        id: String,
        name: String,
        email: String,
        imageURL: URL?,
        emailVerified: Bool,
        sessionID: String,
        sessionExpiresAt: Date?,
        authURL: URL
    ) {
        self.id = id
        self.name = name
        self.email = email
        self.imageURL = imageURL
        self.emailVerified = emailVerified
        self.sessionID = sessionID
        self.sessionExpiresAt = sessionExpiresAt
        self.authURL = authURL
    }
}

public enum CompanionAccountState: Equatable, Sendable {
    case loading
    case signedOut(String)
    case signedIn(CompanionAccount)
    case unavailable(String)
}

public enum CompanionAccountError: LocalizedError, Equatable {
    case missingConnection
    case invalidConnection
    case missingCredentials
    case expiredCredentials
    case invalidAuthURL
    case unauthorized
    case server(Int)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .missingConnection:
            "Open this app with `owls companion open` so it can find your CLI session."
        case .invalidConnection:
            "The companion connection configuration is invalid. Reopen it with the CLI."
        case .missingCredentials:
            "No owls session was found. Run `owls login` in your terminal."
        case .expiredCredentials:
            "Your owls session has expired. Run `owls login` again."
        case .invalidAuthURL:
            "The configured authentication URL is invalid."
        case .unauthorized:
            "Your owls session could not be verified. Run `owls login` again."
        case let .server(status):
            "The authentication service returned HTTP \(status)."
        case .invalidResponse:
            "The authentication service returned an invalid account response."
        }
    }

    var isSignedOut: Bool {
        switch self {
        case .missingCredentials, .expiredCredentials, .unauthorized:
            true
        default:
            false
        }
    }
}

public struct CompanionAccountClient: Sendable {
    private let connectionFile: URL
    private let session: URLSession

    public init(
        connectionFile: URL = CompanionPaths.connectionFile(),
        session: URLSession = .shared
    ) {
        self.connectionFile = connectionFile
        self.session = session
    }

    public func fetch() async throws -> CompanionAccount {
        let connectionData: Data
        do {
            connectionData = try Data(contentsOf: connectionFile)
        } catch {
            throw CompanionAccountError.missingConnection
        }

        let connection: CompanionConnectionConfiguration
        do {
            connection = try JSONDecoder().decode(
                CompanionConnectionConfiguration.self,
                from: connectionData
            )
        } catch {
            throw CompanionAccountError.invalidConnection
        }

        let credentialsData: Data
        do {
            credentialsData = try Data(
                contentsOf: URL(fileURLWithPath: connection.credentialsPath)
            )
        } catch {
            throw CompanionAccountError.missingCredentials
        }

        let credentials: StoredCompanionCredentials
        do {
            credentials = try JSONDecoder().decode(
                StoredCompanionCredentials.self,
                from: credentialsData
            )
        } catch {
            throw CompanionAccountError.missingCredentials
        }

        if let expiresAt = credentials.expiresAt.flatMap(parseDate),
           expiresAt <= Date() {
            throw CompanionAccountError.expiredCredentials
        }

        let normalizedAuthURL = connection.authUrl.hasSuffix("/")
            ? String(connection.authUrl.dropLast())
            : connection.authUrl
        guard let authURL = URL(string: normalizedAuthURL),
              let endpoint = URL(
                string: "\(normalizedAuthURL)/api/auth/get-session"
              )
        else {
            throw CompanionAccountError.invalidAuthURL
        }

        var request = URLRequest(url: endpoint)
        request.setValue(
            "Bearer \(credentials.accessToken)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(
            "owls Companion",
            forHTTPHeaderField: "User-Agent"
        )
        request.timeoutInterval = 12

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CompanionAccountError.server(0)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CompanionAccountError.invalidResponse
        }
        if httpResponse.statusCode == 401 {
            throw CompanionAccountError.unauthorized
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw CompanionAccountError.server(httpResponse.statusCode)
        }

        let document: AccountSessionDocument
        do {
            document = try JSONDecoder().decode(
                AccountSessionDocument.self,
                from: data
            )
        } catch {
            throw CompanionAccountError.invalidResponse
        }

        return CompanionAccount(
            id: document.user.id,
            name: document.user.name,
            email: document.user.email,
            imageURL: document.user.image.flatMap(URL.init(string:)),
            emailVerified: document.user.emailVerified,
            sessionID: document.session.id,
            sessionExpiresAt: parseDate(document.session.expiresAt),
            authURL: authURL
        )
    }
}

@MainActor
public final class CompanionAccountStore: ObservableObject {
    public static let shared = CompanionAccountStore()

    @Published public private(set) var state: CompanionAccountState = .loading
    @Published public private(set) var isRefreshing = false

    private let client: CompanionAccountClient

    public init(client: CompanionAccountClient = CompanionAccountClient()) {
        self.client = client
    }

    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            state = .signedIn(try await client.fetch())
        } catch let accountError as CompanionAccountError {
            let message = accountError.errorDescription ?? "Account unavailable."
            state = accountError.isSignedOut
                ? .signedOut(message)
                : .unavailable(message)
        } catch {
            state = .unavailable(error.localizedDescription)
        }
    }
}

private struct StoredCompanionCredentials: Decodable {
    let accessToken: String
    let expiresAt: String?
}

private struct AccountSessionDocument: Decodable {
    let user: AccountUserDocument
    let session: AccountSessionDetailsDocument
}

private struct AccountUserDocument: Decodable {
    let id: String
    let name: String
    let email: String
    let image: String?
    let emailVerified: Bool
}

private struct AccountSessionDetailsDocument: Decodable {
    let id: String
    let expiresAt: String
}

private func parseDate(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [
        .withInternetDateTime,
        .withFractionalSeconds
    ]
    if let date = formatter.date(from: value) {
        return date
    }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
}
