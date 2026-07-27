import Combine
import Foundation

public enum CompanionUpdateAvailability: Equatable, Sendable {
    case checking
    case current
    case updateAvailable
    case unavailable(String)
}

public struct CompanionUpdateComponent: Equatable, Sendable {
    public let currentVersion: String?
    public let latestVersion: String?
    public let availability: CompanionUpdateAvailability

    public init(
        currentVersion: String?,
        latestVersion: String?,
        availability: CompanionUpdateAvailability
    ) {
        self.currentVersion = currentVersion
        self.latestVersion = latestVersion
        self.availability = availability
    }

    public static var checking: CompanionUpdateComponent {
        CompanionUpdateComponent(
            currentVersion: nil,
            latestVersion: nil,
            availability: .checking
        )
    }
}

public struct CompanionUpdateClient: Sendable {
    private let connectionFile: URL
    private let cliManifestURL: URL
    private let companionManifestURL: URL
    private let session: URLSession

    public init(
        connectionFile: URL = CompanionPaths.connectionFile(),
        cliManifestURL: URL = URL(
            string: "https://raw.githubusercontent.com/OpenWorkloads/owls/main/package.json"
        )!,
        companionManifestURL: URL = URL(
            string: "https://raw.githubusercontent.com/OpenWorkloads/owls-companion/main/update.json"
        )!,
        session: URLSession = .shared
    ) {
        self.connectionFile = connectionFile
        self.cliManifestURL = cliManifestURL
        self.companionManifestURL = companionManifestURL
        self.session = session
    }

    public func statuses(
        currentCompanionVersion: String
    ) async -> (
        cli: CompanionUpdateComponent,
        companion: CompanionUpdateComponent
    ) {
        let currentCLIVersion = loadConnection()?.cliVersion
        async let latestCLIResult = fetchVersion(cliManifestURL)
        async let latestCompanionResult = fetchVersion(companionManifestURL)

        let cli = await component(
            currentVersion: currentCLIVersion,
            latestResult: latestCLIResult,
            missingCurrentMessage: "Open this app through the owls CLI to check its version."
        )
        let companion = await component(
            currentVersion: currentCompanionVersion,
            latestResult: latestCompanionResult,
            missingCurrentMessage: "The installed companion version is unavailable."
        )
        return (cli, companion)
    }

    private func loadConnection() -> CompanionConnectionConfiguration? {
        guard let data = try? Data(contentsOf: connectionFile) else {
            return nil
        }
        return try? JSONDecoder().decode(
            CompanionConnectionConfiguration.self,
            from: data
        )
    }

    private func fetchVersion(
        _ url: URL
    ) async -> Result<String, UpdateCheckError> {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.cachePolicy = .reloadRevalidatingCacheData
        request.setValue(
            "owls Companion",
            forHTTPHeaderField: "User-Agent"
        )

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode)
            else {
                return .failure(.manifestUnavailable)
            }
            let document = try JSONDecoder().decode(
                RepositoryVersionDocument.self,
                from: data
            )
            return .success(document.version)
        } catch {
            return .failure(.manifestUnavailable)
        }
    }

    private func component(
        currentVersion: String?,
        latestResult: Result<String, UpdateCheckError>,
        missingCurrentMessage: String
    ) async -> CompanionUpdateComponent {
        guard let currentVersion else {
            return CompanionUpdateComponent(
                currentVersion: nil,
                latestVersion: try? latestResult.get(),
                availability: .unavailable(missingCurrentMessage)
            )
        }

        switch latestResult {
        case let .success(latestVersion):
            return CompanionUpdateComponent(
                currentVersion: currentVersion,
                latestVersion: latestVersion,
                availability: isNewerVersion(
                    latestVersion,
                    than: currentVersion
                ) ? .updateAvailable : .current
            )
        case .failure:
            return CompanionUpdateComponent(
                currentVersion: currentVersion,
                latestVersion: nil,
                availability: .unavailable(
                    "The latest version could not be checked."
                )
            )
        }
    }
}

@MainActor
public final class CompanionUpdateStore: ObservableObject {
    public static let shared = CompanionUpdateStore()

    @Published public private(set) var cli = CompanionUpdateComponent.checking
    @Published public private(set) var companion = CompanionUpdateComponent.checking
    @Published public private(set) var isRefreshing = false

    private let client: CompanionUpdateClient
    private let currentCompanionVersion: String

    public init(
        client: CompanionUpdateClient = CompanionUpdateClient(),
        currentCompanionVersion: String = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0.0.0"
    ) {
        self.client = client
        self.currentCompanionVersion = currentCompanionVersion
    }

    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let result = await client.statuses(
            currentCompanionVersion: currentCompanionVersion
        )
        cli = result.cli
        companion = result.companion
    }
}

public func isNewerVersion(
    _ candidate: String,
    than current: String
) -> Bool {
    let candidateParts = versionParts(candidate)
    let currentParts = versionParts(current)
    let count = max(candidateParts.count, currentParts.count)

    for index in 0..<count {
        let candidatePart = index < candidateParts.count
            ? candidateParts[index]
            : 0
        let currentPart = index < currentParts.count
            ? currentParts[index]
            : 0
        if candidatePart != currentPart {
            return candidatePart > currentPart
        }
    }
    return false
}

private struct RepositoryVersionDocument: Decodable {
    let version: String
}

private enum UpdateCheckError: Error {
    case manifestUnavailable
}

private func versionParts(_ value: String) -> [Int] {
    value
        .split(separator: "-", maxSplits: 1)
        .first?
        .split(separator: ".")
        .map { Int($0) ?? 0 } ?? []
}
