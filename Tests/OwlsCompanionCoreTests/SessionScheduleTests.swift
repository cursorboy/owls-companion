import Foundation
import Testing
@testable import OwlsCompanionCore

/// A fixed UTC calendar keeps these tests away from the machine's time zone
/// and away from daylight saving shifts.
private let utcCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.firstWeekday = 1
    return calendar
}()

private func makeDate(
    year: Int = 2026,
    month: Int = 7,
    day: Int = 27,
    hour: Int,
    minute: Int
) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    components.second = 0
    return utcCalendar.date(from: components)!
}

private func weekday(of date: Date) -> Int {
    utcCalendar.component(.weekday, from: date)
}

private func makeSettings(
    anchors: [SessionAnchor],
    mode: SessionScheduleMode = .startAutomatically,
    catchUpMinutes: Int = 45
) -> SessionScheduleSettings {
    SessionScheduleSettings(
        isEnabled: true,
        mode: mode,
        anchors: anchors,
        catchUpMinutes: catchUpMinutes
    )
}

@Suite("Session anchor planner")
struct SessionAnchorPlannerTests {
    @Test("The next run is the next anchor later the same day")
    func nextRunLaterToday() {
        let now = makeDate(hour: 9, minute: 30)
        let today = weekday(of: now)
        let settings = makeSettings(anchors: [
            SessionAnchor(hour: 8, minute: 0, weekdays: [today]),
            SessionAnchor(hour: 13, minute: 0, weekdays: [today]),
            SessionAnchor(hour: 18, minute: 0, weekdays: [today])
        ])

        let next = SessionAnchorPlanner.nextRun(
            after: now,
            settings: settings,
            calendar: utcCalendar
        )

        #expect(next?.date == makeDate(hour: 13, minute: 0))
        #expect(next?.anchor.hour == 13)
    }

    @Test("The next run rolls to the following week when today is spent")
    func nextRunRollsToNextWeek() {
        let now = makeDate(hour: 20, minute: 0)
        let today = weekday(of: now)
        let settings = makeSettings(anchors: [
            SessionAnchor(hour: 8, minute: 0, weekdays: [today])
        ])

        let next = SessionAnchorPlanner.nextRun(
            after: now,
            settings: settings,
            calendar: utcCalendar
        )

        #expect(next?.date == makeDate(day: 27 + 7, hour: 8, minute: 0))
    }

    @Test("A disabled schedule has no next run")
    func disabledScheduleHasNoNextRun() {
        var settings = makeSettings(anchors: SessionScheduleSettings
            .defaultAnchors)
        settings.isEnabled = false

        let next = SessionAnchorPlanner.nextRun(
            after: makeDate(hour: 7, minute: 0),
            settings: settings,
            calendar: utcCalendar
        )

        #expect(next == nil)
    }

    @Test("An anchor is due inside the catch up window")
    func anchorIsDueInsideCatchUp() {
        let now = makeDate(hour: 8, minute: 20)
        let today = weekday(of: now)
        let settings = makeSettings(
            anchors: [SessionAnchor(hour: 8, minute: 0, weekdays: [today])],
            catchUpMinutes: 45
        )

        let due = SessionAnchorPlanner.dueAnchor(
            now: now,
            settings: settings,
            lastRunAt: nil,
            calendar: utcCalendar
        )

        #expect(due?.date == makeDate(hour: 8, minute: 0))
    }

    @Test("An anchor is not due once the catch up window has passed")
    func anchorIsNotDueAfterCatchUp() {
        let now = makeDate(hour: 9, minute: 1)
        let today = weekday(of: now)
        let settings = makeSettings(
            anchors: [SessionAnchor(hour: 8, minute: 0, weekdays: [today])],
            catchUpMinutes: 45
        )

        let due = SessionAnchorPlanner.dueAnchor(
            now: now,
            settings: settings,
            lastRunAt: nil,
            calendar: utcCalendar
        )

        #expect(due == nil)
    }

    @Test("An anchor does not fire twice")
    func anchorDoesNotFireTwice() {
        let now = makeDate(hour: 8, minute: 20)
        let today = weekday(of: now)
        let settings = makeSettings(
            anchors: [SessionAnchor(hour: 8, minute: 0, weekdays: [today])]
        )

        let due = SessionAnchorPlanner.dueAnchor(
            now: now,
            settings: settings,
            lastRunAt: makeDate(hour: 8, minute: 1),
            calendar: utcCalendar
        )

        #expect(due == nil)
    }

