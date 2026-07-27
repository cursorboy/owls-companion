import OwlsCompanionCore
import ServiceManagement
import SwiftUI

struct CompanionSettingsView: View {
    @StateObject private var scheduleStore = SessionScheduleStore.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        updateLaunchAtLogin(enabled)
                    }
                LabeledContent("Refresh") {
                    Text("Every 5 minutes")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Session schedule") {
                LabeledContent("claude command") {
                    TextField(
                        detectedExecutablePath ?? "Not found",
                        text: Binding(
                            get: {
                                scheduleStore.settings
                                    .executablePathOverride ?? ""
                            },
                            set: { newValue in
                                let trimmed = newValue.trimmingCharacters(
                                    in: .whitespaces
                                )
                                scheduleStore.settings.executablePathOverride =
                                    trimmed.isEmpty ? nil : trimmed
                            }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                }
                Text(
                    "Leave this empty to use the copy of `claude` found on "
                    + "this Mac. Anchors are set in the Schedule section of "
                    + "the main window."
                )
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }

            Section("Updates") {
                Text("Run `owls update`, then `owls companion update` to rebuild this app.")
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Text(
                    "Usage is read on this Mac from the existing client login and local history. " +
                    "Open Workloads does not receive or store these credentials."
                )
                .foregroundStyle(.secondary)
            }

            if let launchError {
                Text(launchError)
                    .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 460)
        .padding()
    }

    private var detectedExecutablePath: String? {
        SessionPrimer.resolveExecutable(override: nil)?.path
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchError = nil
        } catch {
            launchError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
