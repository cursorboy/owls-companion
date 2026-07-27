import Foundation

/// The length of a Claude subscription session window. The window opens on the
/// first request after the previous one lapsed, so the time that request is
/// sent decides when every following window of the day starts.
public let claudeSessionWindowDuration: TimeInterval = 5 * 60 * 60

public enum SessionScheduleMode: String, Codable, CaseIterable, Sendable {
    /// Send the priming prompt without asking.
    case startAutomatically
    /// Post a notification at the anchor and let the person start the window.
    case notifyOnly

    public var displayName: String {
        switch self {
        case .startAutomatically:
            "Start the window automatically"
        case .notifyOnly:
            "Only remind me"
        }
    }
}

/// A time of day at which a session window should be opened.
public struct SessionAnchor: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var hour: Int
    public var minute: Int
    /// Calendar weekday numbers, where 1 is Sunday and 7 is Saturday.
    public var weekdays: Set<Int>
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        hour: Int,
        minute: Int,
        weekdays: Set<Int> = SessionAnchor.everyDay,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
        self.weekdays = weekdays.isEmpty ? SessionAnchor.everyDay : weekdays
        self.isEnabled = isEnabled
    }

    public static let everyDay: Set<Int> = [1, 2, 3, 4, 5, 6, 7]
    public static let weekdaysOnly: Set<Int> = [2, 3, 4, 5, 6]

    /// Minutes since midnight, used for ordering and overlap checks.
    public var minutesFromMidnight: Int {
        hour * 60 + minute
    }

    public func runs(onWeekday weekday: Int) -> Bool {
        isEnabled && weekdays.contains(weekday)
    }

    public var timeLabel: String {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        let calendar = Calendar.current
        guard let date = calendar.date(from: components) else {
            return String(format: "%02d:%02d", hour, minute)
        }
        return date.formatted(date: .omitted, time: .shortened)
    }

    public var weekdayLabel: String {
        if weekdays == SessionAnchor.everyDay {
            return "Every day"
        }
        if weekdays == SessionAnchor.weekdaysOnly {
            return "Weekdays"
        }
        if weekdays == [1, 7] {
            return "Weekends"
        }
        let symbols = Calendar.current.veryShortWeekdaySymbols
        return weekdays
            .sorted()
            .compactMap { weekday in
                let index = weekday - 1
                return symbols.indices.contains(index) ? symbols[index] : nil
            }
            .joined(separator: " ")
    }
}

