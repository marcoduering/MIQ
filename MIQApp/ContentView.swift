import SwiftUI
import UniformTypeIdentifiers
import MIQCore


extension ViewOrientation {
    static let defaultValue = ViewOrientation(rawValue: MIQConfig.Defaults.imageOrientation)!
    static let thumbnailDefaultValue = ViewOrientation(rawValue: MIQConfig.Defaults.thumbnailImageOrientation)!

    var label: String {
        switch self {
        case .stored:        return "As Stored"
        case .neurological:  return "Neurological"
        case .radiological:  return "Radiological"
        }
    }
}

extension SegmentationColoring {
    static let defaultValue = SegmentationColoring(rawValue: MIQConfig.Defaults.segmentationColoring)!
    static let thumbnailDefaultValue = SegmentationColoring(rawValue: MIQConfig.Defaults.thumbnailSegmentationColoring)!

    var label: String {
        switch self {
        case .off:    return "Off"
        case .auto:   return "Auto"
        case .random: return "Random"
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

    /// `Color` equality doesn't survive the sRGB string round trip, so
    /// "is this still the default?" compares components with a tolerance.
    func isApproximately(_ other: StoredColor) -> Bool {
        let a = rawValue.split(separator: ",").compactMap { Double($0) }
        let b = other.rawValue.split(separator: ",").compactMap { Double($0) }
        return a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 0.002 }
    }
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
        return "Shows the intensity scaling from the file header as x slope +/- intercept, or just x slope when the intercept is zero. Hidden when the scaling is identity (x 1 + 0, meaning voxel values are used as stored) or unavailable."
    case .value:
        return "Shows the image intensity at the crosshair voxel, updating live as you move the crosshair. Appears only while interacting (when the crosshair is visible), not on the initial preview."
    default:
        return nil
    }
}



/// An (i) button that shows a short explanation in a popover. Explanations
/// live here rather than in captions under each row, so rows stay one line and
/// nothing shifts when a selection changes.
private struct InfoButton: View {
    let text: String
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: isPresented ? "info.circle.fill" : "info.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More information")
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 280, alignment: .leading)
                .padding(12)
        }
    }
}

/// A row title with an optional info button beside it.
private struct RowTitle: View {
    let title: String
    var info: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            if let info { InfoButton(text: info) }
        }
    }
}

/// The input device the Controls pane describes. Only one device's gestures
/// are shown at a time, halving what the pane has to say.
private enum InputDevice: String, CaseIterable, Hashable {
    case mouse
    case trackpad

    var label: String {
        switch self {
        case .trackpad: return "Trackpad"
        case .mouse:    return "Mouse"
        }
    }
}

/// One interaction on the Controls pane, as a card: what it does and how to
/// trigger it with the selected input device.
private struct GestureCard: View {
    let title: String
    let systemImage: String
    let gesture: String
    var modifierKey: String? = nil
    var note: String? = nil

