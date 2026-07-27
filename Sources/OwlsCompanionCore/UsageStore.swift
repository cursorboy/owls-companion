import Combine
import Foundation

@MainActor
public final class UsageStore: ObservableObject {
    public static let shared = UsageStore()

    @Published public private(set) var snapshots: [ProviderUsageSnapshot] = []
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var lastRefresh: Date?

    private let providers: [any UsageProvider]
    private let refreshInterval: Duration
    private let cacheFile: URL
    private var refreshLoop: Task<Void, Never>?

    public init(
        providers: [any UsageProvider]? = nil,
        refreshInterval: Duration = .seconds(300),
        cacheFile: URL? = nil
    ) {
        self.providers = providers ?? [
            ClaudeUsageProvider(),
            CodexUsageProvider(),
            OpenCodeUsageProvider()
        ]
        self.refreshInterval = refreshInterval
        self.cacheFile = cacheFile ?? CompanionPaths.usageCacheFile()
        loadCache()
    }

    deinit {
        refreshLoop?.cancel()
    }

    public func start() {
        guard refreshLoop == nil else { return }
        refreshLoop = Task { [weak self] in
            guard let self else { return }
            await refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: refreshInterval)
                guard !Task.isCancelled else { return }
                await refresh()
            }
        }
    }

    public func refresh(
        allowCredentialInteraction: Bool = false
    ) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        async let claude = refreshProvider(
            .claude,
            allowCredentialInteraction: allowCredentialInteraction
        )
        async let codex = refreshProvider(
            .codex,
            allowCredentialInteraction: allowCredentialInteraction
        )
        async let opencode = refreshProvider(
            .opencode,
            allowCredentialInteraction: allowCredentialInteraction
        )
        snapshots = await [claude, codex, opencode]
        lastRefresh = Date()
        saveCache()
    }

    private func refreshProvider(
        _ id: UsageProviderID,
        allowCredentialInteraction: Bool
    ) async -> ProviderUsageSnapshot {
        guard let provider = providers.first(where: { $0.id == id }) else {
            return .failure(id: id, message: "Provider adapter is unavailable.", source: "Local")
        }
        return await provider.refresh(
            allowCredentialInteraction: allowCredentialInteraction
        )
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheFile),
              let decoded = try? JSONDecoder.openWorkloads.decode(
                  CacheDocument.self,
                  from: data
              )
        else {
            return
        }
        snapshots = decoded.snapshots
        lastRefresh = decoded.savedAt
    }

    private func saveCache() {
        let document = CacheDocument(savedAt: Date(), snapshots: snapshots)
        guard let data = try? JSONEncoder.openWorkloads.encode(document) else { return }
        do {
            try FileManager.default.createDirectory(
                at: cacheFile.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: cacheFile, options: .atomic)
        } catch {
            return
        }
    }

}

private struct CacheDocument: Codable {
    let savedAt: Date
    let snapshots: [ProviderUsageSnapshot]
}

private extension JSONEncoder {
    static var openWorkloads: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var openWorkloads: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
