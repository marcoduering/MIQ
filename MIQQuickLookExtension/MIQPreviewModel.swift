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

    /// Lifecycle of the lazy full-decompression for 4D `.nii.gz`. Every other
    /// kind is `.notNeeded` (uncompressed `.nii` is mmap'd; `.mgz`/`.mif.gz`
    /// already decompress in full; 3D `.nii.gz`'s volume-0 budget is the whole
    /// payload). `.pending` files re-parse fully the first time the user steps
    /// past volume 0; until `.expanded`, volumes > 0 render the zero backstop.
    /// `.failed` keeps volumes > 0 on the backstop *without* retrying on every
    /// step (no storm), but is reset to `.pending` at the next scroll-gesture
    /// start so a transient failure isn't permanent for the session.
    private enum ExpansionState {
        case notNeeded
        case pending
        case expanding
        case expanded
        case failed
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
    private(set) var hasInteracted = false

    private let url: URL
    private let fileKind: MIQFileKind?
    private let maxDimension = 512
    private var renderingOptions: RenderingOptions?
    private var interactiveState: InteractivePreviewState?
    private var expansionState: ExpansionState = .notNeeded
    private var expansionTask: Task<Void, Never>?
    private var currentCursor: MIQVolumeCursor?
    private var displayedCursor: MIQVolumeCursor?
    private var windowAdjustment: MIQIntensityWindowBounds?
    private var pendingForceRender = false
    private var interactionPreparationTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var pendingRenderCursor: MIQVolumeCursor?

    init(url: URL) {
        self.url = url
        self.fileKind = MIQFileKind(url: url)
    }

    deinit {
        interactionPreparationTask?.cancel()
        renderTask?.cancel()
        expansionTask?.cancel()
    }

    /// Only a 4D `.nii.gz` carries a volume-0-capped buffer that hides volumes
    /// > 0. Everything else already holds the full payload.
    private static func needsExpansion(kind: MIQFileKind?, volumes: Int) -> Bool {
        kind == .niiGz && volumes > 1
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

        // Preserve interactiveState when reloading the same file with the same options
        // (the typical cache-hit path). Clearing it forces a re-parse before the first
        // scroll can fire, causing silent drops that feel like lag.
        let reusingInteractiveState = interactiveState != nil && renderingOptions == options

        interactionPreparationTask?.cancel()
        interactionPreparationTask = nil
        renderTask?.cancel()
        renderTask = nil
        renderingOptions = options
        if !reusingInteractiveState {
            interactiveState = nil
            // A fresh parse starts capped again; the cache-hit reuse path keeps
            // whatever expansion was already achieved for this file+options.
            expansionTask?.cancel()
            expansionTask = nil
            expansionState = .notNeeded
        }
        currentCursor = interactiveState?.centerCursor
        displayedCursor = interactiveState?.centerCursor
        hasInteracted = false
        windowAdjustment = nil
        pendingForceRender = false
        pendingRenderCursor = nil

        if let cached = MIQPreviewCache.bundle(for: cacheKey) {
            let stateLabel = reusingInteractiveState ? "reused" : "pending"
            logger.notice("load() cache hit — applying cached center preview (interactive state \(stateLabel, privacy: .public))")
            apply(bundle: cached)
            state = .ready
            onChange?()
            if !reusingInteractiveState {
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
        } catch {
            logger.error("load() failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
            onChange?()
        }
    }

    func scrollGestureBegan() {
        renderTask?.cancel()
        renderTask = nil
        pendingRenderCursor = nil
        // A new gesture earns one more expansion attempt after a prior failure.
        if expansionState == .failed { expansionState = .pending }
    }

    func stepSlice(plane: SlicePlane, deltaSteps: Int) {
        guard deltaSteps != 0, let interactiveState else { return }
        hasInteracted = true
        let cursor = currentCursor ?? interactiveState.centerCursor
        let geometry = interactiveState.volume.sliceGeometry(for: plane, options: interactiveState.options)
        let dimensions = [interactiveState.volume.width, interactiveState.volume.height, interactiveState.volume.depth]
        let currentIndex = cursor.coordinate(forAxis: geometry.sliceAxis)
        let nextIndex = max(0, min(dimensions[geometry.sliceAxis] - 1, currentIndex + deltaSteps))
        guard nextIndex != currentIndex else { return }

        var coordinates = [cursor.x, cursor.y, cursor.z]
        coordinates[geometry.sliceAxis] = nextIndex
        let updated = MIQVolumeCursor(x: coordinates[0], y: coordinates[1], z: coordinates[2], t: cursor.t)
        guard updated != currentCursor else { return }

        currentCursor = updated
        onChange?()
        scheduleRender(for: updated)
    }

    /// Step along the 4th (volume/time) axis, leaving x/y/z untouched. No-op for
    /// 3D files. Reuses the same throttled render path as `stepSlice`. For a
    /// volume-0-capped `.nii.gz`, timepoints > 0 render the zero backstop until
    /// the lazy-expand (kicked off here on first 4D intent) swaps in the fully
    /// decompressed volume.
    func stepVolume(deltaSteps: Int) {
        guard deltaSteps != 0, let interactiveState else { return }
        let volumes = interactiveState.volume.volumes
        guard volumes > 1 else { return }
        let cursor = currentCursor ?? interactiveState.centerCursor
        applyVolume(cursor.t + deltaSteps, interactiveState: interactiveState)
    }

    /// Absolute timepoint seek (the metadata scrubber). Same path as
    /// `stepVolume`; clamps into range and is a no-op for 3D files.
    func setVolume(to index: Int) {
        guard let interactiveState, interactiveState.volume.volumes > 1 else { return }
        applyVolume(index, interactiveState: interactiveState)
    }

    /// Total number of volumes along the 4th axis (1 for 3D).
    var volumeCount: Int { interactiveState?.volume.volumes ?? 1 }

    /// Current timepoint the preview is showing.
    var currentVolumeIndex: Int { currentCursor?.t ?? 0 }

    private func applyVolume(_ requestedT: Int, interactiveState: InteractivePreviewState) {
        let cursor = currentCursor ?? interactiveState.centerCursor
        let nextT = max(0, min(interactiveState.volume.volumes - 1, requestedT))
        guard nextT != cursor.t else { return }
        hasInteracted = true

        let updated = MIQVolumeCursor(x: cursor.x, y: cursor.y, z: cursor.z, t: nextT)
        guard updated != currentCursor else { return }

        currentCursor = updated
        triggerExpansionIfNeeded()
        onChange?()
        scheduleRender(for: updated)
    }

    /// `true` while the fully decompressed volume is still being prepared — the
    /// view layer uses this to show a "decompressing" affordance on the volume
    /// indicator (Phase 4).
    var isExpandingVolumes: Bool { expansionState == .expanding }

    /// Kick the one-time full decompression for a 4D `.nii.gz`. Idempotent:
    /// guarded by `expansionState`, and the model is `@MainActor` so the
    /// `.pending` → `.expanding` transition can't race a second caller.
    private func triggerExpansionIfNeeded() {
        guard expansionState == .pending, let interactiveState else { return }
        expansionState = .expanding
        let fileURL = self.url
        let options = interactiveState.options
        let maxDimension = interactiveState.maxDimension
        let windowBounds = interactiveState.windowBounds

        expansionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let expanded = try await Task.detached(priority: .userInitiated) { () -> InteractivePreviewState in
                    try Self.loadExpandedInteractiveState(
                        fileURL: fileURL,
                        options: options,
                        maxDimension: maxDimension,
                        windowBounds: windowBounds
                    )
                }.value
                guard !Task.isCancelled else { return }
                self.expansionTask = nil
                self.interactiveState = expanded
                self.expansionState = .expanded
                self.logger.notice("4D expansion complete — full decompression swapped in")
                // The cursor is unchanged but the underlying volume is not, so
                // force every plane to re-render against the real data.
                self.scheduleFullRender()
                self.onChange?()
            } catch {
                guard !Task.isCancelled else { return }
                self.expansionTask = nil
                // `.failed` (not `.notNeeded`): no retry on every subsequent
                // step within this gesture (no storm), but `scrollGestureBegan`
                // resets it to `.pending` so the *next* gesture retries — a
                // transient failure (I/O, security scope) isn't permanent.
                // Volumes > 0 keep the zero backstop; volume 0 stays correct.
                self.expansionState = .failed
                self.logger.error("4D expansion failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func updateCursor(plane: SlicePlane, normalizedPoint: MIQNormalizedPoint) {
        guard let interactiveState else { return }
        hasInteracted = true
        let cursor = currentCursor ?? interactiveState.centerCursor
        let sliceIndex = interactiveState.volume.sliceIndex(for: plane, cursor: cursor, options: interactiveState.options)
        let updated = interactiveState.volume.cursor(
            for: plane,
            sliceIndex: sliceIndex,
            normalizedPoint: normalizedPoint,
            options: interactiveState.options,
            t: cursor.t
        )
        guard updated != currentCursor else { return }

        currentCursor = updated
        onChange?()
        scheduleRender(for: updated)
    }

    func adjustWindow(deltaX: CGFloat, deltaY: CGFloat) {
        guard let interactiveState, let initialBounds = interactiveState.windowBounds else { return }

        let current = windowAdjustment ?? initialBounds
        let initialRange = initialBounds.high - initialBounds.low
        let sensitivity = initialRange * 0.005
        let minWidth = max(1e-6, initialRange * 0.01)

        let level = (current.high + current.low) / 2 + Float(deltaY) * sensitivity
        let width = max(minWidth, (current.high - current.low) + Float(deltaX) * sensitivity)
        windowAdjustment = MIQIntensityWindowBounds(low: level - width / 2, high: level + width / 2)
        onChange?()
        scheduleFullRender()
    }

    func crosshairPoint(for plane: SlicePlane) -> MIQNormalizedPoint? {
        guard hasInteracted, let interactiveState, let currentCursor else { return nil }
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
        expansionState = Self.needsExpansion(kind: fileKind, volumes: raw.interactiveState.volume.volumes) ? .pending : .notNeeded
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
                self.expansionState = Self.needsExpansion(kind: self.fileKind, volumes: interactiveState.volume.volumes) ? .pending : .notNeeded
                self.currentCursor = interactiveState.centerCursor
                self.displayedCursor = interactiveState.centerCursor
                self.onChange?()
            } catch {
                self.interactionPreparationTask = nil
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

    private func scheduleFullRender() {
        guard let interactiveState else { return }
        pendingRenderCursor = currentCursor ?? interactiveState.centerCursor
        pendingForceRender = true
        guard renderTask == nil else { return }
        startNextRenderIfNeeded()
    }

    private func startNextRenderIfNeeded() {
        guard let interactiveState, let cursor = pendingRenderCursor else {
            renderTask = nil
            return
        }

        pendingRenderCursor = nil
        let forceAll = pendingForceRender
        pendingForceRender = false
        let displayedCursor = self.displayedCursor ?? cursor
        let planesToRender = forceAll
            ? SlicePlane.allCases
            : Self.planesNeedingRender(from: displayedCursor, to: cursor, interactiveState: interactiveState)
        let effectiveWindowBounds = windowAdjustment ?? interactiveState.windowBounds

        guard !planesToRender.isEmpty else {
            self.displayedCursor = cursor
            renderTask = nil
            startNextRenderIfNeeded()
            return
        }

        renderTask = Task { [weak self] in
            guard let self else { return }
            let slices = await Task.detached(priority: .userInitiated) { () -> [SlicePlane: SliceImage] in
                Self.renderSlices(for: cursor, planes: planesToRender, interactiveState: interactiveState, windowBounds: effectiveWindowBounds)
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
            // Single decode of the center slices: the pooled buffer that derives the
            // window is the same buffer finalized into the first-frame images. The
            // previous makeInteractiveState + renderSlices(centerCursor) path decoded
            // them twice (once for the window, once for the render).
            let preview = volume.centerPreview(volumeIndex: 0, maxDimension: maxDimension, options: options)
            let interactiveState = InteractivePreviewState(
                volume: volume,
                options: options,
                maxDimension: maxDimension,
                windowBounds: preview.windowBounds,
                centerCursor: volume.centerCursor()
            )
            let slices = preview.slices

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

    /// Fully decompressed re-parse for 4D navigation. Reuses the volume-0
    /// `windowBounds` from the capped state so intensity windowing stays
    /// constant across the timeseries (comparable frames, no per-volume
    /// percentile recompute).
    private nonisolated static func loadExpandedInteractiveState(
        fileURL: URL,
        options: RenderingOptions,
        maxDimension: Int,
        windowBounds: MIQIntensityWindowBounds?
    ) throws -> InteractivePreviewState {
        try withSecurityScopedAccess(to: fileURL) {
            let image = try MIQParser().parse(url: fileURL, fullyDecompress: true)
            let volume = MIQVolume(image: image)
            return InteractivePreviewState(
                volume: volume,
                options: options,
                maxDimension: maxDimension,
                windowBounds: windowBounds,
                centerCursor: volume.centerCursor()
            )
        }
    }

    private nonisolated static func renderSlices(
        for cursor: MIQVolumeCursor,
        planes: [SlicePlane],
        interactiveState: InteractivePreviewState,
        windowBounds: MIQIntensityWindowBounds?
    ) -> [SlicePlane: SliceImage] {
        var slices: [SlicePlane: SliceImage] = [:]
        for plane in planes {
            let index = interactiveState.volume.sliceIndex(for: plane, cursor: cursor, options: interactiveState.options)
            slices[plane] = interactiveState.volume.slice(
                plane: plane,
                index: index,
                volumeIndex: cursor.t,
                maxDimension: interactiveState.maxDimension,
                options: interactiveState.options,
                windowBounds: windowBounds
            )
        }
        return slices
    }

    private nonisolated static func planesNeedingRender(
        from oldCursor: MIQVolumeCursor,
        to newCursor: MIQVolumeCursor,
        interactiveState: InteractivePreviewState
    ) -> [SlicePlane] {
        // A timepoint change reuses the same x/y/z, so the per-plane slice indices
        // are unchanged — but every plane samples a different volume and must
        // re-render. The spatial diff below would otherwise return nothing.
        if oldCursor.t != newCursor.t {
            return SlicePlane.allCases
        }
        return SlicePlane.allCases.filter { plane in
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
