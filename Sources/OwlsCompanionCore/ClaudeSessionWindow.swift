import Foundation

/// What is known about the session window right now.
///
/// A window can be known to be open while its end time is not known, because
/// the usage service does not always report a reset time.
public struct SessionWindowState: Equatable, Sendable {
    public let isOpen: Bool
    public let endsAt: Date?
    /// Where the answer came from, shown in the tooltip.
    public let source: String

    public init(isOpen: Bool, endsAt: Date?, source: String) {
        self.isOpen = isOpen
        self.endsAt = endsAt
        self.source = source
    }

    public static let closed = SessionWindowState(
        isOpen: false,
        endsAt: nil,
        source: "No window is open."
    )
}

/// Works out whether a session window is open.
///
/// Three sources are consulted, because no single one is reliable. The usage
/// service reports utilization for the current window but often omits the
/// reset time. Local Claude Code transcripts carry request timestamps, from
/// which the window boundaries can be reconstructed. A window this app opened
/// itself is known exactly.
public enum ClaudeSessionWindow {
    /// Reconstructs the start of the window that is open at `now`.
    ///
    /// Windows chain: the first request opens one, requests inside it join it,
    /// and the first request after it lapses opens the next. Walking the
    /// timestamps in order reproduces that, but only once the walk starts from
    /// a request that is certainly the start of a window.
    ///
    /// A request is certainly a window start when nothing was sent in the five
    /// hours before it. The last such request in the history is used as the
    /// anchor. Without one, the phase of the chain is unknowable, since the
    /// history has simply been cut off part way through a window, and nil is
    /// returned rather than a guess.
    ///
    /// - Parameter scannedFrom: the earliest moment the history covers. When
    ///   the first request sits more than a window after it, that request is
    ///   itself a safe anchor.
    public static func currentWindowStart(
        timestamps: [Date],
        now: Date,
        scannedFrom: Date? = nil,
        duration: TimeInterval = claudeSessionWindowDuration
    ) -> Date? {
        let sorted = timestamps.sorted()
        guard let first = sorted.first else { return nil }

        var anchor: Date?
        for (previous, current) in zip(sorted, sorted.dropFirst())
        where current.timeIntervalSince(previous) >= duration {
            anchor = current
        }
        if anchor == nil,
           let scannedFrom,
           first.timeIntervalSince(scannedFrom) >= duration {
            anchor = first
        }
        guard var windowStart = anchor ?? (scannedFrom == nil ? first : nil)
        else {
            return nil
        }

        for timestamp in sorted where timestamp > windowStart {
            if timestamp.timeIntervalSince(windowStart) >= duration {
                windowStart = timestamp
            }
        }
        guard now >= windowStart,
              now.timeIntervalSince(windowStart) < duration
        else {
            return nil
        }
        return windowStart
    }

    /// Combines everything known into one answer.
    ///
    /// - Parameters:
    ///   - reportedResetsAt: the reset time from the usage service, often nil.
    ///   - reportedUsedPercent: utilization of the five hour window. Anything
    ///     above zero means a window is open even when no reset time came
    ///     with it.
    ///   - localWindowEnd: derived from local Claude Code transcripts.
    ///   - selfOpenedWindowEnd: the end of a window this app opened.
    public static func resolve(
        reportedResetsAt: Date?,
        reportedUsedPercent: Double?,
        localWindowEnd: Date?,
        selfOpenedWindowEnd: Date?,
        now: Date
    ) -> SessionWindowState {
        let future: (Date?) -> Date? = { date in
            guard let date, date > now else { return nil }
            return date
        }
        let reported = future(reportedResetsAt)
        let local = future(localWindowEnd)
        let own = future(selfOpenedWindowEnd)
        let reportsUsage = (reportedUsedPercent ?? 0) > 0

        let isOpen = reported != nil
            || local != nil
            || own != nil
            || reportsUsage
        guard isOpen else { return .closed }

        // The service is authoritative when it gives a reset time. Otherwise
        // take the latest estimate, so a window is never treated as lapsed
        // early and primed twice.
        let endsAt = reported ?? [local, own].compactMap { $0 }.max()

        let source: String
        if reported != nil {
            source = "Reported by the Claude usage service."
        } else if endsAt != nil {
            source = local != nil
                ? "Worked out from local Claude Code activity."
                : "This window was opened by the companion."
        } else {
            source = "The usage service reports this window as in use, "
                + "but did not say when it lapses."
        }

        return SessionWindowState(
            isOpen: true,
            endsAt: endsAt,
            source: source
        )
    }
}

/// Reads request timestamps out of the local Claude Code transcripts.
enum ClaudeActivityScanner {
    /// The end of the window that local activity says is currently open.
    /// Two days of history, which almost always contains a night of quiet to
    /// anchor the chain, and still costs far less than the thirty day scan the
    /// cost figures use.
    static let lookback: TimeInterval = 48 * 60 * 60

    static func localWindowEnd(
        homeDirectory: URL,
        now: Date
    ) async -> Date? {
        await Task.detached(priority: .utility) {
            let cutoff = now.addingTimeInterval(-lookback)
            let timestamps = recentTimestamps(
                homeDirectory: homeDirectory,
                now: now,
                cutoff: cutoff
            )
            return ClaudeSessionWindow.currentWindowStart(
                timestamps: timestamps,
                now: now,
                scannedFrom: cutoff
            )?.addingTimeInterval(claudeSessionWindowDuration)
        }.value
    }

    private static func recentTimestamps(
        homeDirectory: URL,
        now: Date,
        cutoff: Date
    ) -> [Date] {
        let root = homeDirectory.appendingPathComponent(".claude/projects")
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

        var timestamps: [Date] = []
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        let plainFormatter = ISO8601DateFormatter()

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: [
                      .isRegularFileKey,
                      .contentModificationDateKey
                  ]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified >= cutoff,
                  let data = try? Data(contentsOf: url)
            else {
                continue
            }
            for line in data.split(separator: UInt8(ascii: "\n")) {
                guard line.range(
                    of: Data(#""type":"assistant""#.utf8)
                ) != nil,
                    let object = try? JSONSerialization.jsonObject(
                        with: Data(line)
                    ) as? [String: Any],
                    let text = object["timestamp"] as? String,
                    let date = formatter.date(from: text)
                        ?? plainFormatter.date(from: text),
                    date >= cutoff,
                    date <= now
                else {
                    continue
                }
                timestamps.append(date)
            }
        }
        return timestamps
    }
}
