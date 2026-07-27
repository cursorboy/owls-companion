import AppKit
import OwlsCompanionCore
import SwiftUI

enum CompanionUsagePresentation {
    case menuBar
    case full
}

struct CompanionUsageView: View {
    @EnvironmentObject private var store: UsageStore
    @Environment(\.openWindow) private var openWindow
    let presentation: CompanionUsagePresentation

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 10) {
                    if store.snapshots.isEmpty {
                        loadingState
                    } else {
                        LocalUsageSummary(snapshots: store.snapshots)
                        ForEach(store.snapshots) { snapshot in
                            ProviderUsageCard(snapshot: snapshot)
                        }
                    }
                }
                .padding(12)
            }
            if presentation == .menuBar {
                Divider()
                footer
            }
        }
        .frame(
            minWidth: presentation == .menuBar ? 390 : nil,
            maxWidth: presentation == .menuBar ? 390 : .infinity,
            maxHeight: presentation == .menuBar ? 620 : .infinity
        )
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: owlsCompanionMarkImage)
                .renderingMode(.template)
                .frame(width: 21, height: 16)
                .foregroundStyle(Color(red: 0.18, green: 0.62, blue: 1))
            VStack(alignment: .leading, spacing: 1) {
                Text("Usage")
                    .font(.system(size: 14, weight: .semibold))
                Text("Claude Code, Codex, and OpenCode")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task {
                    await store.refresh(allowCredentialInteraction: true)
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(store.isRefreshing ? .degrees(360) : .zero)
                    .animation(
                        store.isRefreshing
                            ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                            : .default,
                        value: store.isRefreshing
                    )
            }
            .buttonStyle(.borderless)
            .disabled(store.isRefreshing)
            .help("Refresh usage")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Reading local usage")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 42)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let lastRefresh = store.lastRefresh {
                Text("Updated \(lastRefresh, style: .relative) ago")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else {
                Text("Updates every 5 minutes")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                openWindow(id: "companion")
                NSApplication.shared.activate(ignoringOtherApps: true)
            } label: {
                Text("Open Companion")
            }
            .buttonStyle(.borderless)
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("Quit")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct ProviderUsageCard: View {
    let snapshot: ProviderUsageSnapshot

    private var progressMetrics: [UsageMetric] {
        snapshot.metrics.filter { $0.kind == .progress }
    }

    private var valueMetrics: [UsageMetric] {
        snapshot.metrics.filter { $0.kind == .value }
    }

    private var history: [UsageHistoryPoint] {
        snapshot.history ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                ProviderIcon(provider: snapshot.id)
                    .frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text(snapshot.id.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    Text(snapshot.plan ?? snapshot.source)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if snapshot.error == nil {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 7, height: 7)
                        .help("Usage is available")
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
            }

            if let error = snapshot.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color.orange.opacity(0.08))
                    )
            }

            if !progressMetrics.isEmpty {
                CardSectionLabel(text: "Subscription utilization")
                VStack(spacing: 9) {
                    ForEach(progressMetrics) { metric in
                        TimelineView(.periodic(from: .now, by: 30)) {
                            context in
                            UsageMetricRow(
                                metric: metric,
                                now: context.date
                            )
                        }
                    }
                }
            }

            if !valueMetrics.isEmpty {
                CardSectionLabel(text: "Account")
                VStack(spacing: 9) {
                    ForEach(valueMetrics) { metric in
                        UsageMetricRow(metric: metric)
                    }
                }
            }

            if !history.isEmpty {
                CardSectionLabel(text: "Local usage")
                ProviderHistorySummary(
                    provider: snapshot.id,
                    points: history
                )
            } else if snapshot.error == nil && snapshot.metrics.isEmpty {
                Text("No usage metrics were returned.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 11)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct CardSectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
    }
}

private struct UsageMetricRow: View {
    let metric: UsageMetric
    let now: Date

    init(metric: UsageMetric, now: Date = Date()) {
        self.metric = metric
        self.now = now
    }

    var body: some View {
        switch metric.kind {
        case .progress:
            progressRow
        case .value:
            valueRow
        }
    }

