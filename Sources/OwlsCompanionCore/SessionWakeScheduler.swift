import Foundation
import OSLog

public enum SessionWakeError: LocalizedError {
    case cancelledByUser
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .cancelledByUser:
            "Authorisation was cancelled, so the wake schedule was not changed."
        case .commandFailed(let detail):
            "The wake schedule could not be set: \(detail)"
        }
    }
}

/// Asks macOS to wake the Mac at the anchor times.
///
/// A sleeping Mac suspends this app, so an anchor cannot fire on its own.
/// macOS will wake the machine for a scheduled power event, which it does even
/// with the lid shut while on mains power. Events are tagged with an owner so
/// only the ones this app made are ever cancelled.
public enum SessionWakeScheduler {
    public static let owner = "owls Companion"

    private static let logger = Logger(
        subsystem: "com.openworkloads.owls.companion",
        category: "wake"
    )

    /// macOS keeps a finite list of power events, so the horizon is capped.
    private static let maximumEvents = 50

    private static let pmsetFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM/dd/yy HH:mm:ss"
        return formatter
    }()

    /// Every moment the Mac should be awake for, over the coming horizon.
    ///
    /// Each wake sits a little before its anchor so the app is running by the
    /// time the anchor comes due.
    public static func plannedWakes(
        settings: SessionScheduleSettings,
        from: Date,
        calendar: Calendar = .current
    ) -> [Date] {
        guard settings.isEnabled, settings.wakesMacForAnchors else { return [] }
        let lead = TimeInterval(max(0, settings.wakeLeadSeconds))
        let days = max(1, settings.wakeHorizonDays)
        var wakes: [Date] = []

        for dayOffset in 0...days {
            guard let day = calendar.date(
                byAdding: .day,
                value: dayOffset,
                to: from
            ) else {
                continue
            }
            let weekday = calendar.component(.weekday, from: day)
            for anchor in settings.enabledAnchors
            where anchor.runs(onWeekday: weekday) {
                var components = calendar.dateComponents(
                    [.year, .month, .day],
                    from: day
                )
                components.hour = anchor.hour
                components.minute = anchor.minute
                components.second = 0
                guard let anchorDate = calendar.date(from: components) else {
                    continue
                }
                let wake = anchorDate.addingTimeInterval(-lead)
                // A wake in the past is refused by macOS, and one seconds away
                // is pointless.
                guard wake > from.addingTimeInterval(60) else { continue }
                wakes.append(wake)
            }
        }
        return Array(Set(wakes)).sorted().prefix(maximumEvents).map { $0 }
    }

    /// Replaces the events this app owns with `dates`.
    ///
    /// One authorisation prompt covers the whole change, because every command
    /// is passed to a single privileged shell.
    public static func apply(
        dates: [Date],
        replacing previous: [Date]
    ) async throws {
        var commands: [String] = []
        for date in previous {
            // A stale event may already be gone, which must not abort the rest.
            commands.append(cancelCommand(date) + " >/dev/null 2>&1 || true")
        }
        for date in dates {
            commands.append(scheduleCommand(date))
        }
        guard !commands.isEmpty else { return }
        try await runPrivileged(commands.joined(separator: "\n"))
        logger.info(
            "Wake schedule updated: \(dates.count) events, \(previous.count) replaced."
        )
    }

    public static func cancel(_ previous: [Date]) async throws {
        guard !previous.isEmpty else { return }
        let commands = previous.map {
            cancelCommand($0) + " >/dev/null 2>&1 || true"
        }
        try await runPrivileged(commands.joined(separator: "\n"))
        logger.info("Wake schedule cleared: \(previous.count) events.")
    }

    /// The events macOS currently holds for this app, read without privileges.
    public static func installedWakes() -> [Date] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "sched"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        let reader = DateFormatter()
        reader.locale = Locale(identifier: "en_US_POSIX")
        reader.dateFormat = "MM/dd/yyyy HH:mm:ss"

        return text
            .split(separator: "\n")
            .filter { $0.contains(owner) }
            .compactMap { line in
                guard let atRange = line.range(of: " at "),
                      let byRange = line.range(of: " by ")
                else {
                    return nil
                }
                let stamp = line[atRange.upperBound..<byRange.lowerBound]
                    .trimmingCharacters(in: .whitespaces)
                return reader.date(from: stamp)
            }
            .sorted()
    }

    private static func scheduleCommand(_ date: Date) -> String {
        "/usr/bin/pmset schedule wake "
            + shellQuoted(pmsetFormatter.string(from: date))
            + " " + shellQuoted(owner)
    }

    private static func cancelCommand(_ date: Date) -> String {
        "/usr/bin/pmset schedule cancel wake "
            + shellQuoted(pmsetFormatter.string(from: date))
            + " " + shellQuoted(owner)
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Runs a shell script as an administrator through the standard macOS
    /// authorisation panel, which is the supported route for an app without a
    /// privileged helper.
    private static func runPrivileged(_ script: String) async throws {
        let escaped = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(escaped)\""
            + " with administrator privileges"

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            Task.detached(priority: .userInitiated) {
                let process = Process()
                process.executableURL = URL(
                    fileURLWithPath: "/usr/bin/osascript"
                )
                process.arguments = ["-e", appleScript]
                let errorPipe = Pipe()
                process.standardOutput = Pipe()
                process.standardError = errorPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(
                        throwing: SessionWakeError.commandFailed(
                            error.localizedDescription
                        )
                    )
                    return
                }
                let errorData = errorPipe.fileHandleForReading
                    .readDataToEndOfFile()
                process.waitUntilExit()

                guard process.terminationStatus == 0 else {
                    let message = String(data: errorData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    // Dismissing the panel is a choice, not a failure worth
                    // shouting about.
                    if message.contains("-128")
                        || message.localizedCaseInsensitiveContains(
                            "User canceled"
                        ) {
                        continuation.resume(
                            throwing: SessionWakeError.cancelledByUser
                        )
                    } else {
                        continuation.resume(
                            throwing: SessionWakeError.commandFailed(
                                String(message.prefix(200))
                            )
                        )
                    }
                    return
                }
                continuation.resume()
            }
        }
    }
}
