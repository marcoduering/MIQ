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
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
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
    }
}

private func metadataHelpText(_ field: MetadataField) -> String? {
    switch field {
    case .scaling:
        return "Shows the intensity scaling from the file header as x slope +/- intercept. Hidden when the scaling is identity (x 1 + 0, meaning voxel values are used as stored) or unavailable."
    default:
        return nil
    }
}


private enum SettingsTab: String, CaseIterable, Hashable {
    case about
    case imageDisplay
    case metadataPanel

    var label: String {
        switch self {
        case .about:         return "About"
        case .imageDisplay:  return "Image Display"
        case .metadataPanel: return "Metadata Panel"
        }
    }

    var symbol: String {
        switch self {
        case .about:         return "info.circle"
        case .imageDisplay:  return "photo"
        case .metadataPanel: return "list.bullet.rectangle"
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
        let view = NSView()
        DispatchQueue.main.async {
            context.coordinator.install(into: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if context.coordinator.window == nil {
            DispatchQueue.main.async {
                context.coordinator.install(into: nsView.window)
            }
        }
        context.coordinator.update(selection: selection)
    }

    final class Coordinator: NSObject, NSToolbarDelegate {
        @Binding var selection: SettingsTab
        weak var window: NSWindow?

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
        }

        func update(selection: SettingsTab) {
            guard let toolbar = window?.toolbar,
                  toolbar.selectedItemIdentifier != selection.toolbarItemIdentifier
            else { return }
            toolbar.selectedItemIdentifier = selection.toolbarItemIdentifier
        }

        func toolbar(_ toolbar: NSToolbar,
                     itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                     willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
            guard let tab = SettingsTab.tab(for: itemIdentifier) else { return nil }
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = tab.label
            item.paletteLabel = tab.label
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.label)
            item.target = self
            item.action = #selector(itemTapped(_:))
            return item
        }

        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            SettingsTab.allCases.map(\.toolbarItemIdentifier)
        }

        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            SettingsTab.allCases.map(\.toolbarItemIdentifier)
        }

        func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
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
    private enum FocusTarget: Hashable {
        case resetButton
    }

    private static let store = UserDefaults(suiteName: MIQConfig.appGroupID)

    @AppStorage(MIQConfig.Keys.imageOrientation, store: Self.store)
    private var imageOrientation: ViewOrientation = ViewOrientation.defaultValue
    @AppStorage(MIQConfig.Keys.windowLowerPercentile, store: Self.store)
    private var lowerPercentile: Double = MIQConfig.Defaults.windowLowerPercentile
    @AppStorage(MIQConfig.Keys.windowUpperPercentile, store: Self.store)
    private var upperPercentile: Double = MIQConfig.Defaults.windowUpperPercentile
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
    @AppStorage(MIQConfig.Keys.metadataOrder, store: Self.store)
    private var metadataOrder: StoredMetadataOrder = StoredMetadataOrder.defaultValue
    @AppStorage(MIQConfig.Keys.hideDisclaimerInPreview, store: Self.store)
    private var hideDisclaimerInPreview: Bool = MIQConfig.Defaults.hideDisclaimerInPreview

    @FocusState private var focusedTarget: FocusTarget?
    @State private var showHideDisclaimerConfirm = false
    @State private var draggedMetadataField: MetadataField?
    @State private var presentedMetadataInfoField: MetadataField?
    @State private var selectedTab: SettingsTab = .about

    private static let disclaimerText = """
        MIQ is **not a medical device** and is **not intended for diagnostic use**. It is a developer and researcher convenience tool only; do not use it for clinical decisions.

        MIQ is provided "as is" under the MIT License, without warranty. The authors and contributors accept no liability for any damages arising from its use or inability to use it, including data loss, incorrect image rendering, or decisions based on its previews.
        """

    var body: some View {
        Group {
            switch selectedTab {
            case .about:         aboutSettingsView
            case .imageDisplay:  imageDisplaySettingsView
            case .metadataPanel: metadataPanelSettingsView
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
        .frame(minWidth: 550, idealWidth: 550, maxWidth: 550, minHeight: 560, idealHeight: 560, maxHeight: 560)
        .onAppear {
            focusedTarget = .resetButton
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
                    Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–") – provided under MIT license")
                        .font(.callout)
                        .foregroundStyle(.secondary)
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
                    .focused($focusedTarget, equals: .resetButton)
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

    private var imageDisplaySettingsView: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Orientation", selection: $imageOrientation) {
                        ForEach(ViewOrientation.allCases, id: \.rawValue) { orientation in
                            Text(orientation.label).tag(orientation)
                        }
                    }
                    Text("By default, the image is rendered as stored (best for checking your raw data). Depending on its orientation, it may appear rotated or flipped. If you prefer a standardized view, the preview can be rendered in the neurological convention (patient right on viewer's right) or the radiological convention (patient right on viewer's left).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Lower intensity clip")
                        Spacer()
                        Text("\(Int(lowerPercentile))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Stepper("", value: $lowerPercentile, in: 0...49, step: 1)
                            .labelsHidden()
                    }

                    HStack {
                        Text("Upper intensity clip")
                        Spacer()
                        Text("\(Int(upperPercentile))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Stepper("", value: $upperPercentile, in: 51...100, step: 1)
                            .labelsHidden()
                    }

                    Text("Sets the percentile thresholds (for non-zero voxels) used to map voxel intensities to the greyscale display range (default: 2% - 98%).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Text("Display axis labels")
                    Spacer()
                    ColorPicker("", selection: Binding(
                        get: { axisLabelColor.color },
                        set: { axisLabelColor = StoredColor($0) }
                    ))
                    .labelsHidden()
                    .disabled(!showAxisLabels)
                    Toggle("", isOn: $showAxisLabels)
                        .labelsHidden()
                }
            }

            Section("Tip") {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lightbulb.fill")
                        .font(.title2)
                        .foregroundStyle(.yellow)

                    Text("Click on the images to enter **interactive mode**. After a cross-hair appears, you can click, drag and scroll the orthogonal view to change slice positions.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(5)

            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private var metadataPanelSettingsView: some View {
        Form {
            Section {
                Text("Choose which fields appear in the metadata panel. Drag and drop to rearrange the order.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

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

    private func visibilityBinding(for field: MetadataField) -> Binding<Bool> {
        switch field {
        case .format:      return $showMetadataFormat
        case .dimensions:  return $showMetadataDimensions
        case .spacing:     return $showMetadataSpacing
        case .orientation: return $showMetadataOrientation
        case .datatype:    return $showMetadataDatatype
        case .volumes:     return $showMetadataVolumes
        case .scaling:     return $showMetadataScaling
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

    private func restoreDefaults() {
        imageOrientation  = ViewOrientation.defaultValue
        lowerPercentile   = MIQConfig.Defaults.windowLowerPercentile
        upperPercentile   = MIQConfig.Defaults.windowUpperPercentile
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
    }
}

private struct MetadataReorderDropDelegate: DropDelegate {
    let destination: MetadataField
    @Binding var order: StoredMetadataOrder
    @Binding var draggedField: MetadataField?

    func dropEntered(info: DropInfo) {
        guard let dragged = draggedField, dragged != destination else { return }
        var fields = order.fields
        guard let from = fields.firstIndex(of: dragged),
              let to = fields.firstIndex(of: destination) else { return }
        fields.move(fromOffsets: IndexSet(integer: from),
                    toOffset: to > from ? to + 1 : to)
        order = StoredMetadataOrder(fields)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedField = nil
        return true
    }

    func dropExited(info: DropInfo) {}
}

#Preview {
    ContentView()
}