    @Test("The most recent anchor wins when two are catching up")
    func mostRecentAnchorWins() {
        let now = makeDate(hour: 13, minute: 10)
        let today = weekday(of: now)
        let settings = makeSettings(
            anchors: [
                SessionAnchor(hour: 12, minute: 45, weekdays: [today]),
                SessionAnchor(hour: 13, minute: 0, weekdays: [today])
            ],
            catchUpMinutes: 60
        )

        let due = SessionAnchorPlanner.dueAnchor(
            now: now,
            settings: settings,
            lastRunAt: nil,
            calendar: utcCalendar
        )

        #expect(due?.date == makeDate(hour: 13, minute: 0))
    }

    @Test("A late anchor can still catch up after midnight")
    func lateAnchorCatchesUpAcrossMidnight() {
        let now = makeDate(day: 28, hour: 0, minute: 15)
        let yesterday = weekday(of: makeDate(day: 27, hour: 23, minute: 45))
        let settings = makeSettings(
            anchors: [
                SessionAnchor(hour: 23, minute: 45, weekdays: [yesterday])
            ],
            catchUpMinutes: 45
        )

        let due = SessionAnchorPlanner.dueAnchor(
            now: now,
            settings: settings,
            lastRunAt: nil,
            calendar: utcCalendar
        )

        #expect(due?.date == makeDate(day: 27, hour: 23, minute: 45))
    }

    @Test("An anchor on a weekday that is off is never due")
    func anchorOnExcludedWeekdayIsNotDue() {
        let now = makeDate(hour: 8, minute: 5)
        let today = weekday(of: now)
        let otherDay = today == 7 ? 1 : today + 1
        let settings = makeSettings(
            anchors: [SessionAnchor(hour: 8, minute: 0, weekdays: [otherDay])]
        )

        let due = SessionAnchorPlanner.dueAnchor(
            now: now,
            settings: settings,
            lastRunAt: nil,
            calendar: utcCalendar
        )

        #expect(due == nil)
    }
}

@Suite("Session coverage")
struct SessionCoverageTests {
    @Test("Anchors five hours apart cover the day without gaps")
    func defaultAnchorsChainCleanly() {
        let today = 2
        let settings = makeSettings(anchors: [
            SessionAnchor(hour: 8, minute: 0, weekdays: [today]),
            SessionAnchor(hour: 13, minute: 0, weekdays: [today]),
            SessionAnchor(hour: 18, minute: 0, weekdays: [today])
        ])

        let spans = SessionAnchorPlanner.coverage(
            settings: settings,
            weekday: today
        )

        #expect(spans.count == 3)
        #expect(spans.allSatisfy { !$0.isSwallowedByPreviousWindow })
        #expect(SessionAnchorPlanner.gaps(in: spans).isEmpty)
        #expect(SessionAnchorPlanner.coveredMinutes(in: spans) == 15 * 60)
    }

    @Test("An anchor inside an open window is marked as swallowed")
    func anchorInsideOpenWindowIsSwallowed() {
        let today = 2
        let settings = makeSettings(anchors: [
            SessionAnchor(hour: 8, minute: 0, weekdays: [today]),
            SessionAnchor(hour: 10, minute: 0, weekdays: [today]),
            SessionAnchor(hour: 13, minute: 0, weekdays: [today])
        ])

        let spans = SessionAnchorPlanner.coverage(
            settings: settings,
            weekday: today
        )

        #expect(spans[0].isSwallowedByPreviousWindow == false)
        // 10:00 falls inside the window opened at 08:00, so it cannot start
        // one of its own.
        #expect(spans[1].isSwallowedByPreviousWindow)
        #expect(spans[2].isSwallowedByPreviousWindow == false)
        #expect(SessionAnchorPlanner.coveredMinutes(in: spans) == 10 * 60)
    }

    @Test("Anchors more than five hours apart leave a reported gap")
    func spacedAnchorsLeaveAGap() {
        let today = 2
        let settings = makeSettings(anchors: [
            SessionAnchor(hour: 8, minute: 0, weekdays: [today]),
            SessionAnchor(hour: 15, minute: 0, weekdays: [today])
        ])

        let spans = SessionAnchorPlanner.coverage(
            settings: settings,
            weekday: today
        )
        let gaps = SessionAnchorPlanner.gaps(in: spans)

        #expect(gaps.count == 1)
        #expect(gaps.first == (13 * 60)...(15 * 60))
    }

