import Foundation

/// An anchor paired with the moment it should fire.
public struct ScheduledAnchor: Equatable, Sendable {
    public let anchor: SessionAnchor
    public let date: Date

    public init(anchor: SessionAnchor, date: Date) {
        self.anchor = anchor
        self.date = date
    }
}

/// Works out when anchors fire and how much of the day they keep covered.
/// Everything here is pure so the behaviour can be tested without a clock.
public enum SessionAnchorPlanner {
    private static let minutesPerDay = 24 * 60

    /// The next anchor due strictly after `date`, searching up to a week ahead.
    public static func nextRun(
        after date: Date,
        settings: SessionScheduleSettings,
        calendar: Calendar = .current
    ) -> ScheduledAnchor? {
        let anchors = settings.enabledAnchors
        guard settings.isEnabled, !anchors.isEmpty else { return nil }

        for dayOffset in 0...7 {
            guard let day = calendar.date(
                byAdding: .day,
                value: dayOffset,
                to: date
            ) else {
                continue
            }
            let weekday = calendar.component(.weekday, from: day)
            for anchor in anchors where anchor.runs(onWeekday: weekday) {
                guard let candidate = occurrence(
                    of: anchor,
                    on: day,
                    calendar: calendar
                ) else {
                    continue
                }
                if candidate > date {
                    return ScheduledAnchor(anchor: anchor, date: candidate)
                }
            }
        }
        return nil
    }

    /// The anchor that should fire right now, if any.
    ///
    /// An anchor stays due for `catchUpMinutes` after its time so a Mac that
    /// was asleep still opens the window once it wakes. `lastRunAt` stops the
    /// same anchor firing twice.
    public static func dueAnchor(
        now: Date,
        settings: SessionScheduleSettings,
        lastRunAt: Date?,
        calendar: Calendar = .current
    ) -> ScheduledAnchor? {
        let anchors = settings.enabledAnchors
        guard settings.isEnabled, !anchors.isEmpty else { return nil }

        let grace = TimeInterval(max(0, settings.catchUpMinutes) * 60)
        var best: ScheduledAnchor?

        // Yesterday is checked as well so a late anchor can still catch up
        // across midnight.
        for dayOffset in [-1, 0] {
            guard let day = calendar.date(
                byAdding: .day,
                value: dayOffset,
                to: now
            ) else {
                continue
            }
            let weekday = calendar.component(.weekday, from: day)
            for anchor in anchors where anchor.runs(onWeekday: weekday) {
                guard let scheduled = occurrence(
                    of: anchor,
                    on: day,
                    calendar: calendar
                ) else {
                    continue
                }
                guard scheduled <= now,
                      now.timeIntervalSince(scheduled) <= grace
                else {
                    continue
                }
                if let lastRunAt, lastRunAt >= scheduled {
                    continue
                }
                // Prefer the most recent anchor when several are catching up.
                if let current = best, current.date >= scheduled {
                    continue
                }
                best = ScheduledAnchor(anchor: anchor, date: scheduled)
            }
        }
        return best
    }

    /// The windows the schedule opens on a given weekday.
    ///
    /// Anchors landing inside a window opened earlier are marked, because a
    /// request sent while a window is open joins that window rather than
    /// starting a new one.
    public static func coverage(
        settings: SessionScheduleSettings,
        weekday: Int
    ) -> [SessionCoverageSpan] {
        let windowMinutes = Int(claudeSessionWindowDuration / 60)
        var spans: [SessionCoverageSpan] = []
        var openWindowEnds = Int.min

        for anchor in settings.enabledAnchors
        where anchor.runs(onWeekday: weekday) {
            let start = anchor.minutesFromMidnight
            let swallowed = start < openWindowEnds
            let end = min(start + windowMinutes, minutesPerDay)
            spans.append(SessionCoverageSpan(
                anchorID: anchor.id,
                startMinute: start,
                endMinute: end,
                isSwallowedByPreviousWindow: swallowed
            ))
            if !swallowed {
                openWindowEnds = start + windowMinutes
            }
        }
        return spans
    }

    /// Stretches of the day that no window covers, given the day's spans.
    /// Only gaps between the first and last window are reported, since the
    /// hours before the first anchor are deliberately uncovered.
    public static func gaps(
        in spans: [SessionCoverageSpan]
    ) -> [ClosedRange<Int>] {
        let active = spans
            .filter { !$0.isSwallowedByPreviousWindow }
            .sorted { $0.startMinute < $1.startMinute }
        guard active.count > 1 else { return [] }

        var gaps: [ClosedRange<Int>] = []
        var previousEnd = active[0].endMinute
        for span in active.dropFirst() {
            if span.startMinute > previousEnd {
                gaps.append(previousEnd...span.startMinute)
            }
            previousEnd = max(previousEnd, span.endMinute)
        }
        return gaps
    }

    /// Total minutes of the day held open by the schedule.
    public static func coveredMinutes(
        in spans: [SessionCoverageSpan]
    ) -> Int {
        let active = spans
            .filter { !$0.isSwallowedByPreviousWindow }
            .sorted { $0.startMinute < $1.startMinute }
        var total = 0
        var cursor = 0
        for span in active {
            let start = max(span.startMinute, cursor)
            if span.endMinute > start {
                total += span.endMinute - start
                cursor = span.endMinute
            }
        }
        return total
    }

    /// The anchor time on the calendar day that `day` falls in. Built from
    /// date components rather than a forward search so it never rolls over
    /// into the following day.
    private static func occurrence(
        of anchor: SessionAnchor,
        on day: Date,
        calendar: Calendar
    ) -> Date? {
        var components = calendar.dateComponents(
            [.year, .month, .day],
            from: day
        )
        components.hour = anchor.hour
        components.minute = anchor.minute
        components.second = 0
        return calendar.date(from: components)
    }
}
