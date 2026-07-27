import AppKit
import Combine
import Foundation
import OSLog
import UserNotifications

/// Kept outside the store so the notification callbacks, which run off the
/// main actor, can log without an isolation hop.
private let scheduleLogger = Logger(
    subsystem: "com.openworkloads.owls.companion",
    category: "schedule"
)

@MainActor
public final class SessionScheduleStore: ObservableObject {
    public static let shared = SessionScheduleStore()

    @Published public var settings: SessionScheduleSettings {
        didSet {
            guard !isLoading, settings != oldValue else { return }
            save()
            recalculateNextRun()
        }
    }

    @Published public private(set) var runs: [SessionRunRecord] = []
    @Published public private(set) var nextRun: ScheduledAnchor?
    @Published public private(set) var isRunning = false
    /// What is known about the session window right now.
    @Published public private(set) var window: SessionWindowState = .closed

    /// When the open window lapses, or nil when none is open or the end time
    /// is not known.
    public var openWindowEndsAt: Date? {
        window.isOpen ? window.endsAt : nil
    }

    private static let runHistoryLimit = 40

    private let stateFile: URL
    private let usageStore: UsageStore
    private let homeDirectory: URL
    private let now: () -> Date
    private var lastAnchorRunAt: Date?
    private var isLoading = false
    private var tickLoop: Task<Void, Never>?
    private var wakeObserver: (any NSObjectProtocol)?
    /// The window end worked out from local Claude Code transcripts, refreshed
    /// off the main actor because it reads files.
    private var localWindowEnd: Date?

    public init(
        stateFile: URL? = nil,
        usageStore: UsageStore = .shared,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: @escaping () -> Date = Date.init
    ) {
        self.stateFile = stateFile ?? CompanionPaths.sessionScheduleFile()
        self.usageStore = usageStore
        self.homeDirectory = homeDirectory
        self.now = now
        self.settings = SessionScheduleSettings()
        load()
        recalculateNextRun()
    }

    deinit {
        tickLoop?.cancel()
    }

