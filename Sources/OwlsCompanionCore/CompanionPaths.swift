import Foundation

public enum CompanionPaths {
    public static func applicationSupportDirectory(
        fileManager: FileManager = .default
    ) -> URL {
        let root = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
        return root.appendingPathComponent(
            "owls Companion",
            isDirectory: true
        )
    }

    public static func connectionFile(
        fileManager: FileManager = .default
    ) -> URL {
        applicationSupportDirectory(fileManager: fileManager)
            .appendingPathComponent("connection.json")
    }

    public static func usageCacheFile(
        fileManager: FileManager = .default
    ) -> URL {
        applicationSupportDirectory(fileManager: fileManager)
            .appendingPathComponent("usage-cache.json")
    }
}
