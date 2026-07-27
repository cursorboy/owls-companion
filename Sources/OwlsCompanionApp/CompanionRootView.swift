import AppKit
import OwlsCompanionCore
import SwiftUI

private enum CompanionSection: String, CaseIterable, Identifiable {
    case usage
    case account
    case updates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .usage:
            "Usage"
        case .account:
            "Account"
        case .updates:
            "Updates"
        }
    }

    var symbol: String {
        switch self {
        case .usage:
            "chart.xyaxis.line"
        case .account:
            "person.crop.circle"
        case .updates:
            "arrow.triangle.2.circlepath"
        }
    }
}

struct CompanionRootView: View {
    @EnvironmentObject private var accountStore: CompanionAccountStore
    @State private var selection: CompanionSection? = .usage

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                brand
                List(CompanionSection.allCases, selection: $selection) {
                    section in
                    Label(section.title, systemImage: section.symbol)
                        .tag(section)
                }
                .listStyle(.sidebar)
                footer
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            switch selection ?? .usage {
            case .usage:
                CompanionUsageView(presentation: .full)
            case .account:
                CompanionAccountView()
            case .updates:
                CompanionUpdatesView()
            }
        }
        .task {
            await accountStore.refresh()
        }
    }

    private var brand: some View {
        HStack(spacing: 10) {
            Image(nsImage: owlsCompanionMarkImage)
                .renderingMode(.template)
                .frame(width: 21, height: 16)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text("owls Companion")
                    .font(.system(size: 13, weight: .semibold))
                Text("Open Workloads")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var footer: some View {
        HStack {
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(14)
    }
}

private struct CompanionAccountView: View {
    @EnvironmentObject private var store: CompanionAccountStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                pageHeader
                content
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(32)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var pageHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Account")
                    .font(.system(size: 26, weight: .semibold))
                Text("The Open Workloads account connected through owls.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task {
                    await store.refresh()
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(store.isRefreshing)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .loading:
            ProgressView("Loading account")
                .frame(maxWidth: .infinity, minHeight: 260)
        case let .signedOut(message):
            accountMessage(
                title: "Sign in with owls",
                message: message,
                symbol: "person.crop.circle.badge.exclamationmark"
            )
        case let .unavailable(message):
            accountMessage(
                title: "Account unavailable",
                message: message,
                symbol: "exclamationmark.triangle"
            )
        case let .signedIn(account):
            signedInAccount(account)
        }
    }

    private func signedInAccount(
        _ account: CompanionAccount
    ) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                AccountAvatar(account: account)
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.name)
                        .font(.system(size: 18, weight: .semibold))
                    Text(account.email)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label(
                    account.emailVerified ? "Verified" : "Unverified",
                    systemImage: account.emailVerified
                        ? "checkmark.seal.fill"
                        : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(
                    account.emailVerified ? Color.green : Color.orange
                )
            }

            Divider()

            accountRow("Account ID", value: account.id)
            accountRow("Session ID", value: account.sessionID)
            accountRow(
                "Session expires",
                value: account.sessionExpiresAt?.formatted(
                    date: .abbreviated,
                    time: .shortened
                ) ?? "Unknown"
            )
            accountRow("Authentication", value: account.authURL.host ?? account.authURL.absoluteString)

            Text(
                "The companion reads the existing owls session locally. " +
                "It never displays or stores another copy of the access token."
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.top, 6)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.08))
        )
    }

    private func accountRow(
        _ label: String,
        value: String
    ) -> some View {
        LabeledContent(label) {
            Text(value)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .font(.system(size: 12))
    }

    private func accountMessage(
        title: String,
        message: String,
        symbol: String
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            Text("owls login")
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }
}

private struct AccountAvatar: View {
    let account: CompanionAccount

    var body: some View {
        AsyncImage(url: account.imageURL) { phase in
            switch phase {
            case let .success(image):
                image
                    .resizable()
                    .scaledToFill()
            default:
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.14))
                    Text(initials)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .clipShape(Circle())
    }

    private var initials: String {
        let words = account.name.split(separator: " ")
        return words.prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()
            .uppercased()
    }
}

private struct CompanionUpdatesView: View {
    @EnvironmentObject private var store: CompanionUpdateStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Updates")
                            .font(.system(size: 26, weight: .semibold))
                        Text("CLI and companion releases are checked independently.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task {
                            await store.refresh()
                        }
                    } label: {
                        Label("Check again", systemImage: "arrow.clockwise")
                    }
                    .disabled(store.isRefreshing)
                }

                VStack(alignment: .leading, spacing: 16) {
                    updateComponent(
                        title: "owls CLI",
                        symbol: "terminal",
                        status: store.cli,
                        command: "owls update"
                    )
                    Divider()
                    updateComponent(
                        title: "owls Companion",
                        symbol: "macwindow",
                        status: store.companion,
                        command: "owls companion update --from-source"
                    )
                }
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.primary.opacity(0.08))
                )

                Text(
                    "Signed and notarized automatic app updates remain unavailable " +
                    "until official macOS releases are introduced."
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(32)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await store.refresh()
        }
    }

    private func updateComponent(
        title: String,
        symbol: String,
        status: CompanionUpdateComponent,
        command: String
    ) -> some View {
        HStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color.accentColor.opacity(0.12))
                )
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                HStack(spacing: 8) {
                    Text("Installed \(status.currentVersion ?? "Unknown")")
                    if let latest = status.latestVersion {
                        Text("Latest \(latest)")
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                Text(command)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
            }
            Spacer()
            updateBadge(status.availability)
        }
    }

    @ViewBuilder
    private func updateBadge(
        _ availability: CompanionUpdateAvailability
    ) -> some View {
        switch availability {
        case .checking:
            ProgressView()
                .controlSize(.small)
        case .current:
            Label("Up to date", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .updateAvailable:
            Label("Update available", systemImage: "arrow.down.circle.fill")
                .foregroundStyle(.blue)
        case let .unavailable(message):
            Label("Check unavailable", systemImage: "exclamationmark.circle")
                .foregroundStyle(.secondary)
                .help(message)
        }
    }
}
