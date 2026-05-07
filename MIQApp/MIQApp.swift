import SwiftUI
import AppKit

@main
struct MIQApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About MIQ") {
                    showAboutPanel()
                }
            }
        }
    }

    private func showAboutPanel() {
        guard let url = URL(string: "https://github.com/marcoduering/MIQ") else { return }

        let credits = NSMutableAttributedString(string: "Source code: MIQ on GitHub")
        let fullRange = NSRange(location: 0, length: credits.length)
        credits.addAttribute(.font, value: NSFont.systemFont(ofSize: NSFont.labelFontSize), range: fullRange)
        credits.addAttribute(.link, value: url, range: NSRange(location: 13, length: 13))

        var options: [NSApplication.AboutPanelOptionKey: Any] = [.credits: credits]
        if let icon = NSImage(named: "AppIcon") {
            options[.applicationIcon] = icon
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
    }
}
