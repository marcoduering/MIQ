import SwiftUI
import UniformTypeIdentifiers
import MIQCore


extension ViewOrientation {
    static let defaultValue = ViewOrientation(rawValue: MIQConfig.Defaults.imageOrientation)!

    var label: String {
        switch self {
        case .stored:        return "As stored (default)"
        case .neurological:  return "Neurological view"
        case .radiological:  return "Radiological view"
        }
    }
}

extension SegmentationColoring {
    static let defaultValue = SegmentationColoring(rawValue: MIQConfig.Defaults.segmentationColoring)!

    var label: String {
        switch self {
        case .off:    return "Off (default)"
        case .auto:   return "Auto (FreeSurfer or random)"
        case .random: return "Random colours"
        }
    }
}

// Persists a Color as a comma-separated sRGB string for @AppStorage.
struct StoredColor: RawRepresentable, Equatable {
    var color: Color

    init(_ color: Color) { self.color = color }

    init?(rawValue: String) {
        let parts = rawValue.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4 else { return nil }
        color = Color(red: parts[0], green: parts[1], blue: parts[2], opacity: parts[3])
    }

    var rawValue: String {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        NSColor(color).usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
        return "\(r),\(g),\(b),\(a)"
    }

    static let defaultValue = StoredColor(rawValue: MIQConfig.Defaults.axisLabelColor)!
}

// Persists an ordered list of metadata fields as a CSV of raw values.
// Unknown tokens are dropped and missing fields are appended in canonical order,
// so the result always covers every MetadataField case.
struct StoredMetadataOrder: RawRepresentable, Equatable {
    var fields: [MetadataField]

    init(_ fields: [MetadataField]) { self.fields = fields }

    init?(rawValue: String) {
        self.fields = MIQConfig.parseMetadataOrder(rawValue)
    }

    var rawValue: String {
        fields.map(\.rawValue).joined(separator: ",")
    }

    static let defaultValue = StoredMetadataOrder(rawValue: MIQConfig.Defaults.metadataOrder)!
}

private func metadataLabel(_ field: MetadataField) -> String {
    switch field {
    case .format:      return "Format"
    case .dimensions:  return "Dimensions"
    case .spacing:     return "Spacing"
    case .orientation: return "Orientation"
    case .datatype:    return "Datatype"
    case .volumes:     return "Volumes"
    case .scaling:     return "Scaling"
    case .value:       return "Voxel value"
    }
}

private func metadataHelpText(_ field: MetadataField) -> String? {
    switch field {
    case .scaling:
        return "Shows the intensity scaling from the file header as x slope +/- intercept. Hidden when the scaling is identity (x 1 + 0, meaning voxel values are used as stored) or unavailable."
    case .value:
        return "Shows the image intensity at the crosshair voxel, updating live as you move the crosshair. Appears only while interacting (when the crosshair is visible), not on the initial preview."
    default:
        return nil
    }
}


