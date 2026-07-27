import ServiceManagement
import SwiftUI

struct CompanionSettingsView: View {
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
        .frame(width: 450, height: 330)
        .padding()
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