    @Test("A window is clamped to the end of the day")
    func lateWindowIsClamped() {
        let today = 2
        let settings = makeSettings(anchors: [
            SessionAnchor(hour: 22, minute: 0, weekdays: [today])
        ])

        let spans = SessionAnchorPlanner.coverage(
            settings: settings,
            weekday: today
        )

        #expect(spans.first?.endMinute == 24 * 60)
        #expect(SessionAnchorPlanner.coveredMinutes(in: spans) == 2 * 60)
    }

    @Test("A disabled anchor does not cover anything")
    func disabledAnchorCoversNothing() {
        let today = 2
        let settings = makeSettings(anchors: [
            SessionAnchor(
                hour: 8,
                minute: 0,
                weekdays: [today],
                isEnabled: false
            )
        ])

        let spans = SessionAnchorPlanner.coverage(
            settings: settings,
            weekday: today
        )

        #expect(spans.isEmpty)
    }

    @Test("The shipped defaults run on weekdays only")
    func shippedDefaultsAreWeekdaysOnly() {
        let settings = makeSettings(
            anchors: SessionScheduleSettings.defaultAnchors
        )

        let monday = SessionAnchorPlanner.coverage(
            settings: settings,
            weekday: 2
        )
        let sunday = SessionAnchorPlanner.coverage(
            settings: settings,
            weekday: 1
        )

        #expect(SessionAnchorPlanner.coveredMinutes(in: monday) == 15 * 60)
        #expect(sunday.isEmpty)
    }
}

@Suite("Session window detection")
struct SessionWindowTests {
    private let base = Date(timeIntervalSince1970: 1_785_000_000)

    /// Far enough back that the first request in each fixture is itself a safe
    /// anchor, which is what a real overnight break gives you.
    private var quietSince: Date {
        base.addingTimeInterval(-claudeSessionWindowDuration - 60)
    }

    @Test("Requests inside a window join it rather than starting a new one")
    func requestsInsideAWindowJoinIt() {
        let start = base
        let timestamps = [
            start,
            start.addingTimeInterval(1_800),
            start.addingTimeInterval(7_200)
        ]

        let found = ClaudeSessionWindow.currentWindowStart(
            timestamps: timestamps,
            now: start.addingTimeInterval(3 * 3_600),
            scannedFrom: quietSince
        )

        #expect(found == start)
    }

    @Test("A gap of five hours starts the next window")
    func gapStartsANewWindow() {
        let first = base
        let second = base.addingTimeInterval(claudeSessionWindowDuration + 600)
        let timestamps = [first, first.addingTimeInterval(600), second]

        let found = ClaudeSessionWindow.currentWindowStart(
            timestamps: timestamps,
            now: second.addingTimeInterval(600),
            scannedFrom: quietSince
        )

        #expect(found == second)
    }

    @Test("A window that already lapsed is not reported as open")
    func lapsedWindowIsNotOpen() {
        let found = ClaudeSessionWindow.currentWindowStart(
            timestamps: [base],
            now: base.addingTimeInterval(claudeSessionWindowDuration + 60),
            scannedFrom: quietSince
        )

        #expect(found == nil)
    }

    @Test("No local activity means no window")
    func noActivityMeansNoWindow() {
        let found = ClaudeSessionWindow.currentWindowStart(
            timestamps: [],
            now: base,
            scannedFrom: quietSince
        )

        #expect(found == nil)
    }

    @Test("Unbroken activity gives no trustworthy anchor")
    func unbrokenActivityIsNotGuessed() {
        // History cut off part way through a window. Every request is within
        // a window of the last, so where the chain starts cannot be known and
        // a guess could skip a real anchor.
        let scannedFrom = base
        let timestamps = stride(from: 0.0, through: 40 * 3_600, by: 1_800)
            .map { base.addingTimeInterval(60 + $0) }

        let found = ClaudeSessionWindow.currentWindowStart(
            timestamps: timestamps,
            now: base.addingTimeInterval(40 * 3_600 + 120),
            scannedFrom: scannedFrom
        )

        #expect(found == nil)
    }

