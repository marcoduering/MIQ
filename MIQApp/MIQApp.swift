import SwiftUI

@main
struct MIQApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 550, height: 700)
        .windowResizability(.contentSize)
    }
}