    var body: some View {
        // A system GroupBox, so the card background is the OS's own and
        // follows each macOS version's styling — no colour of ours to tune.
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                    .frame(height: 34, alignment: .leading)
                Text(title)
                    .fontWeight(.semibold)
                HStack(spacing: 5) {
                    if let modifierKey {
                        Text(modifierKey)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.background, in: RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
                        Text("+").foregroundStyle(.secondary)
                    }
                    Text(gesture)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                .font(.callout)
                if let note {
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .accessibilityElement(children: .combine)
    }
}

private enum SettingsTab: String, CaseIterable, Hashable {
    case general
    case preview
    case metadata
    case thumbnails
    case controls

    var label: String {
        switch self {
        case .general:    return "General"
        case .preview:    return "Preview"
        case .metadata:   return "Metadata"
        case .thumbnails: return "Thumbnails"
        case .controls:   return "Controls"
        }
    }

    var symbol: String {
        switch self {
        case .general:    return "gearshape"
        case .preview:    return "eye"
        case .metadata:   return "list.bullet.rectangle"
        case .thumbnails: return "photo.on.rectangle"
        case .controls:   return "computermouse"
        }
    }

    /// Panes that show a live preview beside their settings.
    var hasSideColumn: Bool {
        switch self {
        case .preview, .metadata, .thumbnails: return true
        case .general, .controls:              return false
        }
    }

    var toolbarItemIdentifier: NSToolbarItem.Identifier {
        NSToolbarItem.Identifier("miq.settings.\(rawValue)")
    }

    static func tab(for identifier: NSToolbarItem.Identifier) -> SettingsTab? {
        SettingsTab.allCases.first { $0.toolbarItemIdentifier == identifier }
    }
}

private extension View {
    /// macOS 26+ draws a `.preference` toolbar's background from the content's
    /// scroll edge effect. `.scrollDisabled(true)` leaves `.automatic` with no
    /// edge to draw, so the bar fills only while hovered; `.hard` pins it.
    @ViewBuilder
    func pinnedTopScrollEdge() -> some View {
        if #available(macOS 26.0, *) {
            self.scrollEdgeEffectStyle(.hard, for: .top)
        } else {
            self
        }
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
        let coordinator = context.coordinator
        view.onMoveToWindow = { [coordinator] window in
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

    /// One fixed size for every pane: panes don't resize the window, and none
    /// of them scrolls — a pane that outgrows this gets trimmed, not a scroller.
    private static let windowSize = CGSize(width: 640, height: 520)
    private static let sideColumnWidth: CGFloat = 180
    /// Header for the first section of each Form pane: on panes with a side
    /// column it drops that group level with the column's box (tuned by eye),
    /// and General uses the same top space for consistency.
    private static var sideColumnAlignmentSpacer: some View { Color.clear.frame(height: 10) }

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
    private var thumbnailImageOrientation: ViewOrientation = ViewOrientation.thumbnailDefaultValue
    @AppStorage(MIQConfig.Keys.thumbnailSegmentationColoring, store: Self.store)
    private var thumbnailSegmentationColoring: SegmentationColoring = SegmentationColoring.thumbnailDefaultValue
    @AppStorage(MIQConfig.Keys.thumbnailWindowLowerPercentile, store: Self.store)
    private var thumbnailLowerPercentile: Double = MIQConfig.Defaults.thumbnailWindowLowerPercentile
    @AppStorage(MIQConfig.Keys.thumbnailWindowUpperPercentile, store: Self.store)
    private var thumbnailUpperPercentile: Double = MIQConfig.Defaults.thumbnailWindowUpperPercentile

    @State private var showHideDisclaimerConfirm = false
    @State private var showResetAllConfirm = false
    @State private var showFullDisclaimer = false
    @State private var draggedMetadataField: MetadataField?
    @State private var selectedTab: SettingsTab = .general
    @State private var didCopyRefreshCommand = false
    @State private var inputDevice: InputDevice = .mouse
    @State private var sampleMetadata: SampleRenderer.SampleMetadata?
    /// Supplied by `MIQApp`. Sparkle owns the check → download → install →
    /// relaunch flow; this view only offers the entry points.
    @EnvironmentObject private var updater: UpdaterController

    private static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
    }

    private static let disclaimerText = """
        MIQ is **not a medical device** and is **not intended for diagnostic use**. It is a developer and researcher convenience tool only; do not use it for clinical decisions.

        MIQ is provided "as is" under the MIT License, without warranty. The authors and contributors accept no liability for any damages arising from its use or inability to use it, including data loss, incorrect image rendering, or decisions based on its previews.
        """

    var body: some View {
        VStack(spacing: 0) {
            // One Form for all panes — a Form per pane rebuilt the backing
            // NSScrollView on every tab switch, blinking the titlebar
            // background. It always spans the full width: macOS 26 draws the
            // toolbar background from this scroll view, so a narrower Form
            // left the bar half-drawn. The side column and the Controls cards
            // are drawn over it instead, the side column into a reserved margin.
            Form {
                switch selectedTab {
                case .general:    generalPane
                case .preview:    previewPane
                case .metadata:   metadataPane
                case .thumbnails: thumbnailsPane
                case .controls:   EmptyView()
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .contentMargins(.trailing, selectedTab.hasSideColumn ? Self.sideColumnWidth + 20 : 0, for: .scrollContent)
            .pinnedTopScrollEdge()
            .overlay(alignment: .topTrailing) { sideColumn }
            .overlay(alignment: .topLeading) {
                if selectedTab == .controls { controlsPane }
            }
            footer
        }
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
        .navigationTitle(selectedTab.label)
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
        .alert("Reset all settings?", isPresented: $showResetAllConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                restoreDefaults()
            }
        } message: {
            Text("Every setting returns to its default, including automatic update checks.")
        }
        .task {
            sampleMetadata = await SampleRenderer.metadata(.intensity)
        }
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

    // MARK: - Layout

    /// The live preview beside the settings, on the panes that have one.
    @ViewBuilder
    private var sideColumn: some View {
        switch selectedTab {
        case .preview:
            sideColumn(title: "Example") {
                VStack(spacing: 6) {
                    SampleSliceView(sample: .intensity, options: previewOptions,
                                    overlayColor: axisLabelColor.color,
                                    showsLabels: showAxisLabels, showsCrosshair: true)
                    sampleCaption(.intensity)
                    SampleSliceView(sample: .labels, options: previewOptions,
                                    overlayColor: axisLabelColor.color,
                                    showsLabels: showAxisLabels, showsCrosshair: false)
                        .padding(.top, 6)
                    sampleCaption(.labels)
                }
                // Full column width, like the other panes' previews, so the
                // column doesn't change width when switching tabs.
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(.black, in: RoundedRectangle(cornerRadius: 10))
            }
        case .metadata:
            sideColumn(title: "Example") { metadataPanelPreview }
        case .thumbnails:
            sideColumn(title: "Example") {
                VStack(spacing: 14) {
                    SampleFinderIcon(sample: .intensity, options: thumbnailOptions, showsThumbnail: showThumbnails)
                    SampleFinderIcon(sample: .labels, options: thumbnailOptions, showsThumbnail: showThumbnails)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(.background, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5))
            }
        case .general, .controls:
            EmptyView()
        }
    }

    private func sideColumn<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            content()
        }
        .frame(width: Self.sideColumnWidth)
        .padding(.top, 20)
        .padding(.trailing, 20)
    }

    private func sampleCaption(_ sample: SettingsSample) -> some View {
        Text(sample.displayName)
            .font(.caption)
            .foregroundStyle(Color(white: 0.78))
    }

    /// Each pane's reset sits in the same corner, so it never moves when
    /// switching tabs. It names what it resets and is disabled while that pane
    /// is already at its defaults.
    private var footer: some View {
        HStack {
            Spacer()
            switch selectedTab {
            case .general:
                Button("Reset All Settings…") { showResetAllConfirm = true }
            case .preview:
                Button("Restore Preview Defaults") { restorePreviewDefaults() }
                    .disabled(previewIsDefault)
            case .metadata:
                Button("Restore Metadata Panel Defaults") { restoreMetadataDefaults() }
                    .disabled(metadataIsDefault)
            case .thumbnails:
                Button("Restore Thumbnail Defaults") { restoreThumbnailDefaults() }
                    .disabled(thumbnailsAreDefault)
            case .controls:
                EmptyView()
            }
        }
        .frame(height: 22)
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    // MARK: - Panes

    private var generalPane: some View {
        Group {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 72, height: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("MIQ: Medical Image Quick Look")
                            .font(.title3.weight(.semibold))
                        HStack(spacing: 4) {
                            Text("Version \(Self.currentVersion) · MIT License ·")
                                .foregroundStyle(.secondary)
                            Link("GitHub", destination: URL(string: "https://github.com/marcoduering/MIQ")!)
                        }
                        .font(.callout)
                        Text("Select an image in Finder and press Space.")
                            .padding(.top, 6)
                        HStack(spacing: 5) {
                            ForEach(["NIfTI", "FreeSurfer MGH", "MRtrix MIF", "NRRD"], id: \.self) { format in
                                Text(format)
                                    .font(.callout)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Supported formats: NIfTI, FreeSurfer MGH, MRtrix MIF, NRRD")
                    }
                }
                .padding(.vertical, 10)
            } header: {
                Self.sideColumnAlignmentSpacer
            }

            Section {
                // Lives in the app's own defaults and is Sparkle's to own, so
                // `restoreDefaults()` resets it through Sparkle rather than the
                // App Group suite. On-demand checking stays in the MIQ menu
                // ("Check for Updates…").
                Toggle(isOn: $updater.automaticallyChecksForUpdates) {
                    Text("Check for updates automatically")
                    Text("You can also choose MIQ › Check for Updates… at any time.")
                }
            } header: {
                // Sets the app's identity apart from the settings below.
                Color.clear.frame(height: 6)
            }

            Section("Disclaimer") {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text("Not a medical device. Not for diagnostic use.")
                        .fontWeight(.semibold)
                    Spacer()
                    // A popover rather than an expanding row: the window has a
                    // fixed height and nothing below should move.
                    Button("Read Full Disclaimer") { showFullDisclaimer.toggle() }
                        .buttonStyle(.link)
                        .popover(isPresented: $showFullDisclaimer, arrowEdge: .bottom) {
                            Text(.init(Self.disclaimerText))
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(width: 340, alignment: .leading)
                                .padding(14)
                        }
                }

                Toggle("Hide the disclaimer in previews", isOn: Binding(
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
    }

    private var previewPane: some View {
        Group {
            Section {
                orientationPicker(selection: $imageOrientation)
                segmentationPicker(selection: $segmentationColoring)
                ColorPicker(selection: Binding(
                    get: { axisLabelColor.color },
                    set: { axisLabelColor = StoredColor($0) }
                )) {
                    Text("Axis labels & crosshair colour")
                }
                Toggle("Show axis labels", isOn: $showAxisLabels)
            } header: {
                // Invisible: drops the first group level with the side
                // column's box, below that column's title.
                Self.sideColumnAlignmentSpacer
            }

            Section {
                PercentileRangeControl(lower: $lowerPercentile, upper: $upperPercentile) {
                    RowTitle(title: "Intensity window",
                             info: "The initial grey range, as percentiles of the non-zero voxels (default \(Int(MIQConfig.Defaults.windowLowerPercentile))–\(Int(MIQConfig.Defaults.windowUpperPercentile))%). In the preview, secondary-click and drag to adjust it live.")
                }
                Toggle(isOn: $perVolumeIntensityWindow) {
                    RowTitle(title: "Recompute window for each volume",
                             info: "For 4D series. When off, the window from the first volume is kept while you change volumes.")
                }
            }

            Section {
                Toggle(isOn: $deferLargeNetworkPreviews) {
                    RowTitle(title: "Ask before loading large files on network volumes",
                             info: "Files over \(Int(MIQConfig.Defaults.networkPreviewThresholdMB)) MB show a Load Preview button instead of loading automatically: loading a large file over a slow share can stall Finder. NIfTI files are always loaded, because MIQ reads only their first volume.")
                }
            }
        }
    }

    private var metadataPane: some View {
        Section {
            ForEach(metadataOrder.fields, id: \.self) { field in
                metadataRow(field)
            }
        } header: {
            Self.sideColumnAlignmentSpacer
        } footer: {
            Text("Drag rows to reorder, or use the arrows.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var thumbnailsPane: some View {
        Group {
            Section {
                Toggle("Show slice thumbnails in Finder", isOn: $showThumbnails)
            } header: {
                Self.sideColumnAlignmentSpacer
            }

            if showThumbnails {
                Section {
                    orientationPicker(selection: $thumbnailImageOrientation)
                    segmentationPicker(selection: $thumbnailSegmentationColoring)
                    PercentileRangeControl(lower: $thumbnailLowerPercentile, upper: $thumbnailUpperPercentile) {
                        Text("Intensity window")
                    }
                } header: {
                    HStack {
                        Text("Appearance")
                        Spacer()
                        Button(thumbnailsMatchPreview ? "Matches Preview" : "Use Preview Settings") {
                            copyPreviewSettingsToThumbnails()
                        }
                        .buttonStyle(.plain)
                        .fontWeight(.regular)
                        .foregroundStyle(thumbnailsMatchPreview ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                        .disabled(thumbnailsMatchPreview)
                        .help("Copies orientation, segmentation colours and intensity window from the Preview pane.")
                    }
                }

                Section {
                    Toggle(isOn: $showThumbnailsOnNetworkVolumes) {
                        RowTitle(title: "Include network volumes",
                                 info: "Off by default: generating thumbnails reads each file over the network, which is slow on remote shares.")
                    }
                    HStack {
                        RowTitle(title: "Refresh existing thumbnails",
                                 info: "Finder caches thumbnails. New files pick up changes automatically; existing ones refresh when the file changes, or right away with this Terminal command.\n\nIf they still look stale, also run:\nrm -rf \"$(getconf DARWIN_USER_CACHE_DIR)com.apple.iconservices.store\" && killall Dock Finder\n\nTo stop generating thumbnails, disable the extension in System Settings › General › Login Items & Extensions.")
                        Spacer()
                        Button {
                            copyThumbnailRefreshCommand()
                        } label: {
                            Label(didCopyRefreshCommand ? "Copied" : "Copy Command",
                                  systemImage: didCopyRefreshCommand ? "checkmark" : "doc.on.doc")
                        }
                    }
                }
            } else {
                Section {
                    Text("Thumbnails are off. Finder shows its standard document icons.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The single reference for the preview's input model — keep it in sync
    /// with MIQSliceCanvas, MIQVolumeScrubber, ScrollStepResolver and the
    /// model's cursor/volume methods.
    private var controlsPane: some View {
        let trackpad = inputDevice == .trackpad
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("Show gestures for")
                    .foregroundStyle(.secondary)
                Picker("Show gestures for", selection: $inputDevice) {
                    ForEach(InputDevice.allCases, id: \.self) { device in
                        Text(device.label).tag(device)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    GestureCard(
                        title: "Move the crosshair",
                        systemImage: "dot.scope",
                        gesture: trackpad ? "Click, tap or one-finger drag" : "Click or drag"
                    )
                    GestureCard(
                        title: "Scroll through slices",
                        systemImage: "square.stack",
                        gesture: trackpad ? "Two-finger scroll" : "Scroll wheel"
                    )
                }
                GridRow {
                    GestureCard(
                        title: "Adjust brightness & contrast",
                        systemImage: "circle.lefthalf.filled",
                        gesture: "Secondary-click + drag",
                        note: "Up/down changes brightness (level), left/right changes contrast (window)."
                    )
                    GestureCard(
                        title: "Change volume (4D)",
                        systemImage: "square.stack.3d.down.forward",
                        gesture: trackpad ? "Two-finger scroll" : "Scroll wheel",
                        modifierKey: "⌥",
                        note: "Over any slice or the metadata panel. Or drag the Volumes slider in the metadata panel, or click anywhere on it."
                    )
                }
            }
            // Only as tall as its content; the cards' maxHeight then just
            // equalises the two cards in a row instead of filling the pane.
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }

    // MARK: - Rows

    private func orientationPicker(selection: Binding<ViewOrientation>) -> some View {
        Picker(selection: selection) {
            ForEach(ViewOrientation.allCases, id: \.rawValue) { orientation in
                Text(orientation.label).tag(orientation)
            }
        } label: {
            RowTitle(title: "Orientation",
                     info: "As Stored shows voxels in file order, with edge labels for the anatomy. Neurological puts the patient’s right on the right of the screen; Radiological on the left.")
        }
        .pickerStyle(.segmented)
    }

    private func segmentationPicker(selection: Binding<SegmentationColoring>) -> some View {
        Picker(selection: selection) {
            ForEach(SegmentationColoring.allCases, id: \.rawValue) { mode in
                Text(mode.label).tag(mode)
            }
        } label: {
            RowTitle(title: "Segmentation colours",
                     info: "Label files render in colour. Auto uses FreeSurfer colours when it recognises a FreeSurfer parcellation, distinct colours otherwise. Off renders them in greyscale.")
        }
        .pickerStyle(.segmented)
    }

    private func metadataRow(_ field: MetadataField) -> some View {
        let fields = metadataOrder.fields
        let index = fields.firstIndex(of: field) ?? 0
        return HStack(spacing: 8) {
            Toggle(isOn: visibilityBinding(for: field)) {
                HStack(spacing: 4) {
                    Text(metadataLabel(field))
                    if let helpText = metadataHelpText(field) {
                        InfoButton(text: helpText)
                    }
                }
            }
            .toggleStyle(.checkbox)
            Spacer()
            Button {
                moveMetadataField(field, by: -1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)
            .accessibilityLabel("Move \(metadataLabel(field)) up")
            Button {
                moveMetadataField(field, by: 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(index == fields.count - 1)
            .accessibilityLabel("Move \(metadataLabel(field)) down")
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
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

    /// The preview's own panel text (`MetadataPanelText`, shared with the
    /// extension) for the sample, in the user's order and visibility. The
    /// voxel value — shown in the preview only while interacting — appears as
    /// the value under a centred crosshair, and the disclaimer footer follows
    /// the General pane's setting.
    @ViewBuilder
    private var metadataPanelPreview: some View {
        if let sampleMetadata {
            let fontSize: CGFloat = 11
            let layout = MetadataPanelText.layout(
                entries: sampleMetadata.entries,
                order: metadataOrder.fields,
                isVisible: { visibilityBinding(for: $0).wrappedValue },
                isFourD: false,
                showsValue: false,
                staticValueText: sampleMetadata.centreValue
            )
            let labelColumnX = MetadataPanelText.labelColumnOrigin(
                for: layout.rows.map(\.label),
                font: .systemFont(ofSize: fontSize)
            )
            MetadataPanelSample(text: MetadataPanelText.attributedString(
                from: layout.rows,
                fontSize: fontSize,
                labelColumnX: labelColumnX,
                showsDisclaimer: !hideDisclaimerInPreview
            ))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - State helpers

    private var previewOptions: RenderingOptions {
        RenderingOptions(lowerPercentile: lowerPercentile, upperPercentile: upperPercentile,
                         orientation: imageOrientation, segmentationColoring: segmentationColoring)
    }

    private var thumbnailOptions: RenderingOptions {
        RenderingOptions(lowerPercentile: thumbnailLowerPercentile, upperPercentile: thumbnailUpperPercentile,
                         orientation: thumbnailImageOrientation, segmentationColoring: thumbnailSegmentationColoring)
    }

    private var thumbnailsMatchPreview: Bool {
        thumbnailImageOrientation == imageOrientation
            && thumbnailSegmentationColoring == segmentationColoring
            && thumbnailLowerPercentile == lowerPercentile
            && thumbnailUpperPercentile == upperPercentile
    }

    private var previewIsDefault: Bool {
        imageOrientation == .defaultValue
            && segmentationColoring == .defaultValue
            && lowerPercentile == MIQConfig.Defaults.windowLowerPercentile
            && upperPercentile == MIQConfig.Defaults.windowUpperPercentile
            && perVolumeIntensityWindow == MIQConfig.Defaults.perVolumeIntensityWindow
            && showAxisLabels == MIQConfig.Defaults.showAxisLabels
            && axisLabelColor.isApproximately(.defaultValue)
            && deferLargeNetworkPreviews == MIQConfig.Defaults.deferLargeNetworkPreviews
    }

    private var metadataIsDefault: Bool {
        metadataOrder == .defaultValue
            && MetadataField.allCases.allSatisfy { field in
                visibilityBinding(for: field).wrappedValue == Self.defaultVisibility(field)
            }
    }

    private var thumbnailsAreDefault: Bool {
        showThumbnails == MIQConfig.Defaults.showThumbnails
            && showThumbnailsOnNetworkVolumes == MIQConfig.Defaults.showThumbnailsOnNetworkVolumes
            && thumbnailImageOrientation == .thumbnailDefaultValue
            && thumbnailSegmentationColoring == .thumbnailDefaultValue
            && thumbnailLowerPercentile == MIQConfig.Defaults.thumbnailWindowLowerPercentile
            && thumbnailUpperPercentile == MIQConfig.Defaults.thumbnailWindowUpperPercentile
    }

    private func copyPreviewSettingsToThumbnails() {
        thumbnailImageOrientation = imageOrientation
        thumbnailSegmentationColoring = segmentationColoring
        thumbnailLowerPercentile = lowerPercentile
        thumbnailUpperPercentile = upperPercentile
    }

    private func moveMetadataField(_ field: MetadataField, by offset: Int) {
        var fields = metadataOrder.fields
        guard let from = fields.firstIndex(of: field) else { return }
        let to = from + offset
        guard fields.indices.contains(to) else { return }
        fields.swapAt(from, to)
        metadataOrder = StoredMetadataOrder(fields)
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

    private static func defaultVisibility(_ field: MetadataField) -> Bool {
        switch field {
        case .format:      return MIQConfig.Defaults.showMetadataFormat
        case .dimensions:  return MIQConfig.Defaults.showMetadataDimensions
        case .spacing:     return MIQConfig.Defaults.showMetadataSpacing
        case .orientation: return MIQConfig.Defaults.showMetadataOrientation
        case .datatype:    return MIQConfig.Defaults.showMetadataDatatype
        case .volumes:     return MIQConfig.Defaults.showMetadataVolumes
        case .scaling:     return MIQConfig.Defaults.showMetadataScaling
        case .value:       return MIQConfig.Defaults.showMetadataValue
        }
    }

    private func restorePreviewDefaults() {
        imageOrientation  = ViewOrientation.defaultValue
        segmentationColoring = SegmentationColoring.defaultValue
        lowerPercentile   = MIQConfig.Defaults.windowLowerPercentile
        upperPercentile   = MIQConfig.Defaults.windowUpperPercentile
        perVolumeIntensityWindow = MIQConfig.Defaults.perVolumeIntensityWindow
        showAxisLabels    = MIQConfig.Defaults.showAxisLabels
        axisLabelColor    = StoredColor.defaultValue
        deferLargeNetworkPreviews = MIQConfig.Defaults.deferLargeNetworkPreviews
    }

    private func restoreMetadataDefaults() {
        showMetadataFormat      = MIQConfig.Defaults.showMetadataFormat
        showMetadataDimensions  = MIQConfig.Defaults.showMetadataDimensions
        showMetadataSpacing     = MIQConfig.Defaults.showMetadataSpacing
        showMetadataOrientation = MIQConfig.Defaults.showMetadataOrientation
        showMetadataDatatype    = MIQConfig.Defaults.showMetadataDatatype
        showMetadataVolumes     = MIQConfig.Defaults.showMetadataVolumes
        showMetadataScaling     = MIQConfig.Defaults.showMetadataScaling
        showMetadataValue       = MIQConfig.Defaults.showMetadataValue
        metadataOrder           = StoredMetadataOrder.defaultValue
    }

    private func restoreThumbnailDefaults() {
        showThumbnails            = MIQConfig.Defaults.showThumbnails
        showThumbnailsOnNetworkVolumes = MIQConfig.Defaults.showThumbnailsOnNetworkVolumes
        thumbnailImageOrientation = ViewOrientation.thumbnailDefaultValue
        thumbnailSegmentationColoring = SegmentationColoring.thumbnailDefaultValue
        thumbnailLowerPercentile  = MIQConfig.Defaults.thumbnailWindowLowerPercentile
        thumbnailUpperPercentile  = MIQConfig.Defaults.thumbnailWindowUpperPercentile
    }

    private func restoreDefaults() {
        restorePreviewDefaults()
        restoreMetadataDefaults()
        restoreThumbnailDefaults()
        hideDisclaimerInPreview = MIQConfig.Defaults.hideDisclaimerInPreview
        // The default is SUEnableAutomaticChecks in Info.plist (on); see
        // the Sparkle convention in CLAUDE.md for why it ships on.
        updater.automaticallyChecksForUpdates = true
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
