import AppKit
import Foundation
import OSLog
import MIQCore

@MainActor
final class MIQPreviewModel {
    private let logger = MIQLogger.make(category: "model")

    private struct RawPreviewData: Sendable {
        let slices: [SlicePlane: RGBABitmap]
        let orientations: [SlicePlane: SliceOrientationLabels]
        let metadataEntries: [MetadataEntry]
        let interactiveState: InteractivePreviewState
    }

    private struct InteractivePreviewState: Sendable {
        let volume: MIQVolume
        let options: RenderingOptions
        let maxDimension: Int
        let windowBounds: MIQIntensityWindowBounds?
        let segmentationLut: SegmentationLut?
        let centerCursor: MIQVolumeCursor
    }

    enum State {
        case idle
        case loading
        case ready
        case failed(String)
        /// A large file on a network volume whose full read was deferred behind a
        /// placeholder (see `MIQConfig.deferLargeNetworkPreviews`). Carries the
        /// display name and on-disk size for the placeholder. `forceFullRead`
        /// (the "Load preview" button) bypasses the gate and parses normally.
        case deferred(name: String, sizeBytes: Int)
    }

    /// Result of the cold detached load: either the parsed preview, or a signal
    /// that the network gate deferred it (carrying the size for the placeholder).
    private enum LoadOutcome: Sendable {
        case loaded(RawPreviewData)
        case deferred(sizeBytes: Int)
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
    /// `MIQConfig.perVolumeIntensityWindow` captured at `load()`. Settings can
    /// only change while no preview is open, so it is fixed for an interaction.
    private var perVolumeWindow = false
    /// The auto (non-manual) window the most recent render actually applied. In
    /// per-volume mode this is the displayed volume's own window, so a W/L drag
    /// starts from what's on screen instead of snapping back to volume 0.
    private var lastAppliedAutoBounds: MIQIntensityWindowBounds?
    /// Per-timepoint auto window, memoized so revisiting a volume in per-volume
    /// mode doesn't re-decode its 3 center slices each time (`fixedCenterWindow`
    /// is the dominant per-step cost while scrubbing a 4D series). Keyed by `t`;
    /// only populated/consulted when `perVolumeWindow` is on and no manual W/L
    /// override is active. Cleared whenever the backing volume changes (fresh
    /// parse, cache-hit interactive prep, 4D expansion swap) since the bounds
    /// depend on the volume's pixels.
    private var perVolumeWindowCache: [Int: MIQIntensityWindowBounds] = [:]
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

    /// A 4D buffer that was loaded with the volume-0 cap (any `.nii.gz`, or a
    /// `.nii`/`.nii.gz` on a network volume via the bounded-prefix read) hides
    /// volumes > 0 until expanded. Detected from the actual payload rather than the
    /// file kind, so the bounded uncompressed `.nii` case isn't missed.
    private static func needsExpansion(volume: MIQVolume) -> Bool {
        volume.volumes > 1 && !volume.containsAllVolumes
    }

