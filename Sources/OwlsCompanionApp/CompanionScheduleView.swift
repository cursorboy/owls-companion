import OwlsCompanionCore
import SwiftUI

struct CompanionScheduleView: View {
    @EnvironmentObject private var store: SessionScheduleStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                pageHeader
                windowStatus
                CoverageTimeline(settings: store.settings)
                anchorsCard
                behaviourCard
                historyCard
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(32)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            store.requestNotificationPermission()
        }
    }

    private var pageHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Schedule")
                    .font(.system(size: 26, weight: .semibold))
                Text(
                    "A Claude session window opens on the first request after "
                    + "the last one lapsed. Anchoring that request to fixed "
                    + "times lines the windows up with the hours you work."
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            Button {
                Task {
                    await store.runNow()
                }
            } label: {
                if store.isRunning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Open a window now", systemImage: "bolt.fill")
                }
            }
            .disabled(store.isRunning)
            .help("Send one small prompt to open a session window right away")
        }
    }

    // MARK: - Status

    private var windowStatus: some View {
        HStack(spacing: 14) {
            Image(systemName: store.openWindowEndsAt == nil
                ? "moon.zzz"
                : "clock.badge.checkmark")
                .font(.system(size: 17, weight: .medium))
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(statusTint.opacity(0.14))
                )
                .foregroundStyle(statusTint)

            VStack(alignment: .leading, spacing: 3) {
                Text(statusTitle)
                    .font(.system(size: 13, weight: .semibold))
                Text(nextRunText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(statusTint.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(statusTint.opacity(0.18))
        )
    }

    private var statusTint: Color {
        store.openWindowEndsAt == nil ? .secondary : .green
    }

    private var statusTitle: String {
        guard let endsAt = store.openWindowEndsAt else {
            return "No window is open"
        }
        let time = endsAt.formatted(date: .omitted, time: .shortened)
        return "Window open until \(time)"
    }

    private var nextRunText: String {
        guard store.settings.isEnabled else {
            return "The schedule is off."
        }
        guard let next = store.nextRun else {
            return "No anchors are enabled."
        }
        let action = store.settings.mode == .notifyOnly
            ? "Next reminder"
            : "Next anchor"
        return "\(action) \(next.date.formatted(.relative(presentation: .named)))"
            + " at \(next.date.formatted(date: .omitted, time: .shortened))."
    }

    // MARK: - Anchors

    private var anchorsCard: some View {
        Card(
            title: "Anchors",
            subtitle: "Space these five hours apart so each window opens as "
                + "the last one lapses."
        ) {
            VStack(spacing: 0) {
                ForEach(sortedAnchorIDs, id: \.self) { anchorID in
                    if let index = index(of: anchorID) {
                        AnchorRow(
                            anchor: binding(at: index),
                            isSwallowed: swallowedAnchorIDs.contains(anchorID),
                            onDelete: { remove(anchorID) }
                        )
                        if anchorID != sortedAnchorIDs.last {
                            Divider().padding(.vertical, 4)
                        }
                    }
                }
                if store.settings.anchors.isEmpty {
                    Text("No anchors yet.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }
            }

            HStack {
                Button {
                    addAnchor()
                } label: {
                    Label("Add anchor", systemImage: "plus")
                }
                Spacer()
                Button("Run every day") {
                    for index in store.settings.anchors.indices {
                        store.settings.anchors[index].weekdays =
                            SessionAnchor.everyDay
                    }
                }
                .buttonStyle(.link)
                .disabled(store.settings.anchors.isEmpty)
                Button("Use the default three") {
                    store.settings.anchors = SessionScheduleSettings
                        .defaultAnchors
                }
                .buttonStyle(.link)
            }
            .padding(.top, 10)
        }
    }

    private var sortedAnchorIDs: [UUID] {
        store.settings.sortedAnchors.map(\.id)
    }

    private var swallowedAnchorIDs: Set<UUID> {
        let weekday = Calendar.current.component(.weekday, from: Date())
        let spans = SessionAnchorPlanner.coverage(
            settings: store.settings,
            weekday: weekday
        )
        return Set(
            spans.filter(\.isSwallowedByPreviousWindow).map(\.anchorID)
        )
    }

    private func index(of id: UUID) -> Int? {
        store.settings.anchors.firstIndex { $0.id == id }
    }

    private func binding(at index: Int) -> Binding<SessionAnchor> {
        Binding(
            get: { store.settings.anchors[index] },
            set: { store.settings.anchors[index] = $0 }
        )
    }

    private func addAnchor() {
        // Placed one window after the last anchor, which is where a new one is
        // usually wanted.
        let last = store.settings.sortedAnchors.last
        let windowMinutes = Int(claudeSessionWindowDuration / 60)
        let minutes = ((last?.minutesFromMidnight ?? 480) + windowMinutes)
            % (24 * 60)
        store.settings.anchors.append(SessionAnchor(
            hour: minutes / 60,
            minute: minutes % 60,
            weekdays: last?.weekdays ?? SessionAnchor.weekdaysOnly
        ))
    }

    private func remove(_ id: UUID) {
        store.settings.anchors.removeAll { $0.id == id }
    }

    // MARK: - Behaviour

    private var behaviourCard: some View {
        Card(
            title: "Behaviour",
            subtitle: nil
        ) {
            Toggle(
                "Run this schedule",
                isOn: Binding(
                    get: { store.settings.isEnabled },
                    set: { store.settings.isEnabled = $0 }
                )
            )

            Picker(
                "At each anchor",
                selection: Binding(
                    get: { store.settings.mode },
                    set: { store.settings.mode = $0 }
                )
            ) {
                ForEach(SessionScheduleMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)

            Toggle(
                "Skip when a window is already open",
                isOn: Binding(
                    get: { store.settings.skipWhenWindowIsOpen },
                    set: { store.settings.skipWhenWindowIsOpen = $0 }
                )
            )
            .help(
                "A request sent during an open window joins that window "
                + "instead of starting a new one, so sending one would only "
                + "spend quota."
            )

            LabeledContent("Catch up within") {
                Stepper(
                    value: Binding(
                        get: { store.settings.catchUpMinutes },
                        set: { store.settings.catchUpMinutes = $0 }
                    ),
                    in: 0...240,
                    step: 15
                ) {
                    Text("\(store.settings.catchUpMinutes) minutes")
                        .monospacedDigit()
                }
            }
            .help(
                "How late a missed anchor may still open its window, for "
                + "example after the Mac wakes from sleep."
            )

            LabeledContent("Model") {
                TextField(
                    "haiku",
                    text: Binding(
                        get: { store.settings.model },
                        set: { store.settings.model = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
            }
            .help("A smaller model keeps the cost of opening a window down.")

            LabeledContent("Prompt") {
                TextField(
                    SessionScheduleSettings.defaultPrompt,
                    text: Binding(
                        get: { store.settings.prompt },
                        set: { store.settings.prompt = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
            }

            Text(
                "Opening a window costs about one cent, because the request "
                + "still loads a system prompt. Weekly quota is spent either "
                + "way, so anchor only the hours you actually work."
            )
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
        }
    }

    // MARK: - History

    private var historyCard: some View {
        Card(
            title: "Recent runs",
            subtitle: nil
        ) {
            if store.runs.isEmpty {
                Text("Nothing has run yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 7) {
                    ForEach(store.runs.prefix(8)) { run in
                        RunRow(run: run)
                    }
                }
                HStack {
                    Spacer()
                    Button("Clear history") {
                        store.clearHistory()
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 10))
                }
                .padding(.top, 6)
            }
        }
    }
}

// MARK: - Anchor row

private struct AnchorRow: View {
    @Binding var anchor: SessionAnchor
    let isSwallowed: Bool
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Toggle("", isOn: $anchor.isEnabled)
                    .labelsHidden()
                    .help("Enable this anchor")

                DatePicker(
                    "",
                    selection: timeBinding,
                    displayedComponents: .hourAndMinute
                )
                .labelsHidden()
                .datePickerStyle(.field)
                .frame(width: 92)

                Text("to \(endLabel)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Spacer()

                WeekdayPicker(weekdays: $anchor.weekdays)

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove this anchor")
            }
            .opacity(anchor.isEnabled ? 1 : 0.5)

            if isSwallowed, anchor.isEnabled {
                Label(
                    "An earlier anchor still holds a window open at this "
                    + "time, so this one will not start a new window.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.system(size: 10))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 5)
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                var components = DateComponents()
                components.hour = anchor.hour
                components.minute = anchor.minute
                return Calendar.current.date(from: components) ?? Date()
            },
            set: { newValue in
                let parts = Calendar.current.dateComponents(
                    [.hour, .minute],
                    from: newValue
                )
                anchor.hour = parts.hour ?? anchor.hour
                anchor.minute = parts.minute ?? anchor.minute
            }
        )
    }

    private var endLabel: String {
        let windowMinutes = Int(claudeSessionWindowDuration / 60)
        let total = (anchor.minutesFromMidnight + windowMinutes) % (24 * 60)
        var components = DateComponents()
        components.hour = total / 60
        components.minute = total % 60
        guard let date = Calendar.current.date(from: components) else {
            return ""
        }
        return date.formatted(date: .omitted, time: .shortened)
    }
}

private struct WeekdayPicker: View {
    @Binding var weekdays: Set<Int>

    private var orderedWeekdays: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(orderedWeekdays, id: \.self) { weekday in
                let isOn = weekdays.contains(weekday)
                Button {
                    toggle(weekday)
                } label: {
                    Text(symbol(weekday))
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 19, height: 19)
                        .background(
                            Circle().fill(
                                isOn
                                    ? Color.accentColor
                                    : Color.primary.opacity(0.07)
                            )
                        )
                        .foregroundStyle(isOn ? Color.white : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func toggle(_ weekday: Int) {
        var updated = weekdays
        if updated.contains(weekday) {
            updated.remove(weekday)
        } else {
            updated.insert(weekday)
        }
        // An anchor with no days would never run, so the last day stays on.
        guard !updated.isEmpty else { return }
        weekdays = updated
    }

    private func symbol(_ weekday: Int) -> String {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        let index = weekday - 1
        return symbols.indices.contains(index) ? symbols[index] : "?"
    }
}

// MARK: - Coverage timeline

private struct CoverageTimeline: View {
    let settings: SessionScheduleSettings

    private var weekday: Int {
        Calendar.current.component(.weekday, from: Date())
    }

    private var spans: [SessionCoverageSpan] {
        SessionAnchorPlanner.coverage(settings: settings, weekday: weekday)
            .filter { !$0.isSwallowedByPreviousWindow }
    }

    private var gaps: [ClosedRange<Int>] {
        SessionAnchorPlanner.gaps(
            in: SessionAnchorPlanner.coverage(
                settings: settings,
                weekday: weekday
            )
        )
    }

    private var coveredHours: Double {
        Double(SessionAnchorPlanner.coveredMinutes(
            in: SessionAnchorPlanner.coverage(
                settings: settings,
                weekday: weekday
            )
        )) / 60
    }

    var body: some View {
        Card(
            title: "Today's coverage",
            subtitle: String(
                format: "%.1f hours of today are inside a window.",
                coveredHours
            )
        ) {
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.primary.opacity(0.06))
                        .frame(height: 26)

                    ForEach(gaps, id: \.lowerBound) { gap in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.orange.opacity(0.28))
                            .frame(
                                width: barWidth(
                                    from: gap.lowerBound,
                                    to: gap.upperBound,
                                    total: width
                                ),
                                height: 26
                            )
                            .offset(x: offset(gap.lowerBound, total: width))
                            .help("No window covers this stretch.")
                    }

                    ForEach(spans) { span in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.accentColor.opacity(0.75))
                            .frame(
                                width: barWidth(
                                    from: span.startMinute,
                                    to: span.endMinute,
                                    total: width
                                ),
                                height: 26
                            )
                            .offset(x: offset(span.startMinute, total: width))
                            .help(windowHelp(span))
                    }

                    Rectangle()
                        .fill(Color.red)
                        .frame(width: 1.5, height: 34)
                        .offset(x: offset(currentMinute, total: width), y: -4)
                        .help("Now")
                }
            }
            .frame(height: 30)

            HStack(spacing: 0) {
                ForEach([0, 6, 12, 18], id: \.self) { hour in
                    Text("\(hour):00")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, 2)

            if !gaps.isEmpty {
                Label(
                    gapSummary,
                    systemImage: "exclamationmark.circle"
                )
                .font(.system(size: 10))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            }
        }
    }

    private var currentMinute: Int {
        let parts = Calendar.current.dateComponents(
            [.hour, .minute],
            from: Date()
        )
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    private var gapSummary: String {
        let ranges = gaps.map { gap in
            "\(label(gap.lowerBound)) to \(label(gap.upperBound))"
        }
        let joined = ranges.joined(separator: ", ")
        return gaps.count == 1
            ? "One uncovered stretch: \(joined)."
            : "Uncovered stretches: \(joined)."
    }

    private func windowHelp(_ span: SessionCoverageSpan) -> String {
        "Window from \(label(span.startMinute)) to \(label(span.endMinute))."
    }

    private func label(_ minute: Int) -> String {
        var components = DateComponents()
        components.hour = (minute / 60) % 24
        components.minute = minute % 60
        guard let date = Calendar.current.date(from: components) else {
            return ""
        }
        return date.formatted(date: .omitted, time: .shortened)
    }

    private func offset(_ minute: Int, total: CGFloat) -> CGFloat {
        total * CGFloat(minute) / CGFloat(24 * 60)
    }

    private func barWidth(
        from start: Int,
        to end: Int,
        total: CGFloat
    ) -> CGFloat {
        max(2, total * CGFloat(end - start) / CGFloat(24 * 60))
    }
}

// MARK: - Run row

private struct RunRow: View {
    let run: SessionRunRecord

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .foregroundStyle(tint)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(run.detail)
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                Text(run.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if let cost = run.costUSD, cost > 0 {
                Text(cost.formatted(
                    .currency(code: "USD").precision(.fractionLength(3))
                ))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var symbol: String {
        switch run.outcome {
        case .started:
            "checkmark.circle.fill"
        case .skippedWindowOpen:
            "forward.circle.fill"
        case .notified:
            "bell.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch run.outcome {
        case .started:
            .green
        case .skippedWindowOpen:
            .secondary
        case .notified:
            .blue
        case .failed:
            .orange
        }
    }
}

// MARK: - Card

private struct Card<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.08))
        )
    }
}
