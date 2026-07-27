import AppKit
import OwlsCompanionCore
import SwiftUI

let owlsCompanionMarkImage: NSImage = {
    let size = NSSize(width: 21, height: 16)
    let image = NSImage(size: size, flipped: false) { _ in
        NSColor.black.setFill()
        let blocks = [
            NSRect(x: 0.5, y: 5, width: 3.2, height: 10.5),
            NSRect(x: 4.7, y: 0.5, width: 3.2, height: 9),
            NSRect(x: 8.9, y: 3.2, width: 3.2, height: 10),
            NSRect(x: 13.1, y: 0.5, width: 3.2, height: 9),
            NSRect(x: 17.3, y: 5, width: 3.2, height: 10.5)
        ]
        for block in blocks {
            NSBezierPath(
                roundedRect: block,
                xRadius: 0.7,
                yRadius: 0.7
            ).fill()
        }
        return true
    }
    image.isTemplate = true
    return image
}()

@MainActor
private final class CompanionApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(
        _ notification: Notification
    ) {
        UsageStore.shared.start()
        Task {
            await CompanionAccountStore.shared.refresh()
        }
    }
}

@main
struct OwlsCompanionApp: App {
    @NSApplicationDelegateAdaptor(CompanionApplicationDelegate.self)
    private var applicationDelegate
    @StateObject private var usageStore = UsageStore.shared
    @StateObject private var accountStore = CompanionAccountStore.shared
    @StateObject private var updateStore = CompanionUpdateStore.shared

    var body: some Scene {
        Window("owls Companion", id: "companion") {
            CompanionRootView()
                .environmentObject(usageStore)
                .environmentObject(accountStore)
                .environmentObject(updateStore)
                .frame(minWidth: 760, minHeight: 560)
        }
        .defaultSize(width: 940, height: 700)

        MenuBarExtra {
            CompanionUsageView(presentation: .menuBar)
                .environmentObject(usageStore)
                .environmentObject(accountStore)
        } label: {
            Image(nsImage: owlsCompanionMarkImage)
                .renderingMode(.template)
                .accessibilityLabel("owls Companion")
        }
        .menuBarExtraStyle(.window)

        Settings {
            CompanionSettingsView()
        }
    }
}
