import AppKit
import Foundation
import OSLog
import MIQCore

@MainActor
final class MIQPreviewModel {
    private let logger = MIQLogger.make(category: "model")

    private struct RawPreviewData: Sendable {
        let slices: [SlicePlane: SliceImage]
        let orientations: [SlicePlane: SliceOrientationLabels]
        let metadataEntries: [MetadataEntry]
        let interactiveState: InteractivePreviewState
    }

    private struct InteractivePreviewState: Sendable {
        let volume: MIQVolume
        let options: RenderingOptions
        let maxDimension: Int
        let windowBounds: MIQIntensityWindowBounds?
        let centerCursor: MIQVolumeCursor
    }

    enum State {
        case idle
        case loading
        case ready
        case failed(String)
    }

    var state: State = .idle
    var coronal: NSImage?
    var sagittal: NSImage?
    var axial: NSImage?
    var coronalOrientation = SliceOrientationLabels.placeholderCoronal
    var sagittalOrientation = SliceOrientationLabels.placeholderSagittal
    var axialOrientation = SliceOrientationLabels.placeholderAxial
    var metadataEntries: [MetadataEntry] = []
    var onChange: (() -> Void)?
    private(set) var isInteractiveModeActive = false
    var isInteractiveModeReady: Bool { interactiveState != nil }

    private let url: URL
    private let maxDimension = 512
    private var renderingOptions: RenderingOptions?
    private var interactiveState: InteractivePreviewState?
    private var currentCursor: MIQVolumeCursor?
    private var displayedCursor: MIQVolumeCursor?
    private var interactionPreparationTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var pendingRenderCursor: MIQVolumeCursor?
    private var pendingInteractiveActivation = false

    init(url: URL) {
        self.url = url
    }

    deinit {
        interactionPreparationTask?.cancel()
        renderTask?.cancel()
    }