    /// - Parameter forceFullRead: when `true` (the placeholder's "Load preview"
    ///   button), bypass the large-network-preview gate and parse normally. The
    ///   default cold load respects the gate.
    func load(forceFullRead: Bool = false) async {
        state = .loading
        onChange?()
        let fileURL = self.url
        let kind = self.fileKind
        // The gate's on/off flag is a cheap UserDefaults read, fine on the
        // MainActor; the actual locality + size probe (which can block on a hung
        // mount) runs inside the detached task below.
        let applyNetworkGate = !forceFullRead && MIQConfig.deferLargeNetworkPreviews
        let options = RenderingOptions(
            lowerPercentile: MIQConfig.windowLowerPercentile,
            upperPercentile: MIQConfig.windowUpperPercentile,
            orientation: MIQConfig.imageOrientation,
            segmentationColoring: MIQConfig.segmentationColoring
        )
        let maxDimension = self.maxDimension
        // Read before the cache short-circuit so the interactive path honours it
        // on a cache hit too (the setting only affects volumes > 0, never the
        // cached volume-0 cold preview — see MIQConfig.perVolumeIntensityWindow).
        perVolumeWindow = MIQConfig.perVolumeIntensityWindow
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
            // New volume ⇒ stale per-timepoint windows. (The reuse path keeps
            // them: same volume, same options.)
            perVolumeWindowCache = [:]
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
            let outcome = try await Self.runCancelableDetached { () -> LoadOutcome in
                if applyNetworkGate, let sizeBytes = Self.networkDeferralSizeBytes(fileURL: fileURL, kind: kind) {
                    return .deferred(sizeBytes: sizeBytes)
                }
                return .loaded(try Self.loadPreviewData(fileURL: fileURL, options: options, maxDimension: maxDimension))
            }

            switch outcome {
            case .deferred(let sizeBytes):
                state = .deferred(name: fileURL.lastPathComponent, sizeBytes: sizeBytes)
                logger.notice("load() deferred large network preview: \(sizeBytes / (1024 * 1024), privacy: .public)MB")
                onChange?()
            case .loaded(let raw):
                let bundle = makeBundle(from: raw)
                MIQPreviewCache.insert(bundle, for: cacheKey)
                apply(raw: raw)
                state = .ready
                logger.notice("load() finished successfully")
                onChange?()
            }
        } catch is CancellationError {
            // Preview dismissed/replaced mid-parse (e.g. a large file abandoned on
            // a slow network mount). The load task is being torn down — leave state
            // untouched and don't surface a failure.
            logger.notice("load() canceled before completion")
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
        let segmentationLut = interactiveState.segmentationLut

        expansionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let expanded = try await Self.runCancelableDetached { () -> InteractivePreviewState in
                    try Self.loadExpandedInteractiveState(
                        fileURL: fileURL,
                        options: options,
                        maxDimension: maxDimension,
                        windowBounds: windowBounds,
                        segmentationLut: segmentationLut
                    )
                }
                guard !Task.isCancelled else { return }
                self.expansionTask = nil
                self.interactiveState = expanded
                self.lastAppliedAutoBounds = expanded.segmentationLut == nil ? expanded.windowBounds : nil
                // t>0 windows memoized against the capped buffer (zero backstop)
                // are stale now that the real volumes are present.
                self.perVolumeWindowCache = [:]
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
        guard let interactiveState else { return }
        // Drag starts from the window currently on screen: in per-volume mode
        // that's the displayed volume's own window (lastAppliedAutoBounds), not
        // volume 0's. `nil` only when there is no window at all (RGB-only).
        guard let initialBounds = lastAppliedAutoBounds ?? interactiveState.windowBounds else { return }

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

    /// Whether the live voxel-value line should occupy a slot in the metadata
    /// panel. Tracks crosshair visibility exactly (`crosshairPoint` is gated the
    /// same way): absent on the cold/first-frame preview, present once the user
    /// has interacted. Used by the view to insert/remove the value line — a
    /// one-time structural change, not a per-frame one.
    var showsVoxelValue: Bool {
        guard hasInteracted, let interactiveState else { return false }
        let dt = interactiveState.volume.image.header.datatype
        return dt != .rgb24 && dt != .rgba32
    }

    /// Formatted image intensity at the current crosshair voxel, for the live
    /// readout. Only meaningful while `showsVoxelValue`. Returns "—" when the
    /// value is unavailable — notably timepoints > 0 of a 4D `.nii.gz` whose
    /// full decompression hasn't landed yet (those read the zero backstop, which
    /// must not be shown as a real 0).
    var crosshairVoxelText: String? {
        guard showsVoxelValue, let interactiveState, let cursor = currentCursor else { return nil }
        if cursor.t > 0, !interactiveState.volume.containsAllVolumes { return "—" }
        let value = interactiveState.volume.voxel(x: cursor.x, y: cursor.y, z: cursor.z, t: cursor.t)
        return Self.formatVoxelValue(value)
    }

    /// Whole numbers (integer datatypes, identity-scaled data) render as plain
    /// integers; anything fractional (float data, or scl-scaled integers) uses a
    /// compact significant-digit form. Datatype-agnostic on purpose: the scaled
    /// value alone determines the most natural presentation.
    private static func formatVoxelValue(_ value: Float) -> String {
        guard value.isFinite else { return "—" }
        if value == value.rounded(), abs(value) < 1e7 {
            return String(Int(value))
        }
        return String(format: "%.6g", Double(value))
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
        lastAppliedAutoBounds = raw.interactiveState.segmentationLut == nil ? raw.interactiveState.windowBounds : nil
        // Fresh parse installs a new volume — drop any per-timepoint windows
        // memoized against the previous one (the reuse+cache-miss path reaches
        // here without load()'s clear having run).
        perVolumeWindowCache = [:]
        expansionState = Self.needsExpansion(volume: raw.interactiveState.volume) ? .pending : .notNeeded
        currentCursor = raw.interactiveState.centerCursor
        displayedCursor = raw.interactiveState.centerCursor
        metadataEntries = raw.metadataEntries
        coronalOrientation = raw.orientations[.coronal] ?? .placeholderCoronal
        sagittalOrientation = raw.orientations[.sagittal] ?? .placeholderSagittal
        axialOrientation = raw.orientations[.axial] ?? .placeholderAxial
        apply(bitmaps: raw.slices)
    }

    /// MainActor side of the render handoff: the bitmaps arrive pre-expanded
    /// from the detached task, so this only wraps them in CGImage/NSImage —
    /// no per-pixel work on the main thread.
    private func apply(bitmaps: [SlicePlane: RGBABitmap]) {
        if let coronalImage = bitmaps[.coronal].flatMap(MIQImageBridge.makeNSImage) {
            coronal = coronalImage
        }
        if let sagittalImage = bitmaps[.sagittal].flatMap(MIQImageBridge.makeNSImage) {
            sagittal = sagittalImage
        }
        if let axialImage = bitmaps[.axial].flatMap(MIQImageBridge.makeNSImage) {
            axial = axialImage
        }
    }

    private func makeBundle(from raw: RawPreviewData) -> MIQPreviewBundle {
        var nsSlices: [SlicePlane: NSImage] = [:]
        for plane in SlicePlane.allCases {
            if let bitmap = raw.slices[plane], let image = MIQImageBridge.makeNSImage(from: bitmap) {
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
                let interactiveState = try await Self.runCancelableDetached { () -> InteractivePreviewState in
                    try Self.loadInteractiveState(fileURL: fileURL, options: options, maxDimension: maxDimension)
                }
                guard !Task.isCancelled else { return }
                self.interactionPreparationTask = nil
                self.interactiveState = interactiveState
                self.lastAppliedAutoBounds = interactiveState.segmentationLut == nil ? interactiveState.windowBounds : nil
                self.perVolumeWindowCache = [:]
                self.expansionState = Self.needsExpansion(volume: interactiveState.volume) ? .pending : .notNeeded
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
        guard !planesToRender.isEmpty else {
            self.displayedCursor = cursor
            renderTask = nil
            startNextRenderIfNeeded()
            return
        }

        // A manual W/L adjustment is sticky across all volumes (it overrides
        // per-volume auto entirely). Otherwise the auto window is resolved per
        // volume off the MainActor inside the detached task below.
        let manualBounds = windowAdjustment
        let perVolume = perVolumeWindow
        // Memoized per-volume window: when we've already derived this timepoint's
        // auto window, hand it to the task so it skips the 3-center-slice decode.
        let cachedAutoBounds = (manualBounds == nil && perVolume) ? perVolumeWindowCache[cursor.t] : nil

        renderTask = Task { [weak self] in
            guard let self else { return }
            let result = await Task.detached(priority: .userInitiated) {
                Self.renderBitmaps(
                    cursor: cursor,
                    planes: planesToRender,
                    interactiveState: interactiveState,
                    manual: manualBounds,
                    perVolume: perVolume,
                    cached: cachedAutoBounds
                )
            }.value
            guard !Task.isCancelled else { return }
            self.apply(bitmaps: result.bitmaps)
            // Remember the auto window so a subsequent W/L drag starts from it,
            // and memoize it per timepoint for per-volume mode.
            if manualBounds == nil {
                self.lastAppliedAutoBounds = result.bounds
                if perVolume, let bounds = result.bounds {
                    self.perVolumeWindowCache[cursor.t] = bounds
                }
            }
            self.displayedCursor = cursor
            self.onChange?()
            self.renderTask = nil
            self.startNextRenderIfNeeded()
        }
    }

    /// Runs `work` off the MainActor on a detached task but propagates *this*
    /// task's cancellation into it. A bare `Task.detached(...).value` would keep
    /// running after the awaiting task is cancelled (detached tasks don't inherit
    /// cancellation), so a dismissed/replaced preview couldn't stop an in-flight
    /// parse — notably the full network read for non-boundable kinds (`.mif.gz`).
    private static func runCancelableDetached<T: Sendable>(
        _ work: @Sendable @escaping () throws -> T
    ) async throws -> T {
        let task = Task.detached(priority: .userInitiated, operation: work)
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// On a network volume, the on-disk size (bytes) at which a non-boundable
    /// kind's cold preview should be deferred behind a placeholder rather than
    /// pulling the whole file (which would stall Finder's I/O on a slow mount).
    /// `nil` ⇒ load normally (local disk, canonical NIfTI, or under threshold).
    /// Runs inside the detached task: `VolumeLocation.isLocal` (statfs) and the
    /// size stat can block on a hung mount, so they stay off the MainActor.
    private nonisolated static func networkDeferralSizeBytes(fileURL: URL, kind: MIQFileKind?) -> Int? {
        guard let kind, !kind.supportsBoundedNetworkRead else { return nil }
        guard !VolumeLocation.isLocal(fileURL) else { return nil }
        guard let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > MIQConfig.networkPreviewThresholdBytes else { return nil }
        return size
    }

    private nonisolated static func loadPreviewData(
        fileURL: URL,
        options: RenderingOptions,
        maxDimension: Int
    ) throws -> RawPreviewData {
        try withSecurityScopedAccess(to: fileURL) {
            let image = try MIQParser().parse(url: fileURL)
            let volume = MIQVolume(image: image)
            MIQLogger.make(category: "model").notice("cold parse: \(volume.containsAllVolumes ? "full payload" : "volume-0 capped", privacy: .public), volumes=\(volume.volumes, privacy: .public), payload=\(image.payloadCount / 1024, privacy: .public)KB")
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
                segmentationLut: preview.segmentationLut,
                centerCursor: volume.centerCursor()
            )
            // Expand to RGBA here, inside the detached task — the MainActor
            // then only wraps the buffers in CGImage/NSImage.
            let slices = preview.slices.compactMapValues { $0.rgbaBitmap() }

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
        // Single decode of the 3 center slices yields both the LUT and the
        // window, instead of `buildSegmentationLut` + `fixedCenterWindow` each
        // decoding them. Shaves time-to-first-scroll on the cache-hit path.
        let center = volume.centerInteractiveState(options: options)
        return InteractivePreviewState(
            volume: volume,
            options: options,
            maxDimension: maxDimension,
            windowBounds: center.windowBounds,
            segmentationLut: center.segmentationLut,
            centerCursor: volume.centerCursor()
        )
    }

    /// Fully decompressed re-parse for 4D navigation. Reuses the volume-0
    /// `windowBounds` and `segmentationLut` from the capped state so rendering
    /// stays constant across the timeseries.
    private nonisolated static func loadExpandedInteractiveState(
        fileURL: URL,
        options: RenderingOptions,
        maxDimension: Int,
        windowBounds: MIQIntensityWindowBounds?,
        segmentationLut: SegmentationLut?
    ) throws -> InteractivePreviewState {
        try withSecurityScopedAccess(to: fileURL) {
            let image = try MIQParser().parse(url: fileURL, fullyDecompress: true)
            let volume = MIQVolume(image: image)
            return InteractivePreviewState(
                volume: volume,
                options: options,
                maxDimension: maxDimension,
                windowBounds: windowBounds,
                segmentationLut: segmentationLut,
                centerCursor: volume.centerCursor()
            )
        }
    }

    /// The window the render should use for `cursor`. A manual adjustment wins
    /// for every volume (sticky). Otherwise, in per-volume mode, re-derive the
    /// window from this volume's own pooled center slices (same mechanic as the
    /// cold preview, just for `cursor.t`); a single-volume file or a missing
    /// window falls back to the volume-0 bounds. Called only inside the detached
    /// render task — `fixedCenterWindow` decodes 3 center slices.
    private nonisolated static func renderBitmaps(
        cursor: MIQVolumeCursor,
        planes: [SlicePlane],
        interactiveState: InteractivePreviewState,
        manual: MIQIntensityWindowBounds?,
        perVolume: Bool,
        cached: MIQIntensityWindowBounds?
    ) -> (bounds: MIQIntensityWindowBounds?, bitmaps: [SlicePlane: RGBABitmap]) {
        let bounds = resolveWindowBounds(cursor: cursor, interactiveState: interactiveState, manual: manual, perVolume: perVolume, cached: cached)
        let slices = renderSlices(for: cursor, planes: planes, interactiveState: interactiveState, windowBounds: bounds)
        // RGBA expansion stays off the MainActor with the rest of the
        // pixel work; only CGImage/NSImage wrapping happens in apply.
        return (bounds, slices.compactMapValues { $0.rgbaBitmap() })
    }

    private nonisolated static func resolveWindowBounds(
        cursor: MIQVolumeCursor,
        interactiveState: InteractivePreviewState,
        manual: MIQIntensityWindowBounds?,
        perVolume: Bool,
        cached: MIQIntensityWindowBounds?
    ) -> MIQIntensityWindowBounds? {
        if let manual { return manual }
        guard perVolume, interactiveState.volume.volumes > 1 else {
            return interactiveState.windowBounds
        }
        // A memoized window for this timepoint skips the 3-center-slice decode.
        if let cached { return cached }
        return interactiveState.volume.fixedCenterWindow(volumeIndex: cursor.t, options: interactiveState.options)
            ?? interactiveState.windowBounds
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
                windowBounds: windowBounds,
                lut: interactiveState.segmentationLut
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
