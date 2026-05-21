import AppKit
import SwiftUI
import MIQCore

#if DEBUG
enum DebugFlags {
    static let simulateUpdateAvailableKey = "debug.simulateUpdateAvailable"
}
#endif

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct MIQApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    #if DEBUG
    private static let appGroupStore = UserDefaults(suiteName: MIQConfig.appGroupID)
    // Backs the Debug menu's "Simulate update available" toggle. Same key is
    // also bound in ContentView so the About pane reacts to flips; both omit
    // `store:`, so they share via UserDefaults.standard.
    @AppStorage(DebugFlags.simulateUpdateAvailableKey) private var simulateUpdateAvailable = false
    @AppStorage(MIQConfig.Keys.debugShowLayoutBorders, store: Self.appGroupStore) private var debugShowLayoutBorders = false
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 550, height: 600)
        .windowResizability(.contentSize)
        #if DEBUG
        .commands {
            CommandMenu("Debug") {
                Toggle("Simulate update available", isOn: $simulateUpdateAvailable)
                Toggle("Show layout borders in preview", isOn: $debugShowLayoutBorders)
            }
        }
        #endif
    }
}