public struct SessionScheduleSettings: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var mode: SessionScheduleMode
    public var anchors: [SessionAnchor]
    /// The prompt sent to open the window. Kept short so it costs very little.
    public var prompt: String
    /// A Claude Code model alias. Smaller models cost less to prime with.
    public var model: String
    /// Skip the anchor when a window is already open, because a request during
    /// an open window joins that window instead of starting a new one.
    public var skipWhenWindowIsOpen: Bool
    /// How late an anchor may still fire, for example after the Mac wakes.
    public var catchUpMinutes: Int
    /// Set when the `claude` binary lives somewhere unusual.
    public var executablePathOverride: String?
    /// Ask macOS to wake the Mac at each anchor. Without this a sleeping Mac
    /// suspends the app and the anchor only fires when the lid is opened.
    public var wakesMacForAnchors: Bool
    /// How far ahead of the anchor to wake, giving the app time to be running.
    public var wakeLeadSeconds: Int
    /// How many days of wake events to install at a time.
    public var wakeHorizonDays: Int

    public init(
        isEnabled: Bool = false,
        mode: SessionScheduleMode = .startAutomatically,
        anchors: [SessionAnchor] = SessionScheduleSettings.defaultAnchors,
        prompt: String = SessionScheduleSettings.defaultPrompt,
        model: String = SessionScheduleSettings.defaultModel,
        skipWhenWindowIsOpen: Bool = true,
        catchUpMinutes: Int = 45,
        executablePathOverride: String? = nil,
        wakesMacForAnchors: Bool = false,
        wakeLeadSeconds: Int = 120,
        wakeHorizonDays: Int = 14
    ) {
        self.wakesMacForAnchors = wakesMacForAnchors
        self.wakeLeadSeconds = wakeLeadSeconds
        self.wakeHorizonDays = wakeHorizonDays
        self.isEnabled = isEnabled
        self.mode = mode
        self.anchors = anchors
        self.prompt = prompt
        self.model = model
        self.skipWhenWindowIsOpen = skipWhenWindowIsOpen
        self.catchUpMinutes = catchUpMinutes
        self.executablePathOverride = executablePathOverride
    }

    public static let defaultPrompt = "Reply with the single word: ready"
    public static let defaultModel = "haiku"

    /// Three anchors spaced exactly one window apart, so each window opens as
    /// the previous one lapses and the working day is covered end to end.
    public static let defaultAnchors: [SessionAnchor] = [
        SessionAnchor(hour: 8, minute: 0, weekdays: SessionAnchor.weekdaysOnly),
        SessionAnchor(hour: 13, minute: 0, weekdays: SessionAnchor.weekdaysOnly),
        SessionAnchor(hour: 18, minute: 0, weekdays: SessionAnchor.weekdaysOnly)
    ]

    public var sortedAnchors: [SessionAnchor] {
        anchors.sorted { $0.minutesFromMidnight < $1.minutesFromMidnight }
    }

    public var enabledAnchors: [SessionAnchor] {
        sortedAnchors.filter(\.isEnabled)
    }

    /// Decoded key by key with a fallback for each, so a settings file written
    /// by an older build keeps the anchors and history it already holds
    /// instead of being thrown away when a new field appears.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = SessionScheduleSettings()
        func value<T: Decodable>(
            _ key: CodingKeys,
            _ defaultValue: T
        ) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key))
                .flatMap { $0 } ?? defaultValue
        }

        isEnabled = value(.isEnabled, fallback.isEnabled)
        mode = value(.mode, fallback.mode)
        anchors = value(.anchors, fallback.anchors)
        prompt = value(.prompt, fallback.prompt)
        model = value(.model, fallback.model)
        skipWhenWindowIsOpen = value(
            .skipWhenWindowIsOpen,
            fallback.skipWhenWindowIsOpen
        )
        catchUpMinutes = value(.catchUpMinutes, fallback.catchUpMinutes)
        executablePathOverride = try? container.decodeIfPresent(
            String.self,
            forKey: .executablePathOverride
        )
        wakesMacForAnchors = value(
            .wakesMacForAnchors,
            fallback.wakesMacForAnchors
        )
        wakeLeadSeconds = value(.wakeLeadSeconds, fallback.wakeLeadSeconds)
        wakeHorizonDays = value(.wakeHorizonDays, fallback.wakeHorizonDays)
    }
}

/// One recorded attempt to open a window.
public struct SessionRunRecord: Identifiable, Codable, Hashable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        /// The prompt was sent and a window is now open.
        case started
        /// A window was already open, so nothing was sent.
        case skippedWindowOpen
        /// The person was reminded instead of the window being opened.
        case notified
        /// The prompt was sent but failed.
        case failed
    }

    public let id: UUID
    public let date: Date
    public let outcome: Outcome
    public let detail: String
    public let costUSD: Double?
    /// Set when the run opened a window, so the UI can show when it lapses.
    public let windowEndsAt: Date?
    /// Nil for a manual run.
    public let anchorID: UUID?

    public init(
        id: UUID = UUID(),
        date: Date,
        outcome: Outcome,
        detail: String,
        costUSD: Double? = nil,
        windowEndsAt: Date? = nil,
        anchorID: UUID? = nil
    ) {
        self.id = id
        self.date = date
        self.outcome = outcome
        self.detail = detail
        self.costUSD = costUSD
        self.windowEndsAt = windowEndsAt
        self.anchorID = anchorID
    }
}

/// A stretch of the day that an anchor keeps covered.
public struct SessionCoverageSpan: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let anchorID: UUID
    /// Minutes from midnight at which the window opens.
    public let startMinute: Int
    /// Minutes from midnight at which it lapses, clamped to the end of the day.
    public let endMinute: Int
    /// True when a previous anchor already holds a window open at this time, so
    /// this anchor cannot start a new one.
    public let isSwallowedByPreviousWindow: Bool

    public init(
        id: UUID = UUID(),
        anchorID: UUID,
        startMinute: Int,
        endMinute: Int,
        isSwallowedByPreviousWindow: Bool
    ) {
        self.id = id
        self.anchorID = anchorID
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.isSwallowedByPreviousWindow = isSwallowedByPreviousWindow
    }
}