    public func start() {
        guard tickLoop == nil else { return }
        observeWake()
        tickLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    // MARK: - Scheduling

    private func tick() async {
        await refreshLocalActivity()
        refreshOpenWindow()
        recalculateNextRun()
        guard settings.isEnabled, !isRunning else { return }
        guard let due = SessionAnchorPlanner.dueAnchor(
            now: now(),
            settings: settings,
            lastRunAt: lastAnchorRunAt
        ) else {
            return
        }
        await fire(due)
    }

    private func fire(_ scheduled: ScheduledAnchor) async {
        // Recorded before the work starts so a failure cannot make the same
        // anchor retry on every tick.
        lastAnchorRunAt = scheduled.date
        save()

        if settings.skipWhenWindowIsOpen {
            let state = await currentWindow()
            if state.isOpen {
                record(SessionRunRecord(
                    date: now(),
                    outcome: .skippedWindowOpen,
                    detail: Self.skipDetail(state) + " Nothing was sent.",
                    windowEndsAt: state.endsAt,
                    anchorID: scheduled.anchor.id
                ))
                return
            }
        }

        switch settings.mode {
        case .notifyOnly:
            notify(
                title: "Time to open a Claude session window",
                body: "Send any prompt now to anchor the next five hours."
            )
            record(SessionRunRecord(
                date: now(),
                outcome: .notified,
                detail: "Reminded at \(scheduled.anchor.timeLabel).",
                anchorID: scheduled.anchor.id
            ))
        case .startAutomatically:
            await sendPrimer(anchorID: scheduled.anchor.id)
        }
    }

    /// Opens a window straight away, for the button in the Schedule view.
    ///
    /// Pass `force` to send even when a window looks open, which is the escape
    /// hatch when the usage service and local history disagree.
    public func runNow(force: Bool = false) async {
        guard !isRunning else { return }
        if settings.skipWhenWindowIsOpen, !force {
            let state = await currentWindow()
            if state.isOpen {
                record(SessionRunRecord(
                    date: now(),
                    outcome: .skippedWindowOpen,
                    detail: Self.skipDetail(state)
                        + " Nothing was sent, because a request now would join "
                        + "that window rather than start a new one.",
                    windowEndsAt: state.endsAt
                ))
                return
            }
        }
        await sendPrimer(anchorID: nil)
    }

    private static func skipDetail(_ state: SessionWindowState) -> String {
        guard let endsAt = state.endsAt else {
            return "A window is already open."
        }
        return "A window is already open until "
            + endsAt.formatted(date: .omitted, time: .shortened) + "."
    }

    private func sendPrimer(anchorID: UUID?) async {
        isRunning = true
        defer { isRunning = false }

        let result = await SessionPrimer.run(settings: settings)
        let startedAt = now()

        if result.succeeded {
            let endsAt = startedAt.addingTimeInterval(
                claudeSessionWindowDuration
            )
            record(SessionRunRecord(
                date: startedAt,
                outcome: .started,
                detail: "Window open until "
                    + endsAt.formatted(date: .omitted, time: .shortened) + ".",
                costUSD: result.costUSD,
                windowEndsAt: endsAt,
                anchorID: anchorID
            ))
            notify(
                title: "Claude session window open",
                body: "It lapses at "
                    + endsAt.formatted(date: .omitted, time: .shortened) + "."
            )
            // Pull fresh usage so the meters and the window banner agree.
            await usageStore.refresh()
            await refreshLocalActivity()
            refreshOpenWindow()
        } else {
            record(SessionRunRecord(
                date: startedAt,
                outcome: .failed,
                detail: result.message,
                costUSD: result.costUSD,
                anchorID: anchorID
            ))
            notify(
                title: "Could not open a Claude session window",
                body: result.message
            )
        }
    }

    private func recalculateNextRun() {
        nextRun = SessionAnchorPlanner.nextRun(
            after: now(),
            settings: settings
        )
    }

    // MARK: - Window state

    /// Refreshes everything known about the window, pulling fresh usage first
    /// when the cache is too old to trust for a decision this costly.
    private func currentWindow() async -> SessionWindowState {
        if usageStore.lastRefresh.map({
            now().timeIntervalSince($0) > 120
        }) ?? true {
            await usageStore.refresh()
        }
        await refreshLocalActivity()
        refreshOpenWindow()
        return window
    }

    private func refreshLocalActivity() async {
        localWindowEnd = await ClaudeActivityScanner.localWindowEnd(
            homeDirectory: homeDirectory,
            now: now()
        )
    }

    private func refreshOpenWindow() {
        let sessionMetric = usageStore.snapshots
            .first { $0.id == .claude }?
            .metrics
            .first { $0.id == "session" }
        window = ClaudeSessionWindow.resolve(
            reportedResetsAt: sessionMetric?.resetsAt,
            reportedUsedPercent: sessionMetric?.usedPercent,
            localWindowEnd: localWindowEnd,
            selfOpenedWindowEnd: runs
                .first { $0.outcome == .started }?
                .windowEndsAt,
            now: now()
        )
    }

    private func observeWake() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The tick loop is paused while the Mac sleeps, so an anchor that
            // came due overnight is checked as soon as it wakes.
            Task { @MainActor [weak self] in
                await self?.tick()
            }
        }
    }

    // MARK: - Run history

    private func record(_ run: SessionRunRecord) {
        runs.insert(run, at: 0)
        if runs.count > Self.runHistoryLimit {
            runs = Array(runs.prefix(Self.runHistoryLimit))
        }
        save()
    }

    public func clearHistory() {
        runs = []
        save()
    }

    // MARK: - Notifications

    public func requestNotificationPermission() {
        guard Self.notificationsAreAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { granted, error in
            if let error {
                scheduleLogger.error(
                    "Notification permission failed: \(error.localizedDescription, privacy: .public)"
                )
            } else {
                scheduleLogger.info("Notification permission granted: \(granted)")
            }
        }
    }

    /// `UNUserNotificationCenter` needs a real application bundle, which is
    /// missing when the executable is run straight from `swift run`.
    private static var notificationsAreAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
            && Bundle.main.bundleURL.pathExtension == "app"
    }

    private func notify(title: String, body: String) {
        guard Self.notificationsAreAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Persistence

    private func load() {
        isLoading = true
        defer { isLoading = false }
        guard let data = try? Data(contentsOf: stateFile),
              let document = try? JSONDecoder.sessionSchedule.decode(
                  StateDocument.self,
                  from: data
              )
        else {
            return
        }
        settings = document.settings
        runs = document.runs
        lastAnchorRunAt = document.lastAnchorRunAt
    }

    private func save() {
        let document = StateDocument(
            settings: settings,
            runs: runs,
            lastAnchorRunAt: lastAnchorRunAt
        )
        guard let data = try? JSONEncoder.sessionSchedule.encode(document)
        else {
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: stateFile.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: stateFile, options: .atomic)
        } catch {
            scheduleLogger.error(
                "Session schedule could not be saved: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}

private struct StateDocument: Codable {
    let settings: SessionScheduleSettings
    let runs: [SessionRunRecord]
    let lastAnchorRunAt: Date?
}

private extension JSONEncoder {
    static var sessionSchedule: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var sessionSchedule: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
