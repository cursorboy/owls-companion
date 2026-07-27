import Foundation
import OSLog

public struct SessionPrimerResult: Sendable {
    public let succeeded: Bool
    public let message: String
    public let costUSD: Double?
    public let totalTokens: Double?

    public init(
        succeeded: Bool,
        message: String,
        costUSD: Double? = nil,
        totalTokens: Double? = nil
    ) {
        self.succeeded = succeeded
        self.message = message
        self.costUSD = costUSD
        self.totalTokens = totalTokens
    }
}

/// Opens a Claude session window by sending one very small prompt through the
/// installed `claude` command in print mode.
public enum SessionPrimer {
    private static let logger = Logger(
        subsystem: "com.openworkloads.owls.companion",
        category: "schedule"
    )

    private static let timeout: TimeInterval = 120

    /// Places the `claude` command is normally installed. A menu bar app
    /// inherits a bare PATH from launchd, so the binary is located by hand
    /// rather than left to the shell.
    public static func candidateExecutablePaths(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        [
            homeDirectory.appendingPathComponent(".local/bin/claude"),
            homeDirectory.appendingPathComponent(".claude/local/claude"),
            homeDirectory.appendingPathComponent(".bun/bin/claude"),
            homeDirectory.appendingPathComponent(".volta/bin/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
            URL(fileURLWithPath: "/usr/bin/claude")
        ]
    }

    public static func resolveExecutable(
        override: String?,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL? {
        if let override,
           !override.trimmingCharacters(in: .whitespaces).isEmpty {
            let url = URL(
                fileURLWithPath: (override as NSString).expandingTildeInPath
            )
            return fileManager.isExecutableFile(atPath: url.path) ? url : nil
        }
        return candidateExecutablePaths(homeDirectory: homeDirectory).first {
            fileManager.isExecutableFile(atPath: $0.path)
        }
    }

    /// A working directory of its own, so the prompt never picks up a
    /// `CLAUDE.md` from one of the person's projects and never writes into one.
    public static func workingDirectory(
        fileManager: FileManager = .default
    ) -> URL {
        let directory = CompanionPaths
            .applicationSupportDirectory(fileManager: fileManager)
            .appendingPathComponent("session-primer", isDirectory: true)
        try? fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    public static func run(
        settings: SessionScheduleSettings,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> SessionPrimerResult {
        guard let executable = resolveExecutable(
            override: settings.executablePathOverride,
            homeDirectory: homeDirectory
        ) else {
            return SessionPrimerResult(
                succeeded: false,
                message: "The claude command was not found. "
                    + "Set its path in Settings."
            )
        }

        let prompt = settings.prompt.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let arguments = [
            "--print",
            prompt.isEmpty ? SessionScheduleSettings.defaultPrompt : prompt,
            "--model", settings.model,
            "--output-format", "json",
            "--max-turns", "1",
            // Replacing the system prompt, dropping the tool set, and skipping
            // MCP servers keeps the priming request roughly half the size of a
            // normal one.
            "--system-prompt", "Reply with one word.",
            "--strict-mcp-config",
            "--mcp-config", #"{"mcpServers":{}}"#,
            "--disallowedTools", Self.disallowedTools
        ]

        let workingDirectory = workingDirectory()
        let processEnvironment = Self.processEnvironment(
            from: environment,
            homeDirectory: homeDirectory
        )

        return await withCheckedContinuation { continuation in
            Task.detached(priority: .utility) {
                let result = Self.execute(
                    executable: executable,
                    arguments: arguments,
                    workingDirectory: workingDirectory,
                    environment: processEnvironment
                )
                continuation.resume(returning: result)
            }
        }
    }

    private static let disallowedTools = [
        "Bash", "Edit", "Write", "Read", "Glob", "Grep", "WebFetch",
        "WebSearch", "Task", "NotebookEdit", "TodoWrite", "BashOutput",
        "KillShell", "SlashCommand", "ExitPlanMode"
    ].joined(separator: ",")

    /// launchd hands a GUI app a very small environment. `claude` needs at
    /// least HOME and the user name to find the login, so those are filled in
    /// when they are missing.
    private static func processEnvironment(
        from environment: [String: String],
        homeDirectory: URL
    ) -> [String: String] {
        var result = environment
        result["HOME"] = homeDirectory.path
        let user = environment["USER"] ?? NSUserName()
        result["USER"] = user
        result["LOGNAME"] = environment["LOGNAME"] ?? user
        result["SHELL"] = environment["SHELL"] ?? "/bin/zsh"
        let path = environment["PATH"] ?? ""
        let extraPaths = [
            homeDirectory.appendingPathComponent(".local/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ]
        var pathEntries = path.split(separator: ":").map(String.init)
        for entry in extraPaths where !pathEntries.contains(entry) {
            pathEntries.append(entry)
        }
        result["PATH"] = pathEntries.joined(separator: ":")
        // Marks the request in Claude Code's own telemetry as coming from here
        // rather than from a person at a terminal.
        result["CLAUDE_CODE_ENTRYPOINT"] = "owls-companion-schedule"
        return result
    }

    private static func execute(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String]
    ) -> SessionPrimerResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment

        let output = Pipe()
        let errorOutput = Pipe()
        process.standardOutput = output
        process.standardError = errorOutput
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            logger.error(
                "Session primer failed to start: \(error.localizedDescription, privacy: .public)"
            )
            return SessionPrimerResult(
                succeeded: false,
                message: "The claude command could not be started."
            )
        }

        // Drain both pipes while waiting so a chatty run cannot fill the pipe
        // buffer and deadlock the child.
        let outputData = UnsafeSendableBox(Data())
        let errorData = UnsafeSendableBox(Data())
        let readGroup = DispatchGroup()
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            outputData.value = output.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            errorData.value = errorOutput.fileHandleForReading
                .readDataToEndOfFile()
            readGroup.leave()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        if process.isRunning {
            process.terminate()
            _ = readGroup.wait(timeout: .now() + 5)
            return SessionPrimerResult(
                succeeded: false,
                message: "The claude command did not finish within "
                    + "\(Int(timeout)) seconds."
            )
        }
        process.waitUntilExit()
        _ = readGroup.wait(timeout: .now() + 5)

        return parse(
            standardOutput: outputData.value,
            standardError: errorData.value,
            terminationStatus: process.terminationStatus
        )
    }

    static func parse(
        standardOutput: Data,
        standardError: Data,
        terminationStatus: Int32
    ) -> SessionPrimerResult {
        let body = ProviderSupport.dictionary(from: standardOutput)
        let isError = (body?["is_error"] as? Bool) ?? (terminationStatus != 0)
        let cost = ProviderSupport.number(body?["total_cost_usd"])
        let tokens = (body?["usage"] as? [String: Any]).map(totalTokens)

        if isError {
            let reported = ProviderSupport.string(body?["result"])
                ?? String(data: standardError, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = reported?.isEmpty == false
                ? reported!
                : "exit status \(terminationStatus)"
            logger.error(
                "Session primer failed: \(detail, privacy: .public)"
            )
            return SessionPrimerResult(
                succeeded: false,
                message: String(detail.prefix(200)),
                costUSD: cost,
                totalTokens: tokens
            )
        }

        logger.info("Session primer opened a window.")
        return SessionPrimerResult(
            succeeded: true,
            message: "The session window is open.",
            costUSD: cost,
            totalTokens: tokens
        )
    }

    private static func totalTokens(_ usage: [String: Any]) -> Double {
        [
            "input_tokens",
            "output_tokens",
            "cache_creation_input_tokens",
            "cache_read_input_tokens"
        ]
        .compactMap { ProviderSupport.number(usage[$0]) }
        .reduce(0, +)
    }
}

/// A small mutable box for handing pipe output back from the reader queues.
/// Access is fenced by the dispatch group, which is why the check is waived.
private final class UnsafeSendableBox<Value>: @unchecked Sendable {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