    @Test("A genuine break anchors the chain even mid history")
    func genuineBreakAnchorsTheChain() {
        // Matches a real day: busy, five hours of quiet, then busy again.
        let scannedFrom = base
        var timestamps = stride(from: 0.0, through: 3 * 3_600, by: 1_800)
            .map { base.addingTimeInterval(60 + $0) }
        let afterBreak = base.addingTimeInterval(
            60 + 3 * 3_600 + claudeSessionWindowDuration
        )
        timestamps += stride(from: 0.0, through: 6 * 3_600, by: 1_800)
            .map { afterBreak.addingTimeInterval($0) }

        let found = ClaudeSessionWindow.currentWindowStart(
            timestamps: timestamps,
            now: afterBreak.addingTimeInterval(6 * 3_600 + 60),
            scannedFrom: scannedFrom
        )

        // The break anchors at afterBreak, then one more window has elapsed.
        #expect(found == afterBreak.addingTimeInterval(
            claudeSessionWindowDuration
        ))
    }

    @Test("Utilization alone shows an open window with an unknown end")
    func utilizationWithoutResetTimeIsStillOpen() {
        // This is the shape the usage service actually returns for some
        // accounts: a used percentage and no reset time at all.
        let state = ClaudeSessionWindow.resolve(
            reportedResetsAt: nil,
            reportedUsedPercent: 61,
            localWindowEnd: nil,
            selfOpenedWindowEnd: nil,
            now: base
        )

        #expect(state.isOpen)
        #expect(state.endsAt == nil)
    }

    @Test("Local history supplies the end when the service does not")
    func localHistorySuppliesTheEnd() {
        let end = base.addingTimeInterval(3_600)

        let state = ClaudeSessionWindow.resolve(
            reportedResetsAt: nil,
            reportedUsedPercent: 61,
            localWindowEnd: end,
            selfOpenedWindowEnd: nil,
            now: base
        )

        #expect(state.isOpen)
        #expect(state.endsAt == end)
    }

    @Test("The reported reset time wins when it is present")
    func reportedResetTimeWins() {
        let reported = base.addingTimeInterval(1_800)
        let local = base.addingTimeInterval(3_600)

        let state = ClaudeSessionWindow.resolve(
            reportedResetsAt: reported,
            reportedUsedPercent: 20,
            localWindowEnd: local,
            selfOpenedWindowEnd: nil,
            now: base
        )

        #expect(state.endsAt == reported)
    }

    @Test("The latest estimate wins so a window is never primed twice")
    func latestEstimateWins() {
        let local = base.addingTimeInterval(1_200)
        let own = base.addingTimeInterval(3_600)

        let state = ClaudeSessionWindow.resolve(
            reportedResetsAt: nil,
            reportedUsedPercent: nil,
            localWindowEnd: local,
            selfOpenedWindowEnd: own,
            now: base
        )

        #expect(state.endsAt == own)
    }

    @Test("Everything stale or zero means the window is closed")
    func closedWhenNothingIsOpen() {
        let state = ClaudeSessionWindow.resolve(
            reportedResetsAt: base.addingTimeInterval(-60),
            reportedUsedPercent: 0,
            localWindowEnd: base.addingTimeInterval(-3_600),
            selfOpenedWindowEnd: base.addingTimeInterval(-10),
            now: base
        )

        #expect(state.isOpen == false)
        #expect(state.endsAt == nil)
    }
}

@Suite("Session primer")
struct SessionPrimerTests {
    @Test("A successful run reports cost and tokens")
    func successfulRunIsParsed() {
        let payload = """
        {
          "is_error": false,
          "result": "Ready.",
          "total_cost_usd": 0.0086,
          "usage": {
            "input_tokens": 10,
            "output_tokens": 96,
            "cache_creation_input_tokens": 3589,
            "cache_read_input_tokens": 9108
          }
        }
        """

        let result = SessionPrimer.parse(
            standardOutput: Data(payload.utf8),
            standardError: Data(),
            terminationStatus: 0
        )

        #expect(result.succeeded)
        #expect(result.costUSD == 0.0086)
        #expect(result.totalTokens == 12_803)
    }

    @Test("A signed out run reports the reason")
    func signedOutRunIsParsed() {
        let payload = """
        {"is_error": true, "result": "Not logged in · Please run /login"}
        """

        let result = SessionPrimer.parse(
            standardOutput: Data(payload.utf8),
            standardError: Data(),
            terminationStatus: 1
        )

        #expect(result.succeeded == false)
        #expect(result.message.contains("Not logged in"))
    }

    @Test("Unreadable output falls back to the exit status")
    func unreadableOutputFallsBack() {
        let result = SessionPrimer.parse(
            standardOutput: Data(),
            standardError: Data("command not found".utf8),
            terminationStatus: 127
        )

        #expect(result.succeeded == false)
        #expect(result.message.contains("command not found"))
    }

    @Test("An override that points nowhere resolves to nothing")
    func badOverrideResolvesToNothing() {
        let resolved = SessionPrimer.resolveExecutable(
            override: "/nonexistent/path/to/claude"
        )

        #expect(resolved == nil)
    }
}