    private var progressRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(metric.label)
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                if let detail = metric.detail {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else if let used = metric.usedPercent {
                    Text(
                        "\(Int(used.rounded()))% used · "
                            + "\(Int((100 - used).rounded()))% left"
                    )
                        .font(.system(size: 10, weight: .medium))
                }
            }
            ProgressView(value: metric.usedPercent ?? 0, total: 100)
                .tint(meterColor)
                .controlSize(.small)
            HStack(spacing: 6) {
                if let projection {
                    Label(projectionText(projection), systemImage: projectionIcon(projection))
                        .foregroundStyle(projectionColor(projection))
                        .help(projectionHelp(projection))
                }
                Spacer()
                if let reset = metric.resetsAt {
                    Text("Resets \(reset, style: .relative)")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 9, weight: .medium))
        }
    }

    private var valueRow: some View {
        HStack {
            Text(metric.label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text(metric.value ?? "")
                .font(.system(size: 11, weight: .medium))
                .help(metric.detail ?? "")
        }
    }

    private var meterColor: Color {
        if let projection {
            return projectionColor(projection)
        }
        switch metric.usedPercent ?? 0 {
        case ..<70:
            return .blue
        case ..<90:
            return .orange
        default:
            return .red
        }
    }

    private var projection: UsageProjection? {
        UsageProjectionCalculator.calculate(metric: metric, now: now)
    }

    private func projectionText(_ projection: UsageProjection) -> String {
        switch projection.status {
        case .onPace:
            let left = max(0, 100 - projection.projectedUsedPercentAtReset)
            return "On pace, ~\(Int(left.rounded()))% left at reset"
        case .close:
            let left = max(0, 100 - projection.projectedUsedPercentAtReset)
            return "Close, ~\(Int(left.rounded()))% left at reset"
        case .mayRunOut:
            guard let exhaustion = projection.projectedExhaustionAt else {
                return "May run out before reset"
            }
            return "May run out \(relativeTime(to: exhaustion))"
        case .exhausted:
            return "Limit reached"
        }
    }

    private func projectionIcon(_ projection: UsageProjection) -> String {
        switch projection.status {
        case .onPace:
            "checkmark.circle.fill"
        case .close:
            "exclamationmark.circle.fill"
        case .mayRunOut:
            "flame.fill"
        case .exhausted:
            "xmark.octagon.fill"
        }
    }

    private func projectionColor(_ projection: UsageProjection) -> Color {
        switch projection.status {
        case .onPace:
            .blue
        case .close:
            .orange
        case .mayRunOut, .exhausted:
            .red
        }
    }

    private func projectionHelp(_ projection: UsageProjection) -> String {
        let projected = Int(projection.projectedUsedPercentAtReset.rounded())
        return "At the average pace since this window began, usage is projected to reach \(projected)% by reset."
    }

    private func relativeTime(to date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

private struct LocalUsageSummary: View {
    let snapshots: [ProviderUsageSnapshot]

    private var points: [UsageHistoryPoint] {
        snapshots.flatMap { $0.history ?? [] }
    }

    private var today: [UsageHistoryPoint] {
        points.filter { Calendar.current.isDateInToday($0.date) }
    }

    private var thirtyDayCost: Double {
        points.compactMap(\.costUSD).reduce(0, +)
    }

    private var todayTokens: Double {
        today.reduce(0) { $0 + $1.tokens }
    }

    private var thirtyDayTokens: Double {
        points.reduce(0) { $0 + $1.tokens }
    }

    private var combinedHistory: [UsageHistoryPoint] {
        let grouped = Dictionary(grouping: points, by: \.date)
        return grouped.map { date, values in
            let costs = values.compactMap(\.costUSD)
            return UsageHistoryPoint(
                date: date,
                tokens: values.reduce(0) { $0 + $1.tokens },
                costUSD: costs.isEmpty ? nil : costs.reduce(0, +)
            )
        }
        .sorted { $0.date < $1.date }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Combined local usage")
                    .font(.system(size: 10, weight: .semibold))
                Spacer()
                Text("All clients")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 0) {
                summary(
                    label: "Today cost",
                    value: currency(
                        today.compactMap(\.costUSD).reduce(0, +)
                    ),
                    detail: "\(compact(todayTokens)) tokens"
                )
                Divider()
                    .frame(height: 34)
                    .padding(.horizontal, 12)
                summary(
                    label: "30-day cost",
                    value: currency(thirtyDayCost),
                    detail: "\(compact(thirtyDayTokens)) tokens"
                )
                Spacer(minLength: 12)
                UsageHistoryChart(
                    points: Array(combinedHistory.suffix(14))
                )
                .frame(width: 104)
            }
            Text("Cost combines recorded OpenCode spend with estimated Claude Code and Codex spend.")
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 11)
                .fill(Color.accentColor.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .stroke(Color.accentColor.opacity(0.16), lineWidth: 1)
        )
        .help("Combined token count and cost across local coding clients")
    }

    private func summary(
        label: String,
        value: String,
        detail: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
            Text(detail)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }
}

