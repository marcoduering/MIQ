import Combine
import Foundation
import Sparkle

/// Owns the app's Sparkle updater.
///
/// MIQApp is sandboxed, so it cannot replace `/Applications/MIQ.app` itself —
/// and neither can anything it spawns, since a child process inherits the
/// sandbox. Sparkle's Installer XPC service is the sanctioned way out: it is
/// launched by launchd, outside the app's sandbox, and reaped when idle. Three
/// pieces have to agree for that to work, so change them together:
///
///   1. `SUEnableInstallerLauncherService` in MIQApp/Info.plist,
///   2. the `-spks` / `-spki` `mach-lookup.global-name` temporary exceptions in
///      MIQApp/MIQ.entitlements,
///   3. `Sparkle.framework` embedded in the app bundle (SPM does this for the
///      MIQ target only — never the appexes).
///
/// `Downloader.xpc` ships inside the framework but is deliberately not enabled:
/// the app already holds `com.apple.security.network.client`, so Sparkle
/// downloads in-process.
@MainActor
final class UpdaterController: ObservableObject {
    /// Mirrors `SPUUpdater.canCheckForUpdates`, which goes false while a check
    /// is already in flight — the menu item and button key their enabled state
    /// off it rather than tracking progress themselves.
    @Published private(set) var canCheckForUpdates = false

    /// Written straight through to Sparkle, which persists it in the app's own
    /// `UserDefaults`. Deliberately *not* an `MIQConfig` setting: it steers the
    /// app's updater only, and nothing in the App Group suite — which exists so
    /// the sandboxed extensions can read the app's rendering settings — has any
    /// use for it.
    ///
    /// Defaults to on, via `SUEnableAutomaticChecks` in MIQApp/Info.plist —
    /// which also means Sparkle never shows its permission prompt, so this
    /// toggle in Settings is the only place the user grants or revokes it.
    ///
    /// Two-way: Sparkle owns the stored value and can change it without us, so
    /// it is mirrored back via KVO (in `init`) rather than snapshotted once —
    /// a one-time read left the Settings toggle stale until relaunch.
    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            // Skip the write-back when the value already matches (the KVO
            // mirror lands here too): Sparkle's setter resets its schedule
            // cycle every time it is assigned.
            guard controller.updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates else { return }
            controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    private let controller: SPUStandardUpdaterController

    init() {
        // startingUpdater: true starts the scheduled background checks now. On
        // first launch Sparkle asks the user once whether to allow them, so
        // this does not check the network behind their back.
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.controller = controller
        self.automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        // Both SPUUpdater properties are documented KVO-compliant.
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .assign(to: &$automaticallyChecksForUpdates)
    }

    /// Opens Sparkle's own update UI. Sparkle owns the whole flow from here —
    /// check, release notes, download, install, relaunch — so there is no
    /// result state for the caller to render.
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}