    func load() async {
        state = .loading
        onChange?()
        let fileURL = self.url
        let options = RenderingOptions(
            lowerPercentile: MIQConfig.windowLowerPercentile,
            upperPercentile: MIQConfig.windowUpperPercentile,
            orientation: MIQConfig.imageOrientation
        )
        let maxDimension = self.maxDimension
        let cacheKey = MIQPreviewCache.makeKey(fileURL: fileURL, maxDimension: maxDimension, options: options)
        logger.notice("load() started for: \(fileURL.lastPathComponent, privacy: .public)")
        logger.notice("MIQConfig percentiles: lower=\(options.lowerPercentile, privacy: .public), upper=\(options.upperPercentile, privacy: .public), orientation=\(options.orientation.rawValue, privacy: .public), showAxisLabels=\(MIQConfig.showAxisLabels, privacy: .public)")

        interactionPreparationTask?.cancel()
        interactionPreparationTask = nil
        renderTask?.cancel()
        renderTask = nil
        renderingOptions = options
        interactiveState = nil
        currentCursor = nil
        displayedCursor = nil
        isInteractiveModeActive = false
        pendingRenderCursor = nil
        // pendingInteractiveActivation is preserved: an early click (before load()
        // ran) may have set it, and we want that intent honored once we're ready.

        if let cached = MIQPreviewCache.bundle(for: cacheKey) {
            logger.notice("load() cache hit — applying cached center preview")
            apply(bundle: cached)
            state = .ready
            onChange?()
            if pendingInteractiveActivation, interactionPreparationTask == nil {
                prepareInteractiveState(fileURL: fileURL, options: options)
            }
            return
        }

        do {
            let raw = try await Task.detached(priority: .userInitiated) { () -> RawPreviewData in
                try Self.loadPreviewData(fileURL: fileURL, options: options, maxDimension: maxDimension)
            }.value

            let bundle = makeBundle(from: raw)
            MIQPreviewCache.insert(bundle, for: cacheKey)
            apply(raw: raw)
            state = .ready
            logger.notice("load() finished successfully")
            onChange?()
            if pendingInteractiveActivation, let interactiveState {
                pendingInteractiveActivation = false
                activateInteractionMode(using: interactiveState)
            }
        } catch {
            logger.error("load() failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
            onChange?()
        }
    }

    func stepSlice(plane: SlicePlane, deltaSteps: Int) {
        guard isInteractiveModeActive, deltaSteps != 0, let interactiveState else { return }
        let cursor = currentCursor ?? interactiveState.centerCursor
        let geometry = interactiveState.volume.sliceGeometry(for: plane, options: interactiveState.options)
        let dimensions = [interactiveState.volume.width, interactiveState.volume.height, interactiveState.volume.depth]
        let currentIndex = cursor.coordinate(forAxis: geometry.sliceAxis)
        let nextIndex = max(0, min(dimensions[geometry.sliceAxis] - 1, currentIndex + deltaSteps))
        guard nextIndex != currentIndex else { return }

        var coordinates = [cursor.x, cursor.y, cursor.z]
        coordinates[geometry.sliceAxis] = nextIndex
        let updated = MIQVolumeCursor(x: coordinates[0], y: coordinates[1], z: coordinates[2])
        guard updated != currentCursor else { return }

        currentCursor = updated
        onChange?()
        scheduleRender(for: updated)
    }

    func updateCursor(plane: SlicePlane, normalizedPoint: MIQNormalizedPoint) {
        guard isInteractiveModeActive, let interactiveState else { return }
        let cursor = currentCursor ?? interactiveState.centerCursor
        let sliceIndex = interactiveState.volume.sliceIndex(for: plane, cursor: cursor, options: interactiveState.options)
        let updated = interactiveState.volume.cursor(
            for: plane,
            sliceIndex: sliceIndex,
            normalizedPoint: normalizedPoint,
            options: interactiveState.options
        )
        guard updated != currentCursor else { return }

        currentCursor = updated
        onChange?()
        scheduleRender(for: updated)
    }

    func toggleInteractionMode() {
        if isInteractiveModeActive {
            deactivateInteractionMode()
            return
        }
        if let interactiveState {
            activateInteractionMode(using: interactiveState)
            return
        }

        pendingInteractiveActivation = true
        // If load() hasn't established options yet, the pending flag will be
        // honored once load() completes. Otherwise, kick off prep now.
        guard let options = renderingOptions else { return }
        guard interactionPreparationTask == nil else { return }
        prepareInteractiveState(fileURL: url, options: options)
    }

    private func deactivateInteractionMode() {
        guard let interactiveState else { return }
        pendingInteractiveActivation = false
        isInteractiveModeActive = false
        currentCursor = interactiveState.centerCursor
        scheduleRender(for: interactiveState.centerCursor)
        onChange?()
    }

    private func activateInteractionMode(using interactiveState: InteractivePreviewState) {
        isInteractiveModeActive = true
        if currentCursor == nil {
            currentCursor = interactiveState.centerCursor
        }
        onChange?()
    }

    func crosshairPoint(for plane: SlicePlane) -> MIQNormalizedPoint? {
        guard isInteractiveModeActive, let interactiveState, let currentCursor else {
            return nil
        }
        return interactiveState.volume.normalizedPoint(for: plane, cursor: currentCursor, options: interactiveState.options)
    }

    private func apply(bundle: MIQPreviewBundle) {
        coronal = bundle.slices[.coronal]
        sagittal = bundle.slices[.sagittal]
        axial = bundle.slices[.axial]
        coronalOrientation = bundle.orientations[.coronal] ?? .placeholderCoronal
        sagittalOrientation = bundle.orientations[.sagittal] ?? .placeholderSagittal
        axialOrientation = bundle.orientations[.axial] ?? .placeholderAxial
        metadataEntries = bundle.metadataEntries
    }

    private func apply(raw: RawPreviewData) {
        interactiveState = raw.interactiveState
        currentCursor = raw.interactiveState.centerCursor
        displayedCursor = raw.interactiveState.centerCursor
        metadataEntries = raw.metadataEntries
        coronalOrientation = raw.orientations[.coronal] ?? .placeholderCoronal
        sagittalOrientation = raw.orientations[.sagittal] ?? .placeholderSagittal
        axialOrientation = raw.orientations[.axial] ?? .placeholderAxial
        apply(sliceImages: raw.slices)
    }

    private func apply(sliceImages: [SlicePlane: SliceImage]) {
        if let coronalImage = sliceImages[.coronal].flatMap(MIQImageBridge.makeNSImage) {
            coronal = coronalImage
        }
        if let sagittalImage = sliceImages[.sagittal].flatMap(MIQImageBridge.makeNSImage) {
            sagittal = sagittalImage
        }
        if let axialImage = sliceImages[.axial].flatMap(MIQImageBridge.makeNSImage) {
            axial = axialImage
        }
    }

    private func makeBundle(from raw: RawPreviewData) -> MIQPreviewBundle {
        var nsSlices: [SlicePlane: NSImage] = [:]
        for plane in SlicePlane.allCases {
            if let sliceImage = raw.slices[plane], let image = MIQImageBridge.makeNSImage(from: sliceImage) {
                nsSlices[plane] = image
            }
        }
        return MIQPreviewBundle(
            slices: nsSlices,
            orientations: raw.orientations,
            metadataEntries: raw.metadataEntries
        )
    }

    private func prepareInteractiveState(fileURL: URL, options: RenderingOptions) {
        let maxDimension = self.maxDimension
        interactionPreparationTask?.cancel()
        interactionPreparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let interactiveState = try await Task.detached(priority: .userInitiated) { () -> InteractivePreviewState in
                    try Self.loadInteractiveState(fileURL: fileURL, options: options, maxDimension: maxDimension)
                }.value
                guard !Task.isCancelled else { return }
                self.interactionPreparationTask = nil
                self.interactiveState = interactiveState
                self.currentCursor = interactiveState.centerCursor
                self.displayedCursor = interactiveState.centerCursor
                if self.pendingInteractiveActivation {
                    self.pendingInteractiveActivation = false
                    self.activateInteractionMode(using: interactiveState)
                    return
                }
                self.onChange?()
            } catch {
                self.interactionPreparationTask = nil
                self.pendingInteractiveActivation = false
                self.logger.error("interactive state preparation failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func scheduleRender(for cursor: MIQVolumeCursor) {
        guard interactiveState != nil else { return }
        pendingRenderCursor = cursor
        guard renderTask == nil else { return }
        startNextRenderIfNeeded()
    }

    private func startNextRenderIfNeeded() {
        guard let interactiveState, let cursor = pendingRenderCursor else {
            renderTask = nil
            return
        }

        pendingRenderCursor = nil
        let displayedCursor = self.displayedCursor ?? cursor
        let planesToRender = Self.planesNeedingRender(
            from: displayedCursor,
            to: cursor,
            interactiveState: interactiveState
        )
        guard !planesToRender.isEmpty else {
            self.displayedCursor = cursor
            renderTask = nil
            startNextRenderIfNeeded()
            return
        }

        renderTask = Task { [weak self] in
            guard let self else { return }
            let slices = await Task.detached(priority: .userInitiated) { () -> [SlicePlane: SliceImage] in
                Self.renderSlices(for: cursor, planes: planesToRender, interactiveState: interactiveState)
            }.value
            guard !Task.isCancelled else { return }
            self.apply(sliceImages: slices)
            self.displayedCursor = cursor
            self.onChange?()
            self.renderTask = nil
            self.startNextRenderIfNeeded()
        }
    }

    private nonisolated static func loadPreviewData(
        fileURL: URL,
        options: RenderingOptions,
        maxDimension: Int
    ) throws -> RawPreviewData {
        try withSecurityScopedAccess(to: fileURL) {
            let image = try MIQParser().parse(url: fileURL)
            let volume = MIQVolume(image: image)
            let interactiveState = makeInteractiveState(volume: volume, options: options, maxDimension: maxDimension)
            let slices = renderSlices(for: interactiveState.centerCursor, planes: SlicePlane.allCases, interactiveState: interactiveState)

            var orientations: [SlicePlane: SliceOrientationLabels] = [:]
            for plane in SlicePlane.allCases {
                orientations[plane] = volume.displayOrientation(for: plane, options: options)
            }

            var metadata = MIQMetadata(header: image.header, orientation: volume.storageOrientationLabel()).asDisplayLines()
            metadata.insert(metadataFormatEntry(for: fileURL, header: image.header), at: 0)
            #if DEBUG
            if let built = buildDateEntry() { metadata.append(built) }
            #endif

            return RawPreviewData(
                slices: slices,
                orientations: orientations,
                metadataEntries: metadata,
                interactiveState: interactiveState
            )
        }
    }

    private nonisolated static func loadInteractiveState(
        fileURL: URL,
        options: RenderingOptions,
        maxDimension: Int
    ) throws -> InteractivePreviewState {
        try withSecurityScopedAccess(to: fileURL) {
            let image = try MIQParser().parse(url: fileURL)
            let volume = MIQVolume(image: image)
            return makeInteractiveState(volume: volume, options: options, maxDimension: maxDimension)
        }
    }

    private nonisolated static func makeInteractiveState(
        volume: MIQVolume,
        options: RenderingOptions,
        maxDimension: Int
    ) -> InteractivePreviewState {
        InteractivePreviewState(
            volume: volume,
            options: options,
            maxDimension: maxDimension,
            windowBounds: volume.fixedCenterWindow(volumeIndex: 0, options: options),
            centerCursor: volume.centerCursor()
        )
    }

    private nonisolated static func renderSlices(
        for cursor: MIQVolumeCursor,
        planes: [SlicePlane],
        interactiveState: InteractivePreviewState
    ) -> [SlicePlane: SliceImage] {
        var slices: [SlicePlane: SliceImage] = [:]
        for plane in planes {
            let index = interactiveState.volume.sliceIndex(for: plane, cursor: cursor, options: interactiveState.options)
            slices[plane] = interactiveState.volume.slice(
                plane: plane,
                index: index,
                volumeIndex: 0,
                maxDimension: interactiveState.maxDimension,
                options: interactiveState.options,
                windowBounds: interactiveState.windowBounds
            )
        }
        return slices
    }

    private nonisolated static func planesNeedingRender(
        from oldCursor: MIQVolumeCursor,
        to newCursor: MIQVolumeCursor,
        interactiveState: InteractivePreviewState
    ) -> [SlicePlane] {
        SlicePlane.allCases.filter { plane in
            let oldIndex = interactiveState.volume.sliceIndex(for: plane, cursor: oldCursor, options: interactiveState.options)
            let newIndex = interactiveState.volume.sliceIndex(for: plane, cursor: newCursor, options: interactiveState.options)
            return oldIndex != newIndex
        }
    }

    private nonisolated static func withSecurityScopedAccess<T>(to fileURL: URL, operation: () throws -> T) throws -> T {
        let didAccess = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        return try operation()
    }

    private nonisolated static func metadataFormatEntry(for url: URL, header: MIQHeader) -> MetadataEntry {
        let displayName = header.formatLabel ?? MIQFileKind(url: url)?.displayName ?? "Unknown"
        return MetadataEntry(field: .format, text: "Format: \(displayName)")
    }

    #if DEBUG
    private nonisolated static func buildDateEntry() -> MetadataEntry? {
        guard let formatted = BuildDate.formatted(for: Bundle.main.executableURL) else { return nil }
        return MetadataEntry(field: nil, text: "DEBUG BUILD: \(formatted)")
    }
    #endif
}