/// One interaction in the Usage pane: a title, an optional explanatory note,
/// and the mouse / trackpad gestures that trigger it.
private struct InteractionRow: View {
    let title: String
    var icon: String? = nil
    var note: String? = nil
    var mouse: String? = nil
    var trackpad: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 30)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body)
                if let note {
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if mouse != nil || trackpad != nil {
                    HStack(spacing: 18) {
                        if let mouse {
                            Label(mouse, systemImage: "computermouse")
                        }
                        if let trackpad {
                            Label(trackpad, systemImage: "rectangle.filled.and.hand.point.up.left")
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// A settings pane's header glyph: hierarchical, accent-tinted, static.
private struct SettingsHeaderIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.tint)
            .font(.system(size: 28))
            .frame(width: 32, height: 36)
    }
}

private enum SettingsTab: String, CaseIterable, Hashable {
    case about
    case usage
    case imageDisplay
    case metadataPanel
    case thumbnails

    var label: String {
        switch self {
        case .about:         return "About"
        case .usage:         return "Usage"
        case .imageDisplay:  return "Image Display"
        case .metadataPanel: return "Metadata Panel"
        case .thumbnails:    return "Thumbnails"
        }
    }

    var symbol: String {
        switch self {
        case .about:         return "info.circle"
        case .usage:         return "computermouse"
        case .imageDisplay:  return "photo"
        case .metadataPanel: return "list.bullet.rectangle"
        case .thumbnails:    return "photo.on.rectangle"
        }
    }

    var toolbarItemIdentifier: NSToolbarItem.Identifier {
        NSToolbarItem.Identifier("miq.settings.\(rawValue)")
    }

    static func tab(for identifier: NSToolbarItem.Identifier) -> SettingsTab? {
        SettingsTab.allCases.first { $0.toolbarItemIdentifier == identifier }
    }
}

private struct SettingsToolbarInstaller: NSViewRepresentable {
    @Binding var selection: SettingsTab

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> NSView {
        // A plain NSView added via .background() is not in a window yet at
        // makeNSView time, so the toolbar can only be installed once the view
        // joins the window hierarchy. Doing that synchronously in
        // viewDidMoveToWindow (rather than a deferred DispatchQueue hop) installs
        // the toolbar during the first layout pass, before the window displays —
        // otherwise it appears a tick late and shifts the settings content down.
        let view = InstallerView()
        view.onMoveToWindow = { [coordinator = context.coordinator] window in
            coordinator.install(into: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if context.coordinator.window == nil {
            context.coordinator.install(into: nsView.window)
        }
        context.coordinator.update(selection: selection)
    }

    private final class InstallerView: NSView {
        var onMoveToWindow: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // This view never accepts first responder, so pointing the window's
            // initial first responder at it suppresses AppKit's default of
            // auto-focusing the first key view (the GitHub link) on launch.
            window.initialFirstResponder = self
            onMoveToWindow?(window)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSToolbarDelegate {
        @Binding var selection: SettingsTab
        weak var window: NSWindow?
        private var keyObserver: NSObjectProtocol?

        init(selection: Binding<SettingsTab>) {
            self._selection = selection
        }

        func install(into window: NSWindow?) {
            guard let window else { return }
            self.window = window
            if window.toolbar?.identifier == NSToolbar.Identifier("MIQSettings") {
                window.toolbar?.selectedItemIdentifier = selection.toolbarItemIdentifier
                return
            }
            let toolbar = NSToolbar(identifier: NSToolbar.Identifier("MIQSettings"))
            toolbar.displayMode = .iconAndLabel
            toolbar.allowsUserCustomization = false
            toolbar.delegate = self
            window.toolbar = toolbar
            window.toolbarStyle = .preference
            toolbar.selectedItemIdentifier = selection.toolbarItemIdentifier
            applyInitialSelectionHighlight(in: window)
        }

        /// The macOS 26+ liquid-glass selection highlight only renders while the
        /// window is on screen; setting `selectedItemIdentifier` at install time
        /// (before first display) leaves the initial tab unhighlighted until the
        /// user switches tabs. Re-apply it once the window first becomes key —
        /// toggling through nil so AppKit treats it as a fresh selection and
        /// draws the glass. (User-driven tab switches already happen while the
        /// window is key, which is why they work.)
        private func applyInitialSelectionHighlight(in window: NSWindow) {
            if window.isKeyWindow {
                finalizeInitialWindowState()
                return
            }
            keyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let keyObserver = self.keyObserver {
                        NotificationCenter.default.removeObserver(keyObserver)
                        self.keyObserver = nil
                    }
                    self.finalizeInitialWindowState()
                }
            }
        }

        private func finalizeInitialWindowState() {
            reapplySelectionHighlight()
            // Leave nothing focused on launch, matching the state after switching
            // tabs back to About. SwiftUI's hosting view re-asserts focus on the
            // first control (the GitHub link) as the window comes up, so clearing
            // synchronously here is overridden — defer one tick so the clear runs
            // after SwiftUI has settled.
            DispatchQueue.main.async { [weak self] in
                self?.window?.makeFirstResponder(nil)
            }
        }

        private func reapplySelectionHighlight() {
            guard let toolbar = window?.toolbar else { return }
            toolbar.selectedItemIdentifier = nil
            toolbar.selectedItemIdentifier = selection.toolbarItemIdentifier
        }

        func update(selection: SettingsTab) {
            guard let toolbar = window?.toolbar,
                  toolbar.selectedItemIdentifier != selection.toolbarItemIdentifier
            else { return }
            toolbar.selectedItemIdentifier = selection.toolbarItemIdentifier
        }

        func toolbar(_ _: NSToolbar,
                     itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                     willBeInsertedIntoToolbar _: Bool) -> NSToolbarItem? {
            guard let tab = SettingsTab.tab(for: itemIdentifier) else { return nil }
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = tab.label
            item.paletteLabel = tab.label
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.label)
            item.target = self
            item.action = #selector(itemTapped(_:))
            return item
        }

        func toolbarDefaultItemIdentifiers(_ _: NSToolbar) -> [NSToolbarItem.Identifier] {
            SettingsTab.allCases.map(\.toolbarItemIdentifier)
        }

        func toolbarAllowedItemIdentifiers(_ _: NSToolbar) -> [NSToolbarItem.Identifier] {
            SettingsTab.allCases.map(\.toolbarItemIdentifier)
        }

        func toolbarSelectableItemIdentifiers(_ _: NSToolbar) -> [NSToolbarItem.Identifier] {
            SettingsTab.allCases.map(\.toolbarItemIdentifier)
        }

        @objc private func itemTapped(_ sender: NSToolbarItem) {
            if let tab = SettingsTab.tab(for: sender.itemIdentifier) {
                selection = tab
            }
        }
    }
}

struct ContentView: View {
    private static let store = UserDefaults(suiteName: MIQConfig.appGroupID)

    @AppStorage(MIQConfig.Keys.imageOrientation, store: Self.store)
    private var imageOrientation: ViewOrientation = ViewOrientation.defaultValue
    @AppStorage(MIQConfig.Keys.segmentationColoring, store: Self.store)
    private var segmentationColoring: SegmentationColoring = SegmentationColoring.defaultValue
    @AppStorage(MIQConfig.Keys.windowLowerPercentile, store: Self.store)
    private var lowerPercentile: Double = MIQConfig.Defaults.windowLowerPercentile
    @AppStorage(MIQConfig.Keys.windowUpperPercentile, store: Self.store)
    private var upperPercentile: Double = MIQConfig.Defaults.windowUpperPercentile
    @AppStorage(MIQConfig.Keys.perVolumeIntensityWindow, store: Self.store)
    private var perVolumeIntensityWindow: Bool = MIQConfig.Defaults.perVolumeIntensityWindow
    @AppStorage(MIQConfig.Keys.showAxisLabels, store: Self.store)
    private var showAxisLabels: Bool = MIQConfig.Defaults.showAxisLabels
    @AppStorage(MIQConfig.Keys.axisLabelColor, store: Self.store)
    private var axisLabelColor: StoredColor = StoredColor.defaultValue
    @AppStorage(MIQConfig.Keys.showMetadataFormat, store: Self.store)
    private var showMetadataFormat: Bool = MIQConfig.Defaults.showMetadataFormat
    @AppStorage(MIQConfig.Keys.showMetadataDimensions, store: Self.store)
    private var showMetadataDimensions: Bool = MIQConfig.Defaults.showMetadataDimensions
    @AppStorage(MIQConfig.Keys.showMetadataSpacing, store: Self.store)
    private var showMetadataSpacing: Bool = MIQConfig.Defaults.showMetadataSpacing
    @AppStorage(MIQConfig.Keys.showMetadataOrientation, store: Self.store)
    private var showMetadataOrientation: Bool = MIQConfig.Defaults.showMetadataOrientation
    @AppStorage(MIQConfig.Keys.showMetadataDatatype, store: Self.store)
    private var showMetadataDatatype: Bool = MIQConfig.Defaults.showMetadataDatatype
    @AppStorage(MIQConfig.Keys.showMetadataVolumes, store: Self.store)
    private var showMetadataVolumes: Bool = MIQConfig.Defaults.showMetadataVolumes
    @AppStorage(MIQConfig.Keys.showMetadataScaling, store: Self.store)
    private var showMetadataScaling: Bool = MIQConfig.Defaults.showMetadataScaling
    @AppStorage(MIQConfig.Keys.showMetadataValue, store: Self.store)
    private var showMetadataValue: Bool = MIQConfig.Defaults.showMetadataValue
    @AppStorage(MIQConfig.Keys.metadataOrder, store: Self.store)
    private var metadataOrder: StoredMetadataOrder = StoredMetadataOrder.defaultValue
    @AppStorage(MIQConfig.Keys.deferLargeNetworkPreviews, store: Self.store)
    private var deferLargeNetworkPreviews: Bool = MIQConfig.Defaults.deferLargeNetworkPreviews
    @AppStorage(MIQConfig.Keys.hideDisclaimerInPreview, store: Self.store)
    private var hideDisclaimerInPreview: Bool = MIQConfig.Defaults.hideDisclaimerInPreview
    @AppStorage(MIQConfig.Keys.showThumbnails, store: Self.store)
    private var showThumbnails: Bool = MIQConfig.Defaults.showThumbnails
    @AppStorage(MIQConfig.Keys.showThumbnailsOnNetworkVolumes, store: Self.store)
    private var showThumbnailsOnNetworkVolumes: Bool = MIQConfig.Defaults.showThumbnailsOnNetworkVolumes
    @AppStorage(MIQConfig.Keys.thumbnailImageOrientation, store: Self.store)
    private var thumbnailImageOrientation: ViewOrientation = ViewOrientation.defaultValue
    @AppStorage(MIQConfig.Keys.thumbnailWindowLowerPercentile, store: Self.store)
    private var thumbnailLowerPercentile: Double = MIQConfig.Defaults.thumbnailWindowLowerPercentile
    @AppStorage(MIQConfig.Keys.thumbnailWindowUpperPercentile, store: Self.store)
    private var thumbnailUpperPercentile: Double = MIQConfig.Defaults.thumbnailWindowUpperPercentile

    @State private var showHideDisclaimerConfirm = false
    @State private var draggedMetadataField: MetadataField?
    @State private var presentedMetadataInfoField: MetadataField?
    @State private var selectedTab: SettingsTab = .about
    @State private var updateState: UpdateState = .idle
    @State private var showUpdateAlert: Bool = false
    @State private var showThumbnailRefreshInfo = false
    @State private var didCopyRefreshCommand = false
    #if DEBUG
    // Mirrors the @AppStorage in MIQApp so the About pane updates when the
    // Debug menu's "Simulate update available" toggle flips. Same key, no
    // `store:`, shared via UserDefaults.standard.
    @AppStorage(DebugFlags.simulateUpdateAvailableKey) private var simulateUpdateAvailable = false
    #endif

    private enum UpdateState: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateCheckResult)
        case error(String)

        var availableResult: UpdateCheckResult? {
            if case .available(let r) = self { return r }
            return nil
        }
    }

    private static let homebrewCommand = "brew update --cask miq"

    private static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
    }

    #if DEBUG
    private static let simulatedUpdateResult = UpdateCheckResult(
        tagName: "v999.0.0",
        version: "999.0.0",
        releaseURL: URL(string: "https://github.com/marcoduering/MIQ/releases/tag/v999.0.0")!
    )
    #endif

    private static let disclaimerText = """
        MIQ is **not a medical device** and is **not intended for diagnostic use**. It is a developer and researcher convenience tool only; do not use it for clinical decisions.

        MIQ is provided "as is" under the MIT License, without warranty. The authors and contributors accept no liability for any damages arising from its use or inability to use it, including data loss, incorrect image rendering, or decisions based on its previews.
        """

    var body: some View {
        Group {
            switch selectedTab {
            case .about:         aboutSettingsView
            case .usage:         usageSettingsView
            case .imageDisplay:  imageDisplaySettingsView
            case .metadataPanel: metadataPanelSettingsView
            case .thumbnails:    thumbnailSettingsView
            }
        }
        .background(SettingsToolbarInstaller(selection: $selectedTab))
        .alert("Hide disclaimer in preview?", isPresented: $showHideDisclaimerConfirm) {
            Button("Cancel", role: .cancel) {
                hideDisclaimerInPreview = false
            }
            Button("I understand, hide it") {
                hideDisclaimerInPreview = true
            }
        } message: {
            Text(Self.disclaimerText + "\n\nBy hiding the disclaimer in previews, you confirm that you understand and accept these terms.")
        }
        .alert("Update available", isPresented: $showUpdateAlert, presenting: updateState.availableResult) { result in
            Button("Download latest version") {
                NSWorkspace.shared.open(UpdateChecker.latestAppDownloadURL)
            }
            .keyboardShortcut(.defaultAction)
            Button("Open Changelog on GitHub") {
                NSWorkspace.shared.open(result.releaseURL)
            }
            Button("Cancel", role: .cancel) { /* sheet dismissed by .cancel role */ }
        } message: { result in
            Text("MIQ \(result.version) is available.\nYou are running \(Self.currentVersion).\n\nDownload the latest release from GitHub.\n\nOr if you installed via Homebrew, run in Terminal:\n\(Self.homebrewCommand)")
        }
        .frame(minWidth: 550, idealWidth: 550, maxWidth: 550, minHeight: 587, idealHeight: 587, maxHeight: 587)
        .onAppear {
            // No element is focused on launch (matching the state after switching
            // tabs back to About). AppKit would otherwise auto-focus the first
            // key view (the GitHub link); SettingsToolbarInstaller suppresses that
            // and clears the first responder once the window is up.
            #if DEBUG
            if simulateUpdateAvailable {
                updateState = .available(Self.simulatedUpdateResult)
                return
            }
            #endif
            primeUpdateStateFromCache()
            Task { await runUpdateCheck(force: false) }
        }
        #if DEBUG
        .onChange(of: simulateUpdateAvailable) { _, newValue in
            if newValue {
                updateState = .available(Self.simulatedUpdateResult)
            } else {
                Task { await runUpdateCheck(force: true) }
            }
        }
        #endif
        #if DEBUG
        .safeAreaInset(edge: .bottom, spacing: 0) {
            let appDate = BuildDate.formatted(for: Bundle.main.executableURL) ?? "unknown"
            let extExec = Bundle.main.builtInPlugInsURL?
                .appendingPathComponent("MIQQuickLookExtension.appex/Contents/MacOS/MIQQuickLookExtension")
            let extDate = BuildDate.formatted(for: extExec) ?? "unknown"
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Text("App built: \(appDate)")
                    Spacer()
                    Text("Extension built: \(extDate)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
            .background(.bar)
        }
        #endif
    }

    private var aboutSettingsView: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 60, height: 60)
                    Text("MIQ: Medical Image Quick Look")
                        .font(.title2.weight(.semibold))
                    Link("github.com/marcoduering/MIQ",
                         destination: URL(string: "https://github.com/marcoduering/MIQ")!)
                        .font(.callout)
                    HStack(spacing: 8) {
                        Text("Version \(Self.currentVersion)")
                            .foregroundStyle(.secondary)
                        updateBadge
                    }
                    .font(.callout)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
            }

            Section {
                Text("Changes apply the next time a preview is rendered. Reopen a preview to re-render.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("General") {
                HStack {
                    Text("Restore default settings")
                    Spacer()
                    Button("Reset") {
                        restoreDefaults()
                    }
                }
            }

            Section("Disclaimer") {
                Text(.init(Self.disclaimerText))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Hide disclaimer in preview", isOn: Binding(
                    get: { hideDisclaimerInPreview },
                    set: { newValue in
                        if newValue {
                            showHideDisclaimerConfirm = true
                        } else {
                            hideDisclaimerInPreview = false
                        }
                    }
                ))
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private var usageSettingsView: some View {
        Form {
            
            Section {
                HStack(spacing: 12) {
                    SettingsHeaderIcon(systemName: "pointer.arrow.rays")
                    Text("The preview is **fully interactive**. See below for an overview of the available controls.")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Orthogonal 3D view") {
                InteractionRow(
                    title: "Move the crosshair",
                    icon: "dot.scope",
                    mouse: "Click or drag",
                    trackpad: "Click, tap or one-finger drag"
                )
                InteractionRow(
                    title: "Scroll through slices",
                    icon: "square.stack",
                    mouse: "Scroll wheel",
                    trackpad: "Two-finger scroll"
                )
                InteractionRow(
                    title: "Window / level",
                    icon: "circle.lefthalf.filled",
                    note: "Vertical = level (brightness), horizontal = window (contrast).",
                    mouse: "Secondary-click + drag",
                    trackpad: "Secondary-click + drag"
                )
            }

            Section("4D series (multi-volume)") {
                InteractionRow(
                    title: "Change volume",
                    icon: "square.stack.3d.down.forward",
                    note: "For 4D image series, a slider appears next to Volume in the metadata panel. Drag the slider or click anywhere on it to change volumes.\nOr use ⌥ **Option-scroll**:",
                    mouse: "⌥ Option key + scroll wheel",
                    trackpad: "⌥ Option key + two-finger scroll"
                )
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private var imageDisplaySettingsView: some View {
        Form {
            
            Section {
                HStack(spacing: 12) {
                    SettingsHeaderIcon(systemName: "gear.badge.checkmark")
                    Text("Tailor the image display to your preferences.")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Orientation", selection: $imageOrientation) {
                        ForEach(ViewOrientation.allCases, id: \.rawValue) { orientation in
                            Text(orientation.label).tag(orientation)
                        }
                    }
                    Text("By default, images are rendered as stored. For a standardized view, use neurological (patient right on right) or radiological (patient right on left).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Picker(selection: $segmentationColoring) {
                        ForEach(SegmentationColoring.allCases, id: \.rawValue) { mode in
                            Text(mode.label).tag(mode)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text("Segmentation colouring")
                            Text("NEW in v1.1.0")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(.tint))
                        }
                    }
                    Text("When a label file is detected, render in colour. Auto uses canonical FreeSurfer colours when a FreeSurfer parcellation is detected, otherwise assigns random colours.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Upper intensity clip")
                        Spacer()
                        Text("\(Int(upperPercentile))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Stepper("", value: $upperPercentile, in: 51...100, step: 1)
                            .labelsHidden()
                    }
                    
                    HStack {
                        Text("Lower intensity clip")
                        Spacer()
                        Text("\(Int(lowerPercentile))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Stepper("", value: $lowerPercentile, in: 0...49, step: 1)
                            .labelsHidden()
                    }

                    Text("Initial intensity range, percentile thresholds for non-zero voxels (default: 2% - 98%).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Per-volume intensity window for multi-volume (4D) data")
                        Spacer()
                        Toggle("", isOn: $perVolumeIntensityWindow)
                            .labelsHidden()
                    }

                    Text("Off (default): the window is computed once from the first volume and kept constant. On: The window is re-calculated for each volume.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Text("Overlay color (axis labels, interactive mode crosshair)")
                    Spacer()
                    ColorPicker("", selection: Binding(
                        get: { axisLabelColor.color },
                        set: { axisLabelColor = StoredColor($0) }
                    ))
                    .labelsHidden()
                }

                HStack {
                    Text("Display axis labels")
                    Spacer()
                    Toggle("", isOn: $showAxisLabels)
                        .labelsHidden()
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        HStack(spacing: 6) {
                            Text("Defer large previews on network volumes")
                            Text("NEW in v1.2.0")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(.tint))
                        }
                        Spacer()
                        Toggle("", isOn: $deferLargeNetworkPreviews)
                            .labelsHidden()
                    }

                    Text("On by default: for files larger than \(Int(MIQConfig.Defaults.networkPreviewThresholdMB)) MB the user needs to actively confirm loading. 4D NIfTI is unaffected, it only reads the first volume.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private var metadataPanelSettingsView: some View {
        Form {
            
            Section {
                HStack(spacing: 12) {
                    SettingsHeaderIcon(systemName: "checklist")
                    Text("Choose which fields appear in the metadata panel. Drag and drop to rearrange the order.")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            
            Section {
                let fields = metadataOrder.fields
                ForEach(fields, id: \.self) { field in
                    HStack {
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.secondary)
                            .padding(.trailing, 4)
                        Text(metadataLabel(field))
                        if let helpText = metadataHelpText(field) {
                            Button {
                                presentedMetadataInfoField = presentedMetadataInfoField == field ? nil : field
                            } label: {
                                Image(systemName: presentedMetadataInfoField == field ? "info.circle.fill" : "info.circle")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .popover(isPresented: metadataInfoPopoverBinding(for: field), arrowEdge: .top) {
                                Text(helpText)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(width: 260, alignment: .leading)
                                    .padding(12)
                            }
                        }
                        Spacer()
                        Toggle("", isOn: visibilityBinding(for: field))
                            .labelsHidden()
                    }
                    .contentShape(Rectangle())
                    .opacity(draggedMetadataField == field ? 0.4 : 1.0)
                    .onDrag {
                        draggedMetadataField = field
                        return NSItemProvider(object: field.rawValue as NSString)
                    }
                    .onDrop(of: [UTType.text], delegate: MetadataReorderDropDelegate(
                        destination: field,
                        order: $metadataOrder,
                        draggedField: $draggedMetadataField
                    ))
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private var thumbnailSettingsView: some View {
        Form {

            Section {
                HStack(spacing: 12) {
                    SettingsHeaderIcon(systemName: "photo.on.rectangle")
                    Text("Show an image slice as the file thumbnail in Finder\n(optional feature, off by default).")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Show thumbnails in Finder")
                        Spacer()
                        Toggle("", isOn: $showThumbnails)
                            .labelsHidden()
                    }

                    Text("New thumbnails appear automatically; existing ones refresh when the file changes or when forcing a refresh via Terminal.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Button {
                            copyThumbnailRefreshCommand()
                        } label: {
                            Label(didCopyRefreshCommand ? "Copied" : "Copy refresh command",
                                  systemImage: didCopyRefreshCommand ? "checkmark" : "doc.on.doc")
                        }

                        Button {
                            showThumbnailRefreshInfo.toggle()
                        } label: {
                            Image(systemName: showThumbnailRefreshInfo ? "info.circle.fill" : "info.circle")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showThumbnailRefreshInfo, arrowEdge: .top) {
                            Text("Paste into Terminal to refresh already-cached thumbnails.\n\nIf they still look stale, also run:\nrm -rf \"$(getconf DARWIN_USER_CACHE_DIR)com.apple.iconservices.store\" && killall Dock Finder\n\nTo stop generating thumbnails, disable the extension in System Settings › General › Login Items & Extensions.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(width: 300, alignment: .leading)
                                .padding(12)
                        }
                    }
                    .padding(.top, 2)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        HStack(spacing: 6) {
                            Text("Include network volumes")
                            Text("NEW in v1.2.0")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(.tint))
                        }
                        Spacer()
                        Toggle("", isOn: $showThumbnailsOnNetworkVolumes)
                            .labelsHidden()
                    }
                    Text("Off by default: thumbnailing files on a network share reads each one while browsing, which can be slow on a remote mount.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .disabled(!showThumbnails)
            }

            Section("Thumbnail display options") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Orientation", selection: $thumbnailImageOrientation) {
                        ForEach(ViewOrientation.allCases, id: \.rawValue) { orientation in
                            Text(orientation.label).tag(orientation)
                        }
                    }
                    Text("Same options as Image Display, applied independently to thumbnails.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Upper intensity clip")
                        Spacer()
                        Text("\(Int(thumbnailUpperPercentile))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Stepper("", value: $thumbnailUpperPercentile, in: 51...100, step: 1)
                            .labelsHidden()
                    }

                    HStack {
                        Text("Lower intensity clip")
                        Spacer()
                        Text("\(Int(thumbnailLowerPercentile))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Stepper("", value: $thumbnailLowerPercentile, in: 0...49, step: 1)
                            .labelsHidden()
                    }

                    Text("Grayscale intensity range, as percentiles of non-zero voxels (default 2–98%).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(!showThumbnails)
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    /// Terminal command that drops Quick Look's thumbnail cache and restarts the
    /// agents so already-cached thumbnails regenerate with the current settings.
    private static let thumbnailRefreshCommand =
        "qlmanage -r cache && killall com.apple.quicklook.ThumbnailsAgent Finder"

    private func copyThumbnailRefreshCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.thumbnailRefreshCommand, forType: .string)
        didCopyRefreshCommand = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            didCopyRefreshCommand = false
        }
    }

    private func visibilityBinding(for field: MetadataField) -> Binding<Bool> {
        switch field {
        case .format:      return $showMetadataFormat
        case .dimensions:  return $showMetadataDimensions
        case .spacing:     return $showMetadataSpacing
        case .orientation: return $showMetadataOrientation
        case .datatype:    return $showMetadataDatatype
        case .volumes:     return $showMetadataVolumes
        case .scaling:     return $showMetadataScaling
        case .value:       return $showMetadataValue
        }
    }

    private func metadataInfoPopoverBinding(for field: MetadataField) -> Binding<Bool> {
        Binding(
            get: { presentedMetadataInfoField == field },
            set: { isPresented in
                presentedMetadataInfoField = isPresented ? field : nil
            }
        )
    }

    @ViewBuilder
    private var updateBadge: some View {
        switch updateState {
        case .idle:
            Button("Check for Updates") {
                Task { await runUpdateCheck(force: true) }
            }
            .buttonStyle(.link)
            .font(.callout)

        case .checking:
            HStack(spacing: 6) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                Text("Checking for updates…")
            }
            .font(.callout)

        case .upToDate:
            Button {
                Task { await runUpdateCheck(force: true) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle")
                    Text("You're up to date")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

        case .available:
            Button {
                showUpdateAlert = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle.fill")
                    Text("Update available")
                }
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)

        case .error(let message):
            HStack(spacing: 6) {
                Text(message)
                    .foregroundStyle(.red)
                Button("Try again") {
                    Task { await runUpdateCheck(force: true) }
                }
                .buttonStyle(.link)
            }
            .font(.callout)
        }
    }

    private func primeUpdateStateFromCache() {
        if case .available = updateState { return }
        if case .checking = updateState { return }
        if let cached = MIQConfig.lastKnownLatestVersion,
           UpdateChecker.isNewer(latest: cached, than: Self.currentVersion) {
            updateState = .available(UpdateCheckResult(
                tagName: "v" + cached,
                version: cached,
                releaseURL: UpdateChecker.latestReleasePageURL
            ))
        }
    }

    private func runUpdateCheck(force: Bool) async {
        if case .checking = updateState { return }
        updateState = .checking
        let started = Date()

        let nextState: UpdateState
        do {
            let result = try await UpdateChecker.fetchLatestRelease()
            MIQConfig.lastKnownLatestVersion = result.version
            if UpdateChecker.isNewer(latest: result.version, than: Self.currentVersion) {
                nextState = .available(result)
            } else {
                nextState = .upToDate
            }
        } catch {
            let description = (error as? LocalizedError)?.errorDescription ?? "Couldn't check for updates."
            if force {
                nextState = .error(description)
            } else {
                // Silent failure for the on-launch check: revert to idle so the
                // user can retry manually.
                nextState = .idle
            }
        }

        // Keep the spinner visible long enough that a manual click feels
        // acknowledged — otherwise a sub-300ms request flashes through and the
        // user thinks the button is dead and clicks again.
        if force {
            let minimumDisplay: TimeInterval = 1.5
            let elapsed = Date().timeIntervalSince(started)
            if elapsed < minimumDisplay {
                try? await Task.sleep(nanoseconds: UInt64((minimumDisplay - elapsed) * 1_000_000_000))
            }
        }

        updateState = nextState
    }

    private func restoreDefaults() {
        imageOrientation  = ViewOrientation.defaultValue
        segmentationColoring = SegmentationColoring.defaultValue
        lowerPercentile   = MIQConfig.Defaults.windowLowerPercentile
        upperPercentile   = MIQConfig.Defaults.windowUpperPercentile
        perVolumeIntensityWindow = MIQConfig.Defaults.perVolumeIntensityWindow
        showAxisLabels    = MIQConfig.Defaults.showAxisLabels
        axisLabelColor    = StoredColor.defaultValue
        showMetadataFormat      = MIQConfig.Defaults.showMetadataFormat
        showMetadataDimensions  = MIQConfig.Defaults.showMetadataDimensions
        showMetadataSpacing     = MIQConfig.Defaults.showMetadataSpacing
        showMetadataOrientation = MIQConfig.Defaults.showMetadataOrientation
        showMetadataDatatype    = MIQConfig.Defaults.showMetadataDatatype
        showMetadataVolumes     = MIQConfig.Defaults.showMetadataVolumes
        showMetadataScaling     = MIQConfig.Defaults.showMetadataScaling
        metadataOrder           = StoredMetadataOrder.defaultValue
        hideDisclaimerInPreview = MIQConfig.Defaults.hideDisclaimerInPreview
        deferLargeNetworkPreviews = MIQConfig.Defaults.deferLargeNetworkPreviews
        showThumbnails            = MIQConfig.Defaults.showThumbnails
        showThumbnailsOnNetworkVolumes = MIQConfig.Defaults.showThumbnailsOnNetworkVolumes
        thumbnailImageOrientation = ViewOrientation.defaultValue
        thumbnailLowerPercentile  = MIQConfig.Defaults.thumbnailWindowLowerPercentile
        thumbnailUpperPercentile  = MIQConfig.Defaults.thumbnailWindowUpperPercentile
    }
}

private struct MetadataReorderDropDelegate: DropDelegate {
    let destination: MetadataField
    @Binding var order: StoredMetadataOrder
    @Binding var draggedField: MetadataField?

    func dropEntered(info _: DropInfo) {
        guard let dragged = draggedField, dragged != destination else { return }
        var fields = order.fields
        guard let from = fields.firstIndex(of: dragged),
              let to = fields.firstIndex(of: destination) else { return }
        fields.move(fromOffsets: IndexSet(integer: from),
                    toOffset: to > from ? to + 1 : to)
        order = StoredMetadataOrder(fields)
    }

    func dropUpdated(info _: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info _: DropInfo) -> Bool {
        draggedField = nil
        return true
    }

    func dropExited(info _: DropInfo) { /* no cleanup needed on drag exit */ }
}

#Preview {
    ContentView()
}
