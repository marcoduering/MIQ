import AppKit
import SwiftUI
import MIQCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }
}

@main
struct MIQApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // Owned here rather than in ContentView so the updater starts with the app,
    // not with the Settings window, and survives that window closing.
    @StateObject private var updater = UpdaterController()

    #if DEBUG
    private static let appGroupStore = UserDefaults(suiteName: MIQConfig.appGroupID)
    @AppStorage(MIQConfig.Keys.debugShowLayoutBorders, store: Self.appGroupStore) private var debugShowLayoutBorders = false
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(updater)
        }
        .defaultSize(width: 550, height: 600)
        .windowResizability(.contentSize)
        .commands {
            // The conventional slot for this item, directly under "About MIQ".
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }
            #if DEBUG
            CommandMenu("Debug") {
                Toggle("Show layout borders in preview", isOn: $debugShowLayoutBorders)
            }
            #endif
        }
    }
}