private struct ProviderHistorySummary: View {
    let provider: UsageProviderID
    let points: [UsageHistoryPoint]

    private var visiblePoints: [UsageHistoryPoint] {
        Array(points.suffix(14))
    }

    private var today: UsageHistoryPoint? {
        points.last { Calendar.current.isDateInToday($0.date) }
    }

    private var totalCost: Double {
        points.compactMap(\.costUSD).reduce(0, +)
    }

    private var totalTokens: Double {
        points.reduce(0) { $0 + $1.tokens }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                historyValue(
                    label: provider == .opencode
                        ? "Recorded cost"
                        : "Estimated cost",
                    value: currency(totalCost),
                    detail: "Last 30 days"
                )
                Spacer()
                historyValue(
                    label: "Tokens",
                    value: compact(totalTokens),
                    detail: "Last 30 days"
                )
                Spacer()
                historyValue(
                    label: "Today",
                    value: compact(today?.tokens ?? 0),
                    detail: "tokens"
                )
            }
            UsageHistoryChart(points: visiblePoints)
        }
    }

    private func historyValue(
        label: String,
        value: String,
        detail: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
            Text(detail)
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
        }
    }
}

private struct UsageHistoryChart: View {
    let points: [UsageHistoryPoint]

    private var maximum: Double {
        max(points.map(\.tokens).max() ?? 0, 1)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(points) { point in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor.opacity(
                        Calendar.current.isDateInToday(point.date)
                            ? 0.95
                            : 0.42
                    ))
                    .frame(
                        maxWidth: .infinity,
                        minHeight: 2,
                        maxHeight: CGFloat(max(
                            2,
                            38 * point.tokens / maximum
                        ))
                    )
                    .help(chartHelp(point))
            }
        }
        .frame(height: 38, alignment: .bottom)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
        }
    }

    private func chartHelp(_ point: UsageHistoryPoint) -> String {
        let date = point.date.formatted(
            .dateTime.month(.abbreviated).day()
        )
        let cost = point.costUSD.map(currency) ?? "Cost unavailable"
        return "\(date): \(compact(point.tokens)) tokens, \(cost)"
    }
}

private func currency(_ value: Double) -> String {
    value.formatted(
        .currency(code: "USD")
            .precision(.fractionLength(value < 10 ? 2 : 0))
    )
}

private func compact(_ value: Double) -> String {
    switch abs(value) {
    case 1_000_000_000...:
        String(format: "%.1fB", value / 1_000_000_000)
    case 1_000_000...:
        String(format: "%.1fM", value / 1_000_000)
    case 1_000...:
        String(format: "%.1fK", value / 1_000)
    default:
        String(format: "%.0f", value)
    }
}

private struct ProviderIcon: View {
    let provider: UsageProviderID

    var body: some View {
        if let image = image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: fallbackSymbol)
                .resizable()
                .scaledToFit()
        }
    }

    private var image: NSImage? {
        guard let url = Bundle.main.url(
            forResource: provider.rawValue,
            withExtension: "svg"
        ) else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    private var fallbackSymbol: String {
        switch provider {
        case .claude:
            "sparkles"
        case .codex:
            "hexagon"
        case .opencode:
            "terminal"
        }
    }
}
