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
        /// A well-formed scalar volume with no finite voxel in volume 0.
        /// Not `.failed` — nothing went wrong, there is just nothing to render, and
        /// the resulting black grid is otherwise indistinguishable from a bug.
        case noFiniteVoxels
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
    private var interactiveState: InteractivePreviewState? {
        didSet { interactiveStateGeneration &+= 1 }
    }
    /// Bumped on every `interactiveState` swap (fresh parse, cache-hit prep, 4D
    /// expansion). A render captures it at start; if it changed by completion,
    /// the render's auto window was derived from a buffer that's no longer
    /// current (e.g. the volume-0-capped one) and must not be remembered.
    private var interactiveStateGeneration = 0
    /// Set on a cache hit for a file the large-network gate would defer: the
    /// cached frame is shown, but the full read waits for the first interaction.
    private var interactivePreparationDeferred = false
    /// Volume count from a cache hit's bundle, until the interactive state lands.
    private var cachedVolumeCount: Int?
    private var expansionState: ExpansionState = .notNeeded
    private var expansionTask: Task<Void, Never>?
    /// The cold parse `load()` is awaiting. Owned by the model (not only by the
    /// controller's load task) so `deinit` can cancel it.
    private var coldLoadTask: Task<RawPreviewData, Error>?
    /// Whether this file is on a network volume, from `load()`'s probe. Its reads
    /// then go through `NetworkReadLane`.
    private var readsOverNetwork = false
    /// The last load's read was dropped because no preview wanted the file any
    /// more (`NetworkReadLane.Superseded`) — so this preview was off screen. The
    /// model is `.idle`; the controller reloads if it comes back into view.
    private(set) var loadSuperseded = false
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

    /// Reached only because no task below holds `self` across its `await`: each
    /// binds `self` strongly only *after* the detached work returns. A task that
    /// did `guard let self` up front would keep this model alive until its work
    /// finished, so this cancellation could never run while there was anything to
    /// cancel.
    deinit {
        coldLoadTask?.cancel()
        interactionPreparationTask?.cancel()
        renderTask?.cancel()
        expansionTask?.cancel()
    }

    /// Stops every in-flight background task: interactive-state prep, the 4D
    /// expansion re-parse, and the render queue — for a model being discarded.
    /// Used by `load()` to reset, and by the controller if it ever replaces its
    /// model. `runCancelableDetached` forwards the cancellation into the chunked
    /// network reads.
    func cancelInFlightWork() {
        coldLoadTask?.cancel()
        coldLoadTask = nil
        interactionPreparationTask?.cancel()
        interactionPreparationTask = nil
        renderTask?.cancel()
        renderTask = nil
        pendingRenderCursor = nil
        expansionTask?.cancel()
        expansionTask = nil
    }

    /// A 4D buffer that was loaded with the volume-0 cap (any `.nii.gz`, or a
    /// `.nii`/`.nii.gz` on a network volume via the bounded-prefix read) hides
    /// volumes > 0 until expanded. Detected from the actual payload rather than the
    /// file kind, so the bounded uncompressed `.nii` case isn't missed.
    private static func needsExpansion(volume: MIQVolume) -> Bool {
        volume.volumes > 1 && !volume.containsAllVolumes
    }

    /// - Parameters:
    ///   - forceFullRead: when `true` (the placeholder's "Load preview" button),
    ///     bypass the large-network-preview gate and parse normally. The default
    ///     cold load respects the gate.
    ///   - navigating: from `NetworkReadLane.requestStarted`, which the controller
    ///     calls before this: the user is moving through files, so a network read
    ///     waits briefly before starting.
    func load(forceFullRead: Bool = false, navigating: Bool = false) async {
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
        logger.notice("load() started for: \(fileURL.lastPathComponent, privacy: .public)")
        logger.notice("MIQConfig percentiles: lower=\(options.lowerPercentile, privacy: .public), upper=\(options.upperPercentile, privacy: .public), orientation=\(options.orientation.rawValue, privacy: .public), showAxisLabels=\(MIQConfig.showAxisLabels, privacy: .public)")

        // The controller creates one model per URL, and a second load() only comes
        // from the deferred placeholder, so there is never state worth keeping.
        cancelInFlightWork()
        loadSuperseded = false
        interactivePreparationDeferred = false
        renderingOptions = options
        interactiveState = nil
        cachedVolumeCount = nil
        expansionState = .notNeeded
        perVolumeWindowCache = [:]
        currentCursor = nil
        displayedCursor = nil
        hasInteracted = false
        windowAdjustment = nil
        pendingForceRender = false
        pendingRenderCursor = nil

        do {
            // The cache key stats the file (mtime) and the gate probes locality and
            // size; either can block on a hung network mount, so both run off the
            // MainActor. Only the String key and the size come back — cached
            // bundles hold NSImages, so the lookup itself stays on the MainActor.
            let probe = try await Self.runCancelableDetached { () -> (cacheKey: String, isLocal: Bool, deferralSizeBytes: Int?) in
                let cacheKey = MIQPreviewCache.makeKey(fileURL: fileURL, maxDimension: maxDimension, options: options)
                let isLocal = VolumeLocation.isLocal(fileURL)
                let deferralSizeBytes = applyNetworkGate && !isLocal ? Self.networkDeferralSizeBytes(fileURL: fileURL, kind: kind) : nil
                return (cacheKey, isLocal, deferralSizeBytes)
            }
            try Task.checkCancellation()
            readsOverNetwork = !probe.isLocal

            if let cached = MIQPreviewCache.bundle(for: probe.cacheKey) {
                apply(bundle: cached)
                state = .ready
                onChange?()
                if probe.deferralSizeBytes != nil {
                    // The gate would have deferred this file: show the cached frame
                    // but don't pull the whole file until the user interacts.
                    interactivePreparationDeferred = true
                    logger.notice("load() cache hit — interactive state deferred to first interaction (large network file)")
                } else {
                    // On a share this re-read goes through the lane like a cold
                    // load: it waits `dwell` while the user navigates and is
                    // stopped as soon as they move on, so revisiting cached files
                    // doesn't compete with Finder — but it is ready (or under way)
                    // by the time the user interacts.
                    logger.notice("load() cache hit — applying cached center preview, preparing interactive state")
                    prepareInteractiveState(fileURL: fileURL, options: options, navigating: navigating, claimsNewest: false)
                }
                return
            }

            if let sizeBytes = probe.deferralSizeBytes {
                state = .deferred(name: fileURL.lastPathComponent, sizeBytes: sizeBytes)
                logger.notice("load() deferred large network preview: \(sizeBytes / (1024 * 1024), privacy: .public)MB")
                onChange?()
                return
            }

            let overNetwork = readsOverNetwork
            let coldLoad = Task {
                try await Self.sharedColdLoad(key: probe.cacheKey) {
                    try await MIQPreviewModel.runRead(overNetwork: overNetwork, url: fileURL, navigating: navigating, claimsNewest: false, label: "load \(fileURL.lastPathComponent)") { parser in
                        try MIQPreviewModel.loadPreviewData(parser: parser, fileURL: fileURL, options: options, maxDimension: maxDimension)
                    }
                }
            }
            coldLoadTask = coldLoad
            // An unstructured task doesn't inherit cancellation, so forward the
            // controller's (a dismissed preview) explicitly.
            let raw = try await withTaskCancellationHandler {
                try await coldLoad.value
            } onCancel: {
                coldLoad.cancel()
            }
            coldLoadTask = nil
            // Applied either way — metadata and orientation are valid even with
            // nothing to window.
            apply(raw: raw)
            if Self.hasNoFiniteVoxels(raw) {
                // Not cached: the cache short-circuit at the top of load() would
                // return `.ready` next time and drop the explanation.
                state = .noFiniteVoxels
                logger.notice("load() finished: volume has no finite voxel values")
            } else {
                MIQPreviewCache.insert(makeBundle(from: raw), for: probe.cacheKey)
                state = .ready
                logger.notice("load() finished successfully")
            }
            onChange?()
        } catch is NetworkReadLane.Superseded {
            state = .idle
            loadSuperseded = true
            logger.notice("load() dropped: no preview wants this file any more")
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

    /// The interactive state for an input event, or `nil` while it isn't ready
    /// (the event is dropped). If the large-network gate deferred preparation on
    /// a cache hit, this first interaction is what starts it.
    private func interactiveStateForInteraction() -> InteractivePreviewState? {
        if let interactiveState { return interactiveState }
        if interactivePreparationDeferred, let renderingOptions {
            interactivePreparationDeferred = false
            logger.notice("first interaction — preparing deferred interactive state")
            prepareInteractiveState(fileURL: url, options: renderingOptions)
        }
        return nil
    }

    func scrollGestureBegan() {
        _ = interactiveStateForInteraction()
        // The in-flight render may have been a forced full render (after W/L or
        // the 4D expansion swap) whose `pendingForceRender` was already consumed.
        // Cancelled, it never repaints, so the diff against `displayedCursor`
        // would skip planes that are stale — re-arm the force so the next render
        // repaints all three.
        if let renderTask {
            renderTask.cancel()
            pendingForceRender = true
        }
        renderTask = nil
        pendingRenderCursor = nil
        // A new gesture earns one more expansion attempt after a prior failure.
        if expansionState == .failed { expansionState = .pending }
    }

    func stepSlice(plane: SlicePlane, deltaSteps: Int) {
        guard deltaSteps != 0, let interactiveState = interactiveStateForInteraction() else { return }
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
        guard deltaSteps != 0, let interactiveState = interactiveStateForInteraction() else { return }
        let volumes = interactiveState.volume.volumes
        guard volumes > 1 else { return }
        let cursor = currentCursor ?? interactiveState.centerCursor
        applyVolume(cursor.t + deltaSteps, interactiveState: interactiveState)
    }

    /// Absolute timepoint seek (the metadata scrubber). Same path as
    /// `stepVolume`; clamps into range and is a no-op for 3D files.
    func setVolume(to index: Int) {
        guard let interactiveState = interactiveStateForInteraction(), interactiveState.volume.volumes > 1 else { return }
        applyVolume(index, interactiveState: interactiveState)
    }

    /// Total number of volumes along the 4th axis (1 for 3D).
    var volumeCount: Int { interactiveState?.volume.volumes ?? cachedVolumeCount ?? 1 }

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

    /// What the Volumes line says about the lazy 4D expansion: nothing, a
    /// "decompressing" affordance while it runs, or that it failed — without the
    /// last, volumes > 0 render the zero backstop with no explanation.
    enum VolumeExpansionStatus {
        case idle
        case expanding
        case failed
    }

    var volumeExpansionStatus: VolumeExpansionStatus {
        switch expansionState {
        case .expanding: return .expanding
        case .failed: return .failed
        case .notNeeded, .pending, .expanded: return .idle
        }
    }

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
        let overNetwork = readsOverNetwork

        // `self` stays weak across the await (see deinit) and the statics are named
        // by type, not `Self`, so nothing in the closure retains the model.
        expansionTask = Task { [weak self] in
            do {
                let expanded = try await MIQPreviewModel.runRead(overNetwork: overNetwork, url: fileURL, navigating: false, claimsNewest: true, label: "expand \(fileURL.lastPathComponent)") { parser in
                    try MIQPreviewModel.loadExpandedInteractiveState(
                        parser: parser,
                        fileURL: fileURL,
                        options: options,
                        maxDimension: maxDimension,
                        windowBounds: windowBounds,
                        segmentationLut: segmentationLut
                    )
                }
                guard let self, !Task.isCancelled else { return }
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
            } catch is NetworkReadLane.Superseded {
                // Another file took the link; the next 4D step retries.
                guard let self, !Task.isCancelled else { return }
                self.expansionTask = nil
                self.expansionState = .pending
                self.onChange?()
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.expansionTask = nil
                // `.failed` (not `.notNeeded`): no retry on every subsequent
                // step within this gesture (no storm), but `scrollGestureBegan`
                // resets it to `.pending` so the *next* gesture retries — a
                // transient failure (I/O, security scope) isn't permanent.
                // Volumes > 0 keep the zero backstop; volume 0 stays correct.
                self.expansionState = .failed
                self.logger.error("4D expansion failed: \(error.localizedDescription, privacy: .public)")
                // Repaint so the Volumes line drops "decompressing…" and says so.
                self.onChange?()
            }
        }
    }

    func updateCursor(plane: SlicePlane, normalizedPoint: MIQNormalizedPoint) {
        guard let interactiveState = interactiveStateForInteraction() else { return }
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
        guard let interactiveState = interactiveStateForInteraction() else { return }
        // Drag starts from the window currently on screen: in per-volume mode
        // that's the displayed volume's own window (lastAppliedAutoBounds), not
        // volume 0's. `nil` only when there is no window at all (RGB-only).
        guard let initialBounds = lastAppliedAutoBounds ?? interactiveState.windowBounds else { return }

        let current = windowAdjustment ?? initialBounds
        // Relative, not absolute: data with tiny values (~1e-9) must stay
        // adjustable. A zero-width window (only left for a constant volume, since
        // `MIQVolume` widens a mask's window over the whole volume) scales the drag
        // by the value's own magnitude instead, or 1 for an all-zero volume.
        let span = initialBounds.high - initialBounds.low
        let magnitude = abs(initialBounds.low)
        let initialRange = span > 0 ? span : (magnitude > 0 ? magnitude : 1)
        let sensitivity = initialRange * 0.005
        let minWidth = initialRange * 0.01

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
        return MetadataPanelText.formatVoxelValue(value)
    }

    /// Whole numbers (integer datatypes, identity-scaled data) render as plain
    /// integers; anything fractional (float data, or scl-scaled integers) uses a
    /// compact significant-digit form. Datatype-agnostic on purpose: the scaled
    /// value alone determines the most natural presentation.
    ///
    /// Non-finite voxels print literally rather than as "—". NaN is real data here
    /// (parametric and statistical maps spell "not computed" with it) and windowing
    /// draws it at the window minimum, indistinguishable from background — so this
    /// readout is the only place it shows, and "—" means "no value available".
    private func apply(bundle: MIQPreviewBundle) {
        coronal = bundle.slices[.coronal]
        sagittal = bundle.slices[.sagittal]
        axial = bundle.slices[.axial]
        coronalOrientation = bundle.orientations[.coronal] ?? .placeholderCoronal
        sagittalOrientation = bundle.orientations[.sagittal] ?? .placeholderSagittal
        axialOrientation = bundle.orientations[.axial] ?? .placeholderAxial
        metadataEntries = bundle.metadataEntries
        cachedVolumeCount = bundle.volumeCount
    }

    private func apply(raw: RawPreviewData) {
        interactiveState = raw.interactiveState
        lastAppliedAutoBounds = raw.interactiveState.segmentationLut == nil ? raw.interactiveState.windowBounds : nil
        // Fresh parse installs a new volume — drop any per-timepoint windows
        // memoized against the previous one.
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

    /// No window and no LUT to replace it ⇒ not one finite voxel in volume 0 (the
    /// window falls back to the whole volume when the center slices have none —
    /// see `MIQVolume.pooledBounds`). The RGB exclusion is load-bearing, not defensive: RGB planes
    /// contribute nothing to the pooled window by design, so every RGB volume
    /// reaches here with no bounds and would otherwise be declared empty.
    private static func hasNoFiniteVoxels(_ raw: RawPreviewData) -> Bool {
        let datatype = raw.interactiveState.volume.image.header.datatype
        guard datatype != .rgb24, datatype != .rgba32 else { return false }
        return raw.interactiveState.windowBounds == nil && raw.interactiveState.segmentationLut == nil
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
            metadataEntries: raw.metadataEntries,
            volumeCount: raw.interactiveState.volume.volumes
        )
    }

    /// - Parameters:
    ///   - navigating: see `load(navigating:)`; only for the cache-hit path.
    ///   - claimsNewest: `true` when an interaction asked for it (the user is on
    ///     this file); `false` right after a cache hit, where it is part of that
    ///     file's request, already registered.
    private func prepareInteractiveState(
        fileURL: URL,
        options: RenderingOptions,
        navigating: Bool = false,
        claimsNewest: Bool = true
    ) {
        let maxDimension = self.maxDimension
        let overNetwork = readsOverNetwork
        interactionPreparationTask?.cancel()
        // Weak across the await; see deinit.
        interactionPreparationTask = Task { [weak self] in
            do {
                let interactiveState = try await MIQPreviewModel.runRead(overNetwork: overNetwork, url: fileURL, navigating: navigating, claimsNewest: claimsNewest, label: "prepare \(fileURL.lastPathComponent)") { parser in
                    try MIQPreviewModel.loadInteractiveState(parser: parser, fileURL: fileURL, options: options, maxDimension: maxDimension)
                }
                guard let self, !Task.isCancelled else { return }
                self.interactionPreparationTask = nil
                self.interactiveState = interactiveState
                self.lastAppliedAutoBounds = interactiveState.segmentationLut == nil ? interactiveState.windowBounds : nil
                self.perVolumeWindowCache = [:]
                self.expansionState = Self.needsExpansion(volume: interactiveState.volume) ? .pending : .notNeeded
                self.currentCursor = interactiveState.centerCursor
                self.displayedCursor = interactiveState.centerCursor
                self.onChange?()
            } catch {
                // A cancelled task may already have been replaced; don't clear
                // its successor.
                guard let self, !Task.isCancelled, !(error is CancellationError) else { return }
                self.interactionPreparationTask = nil
                if error is NetworkReadLane.Superseded {
                    // Another file took the link; the next interaction retries.
                    self.interactivePreparationDeferred = true
                    return
                }
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
        let generation = interactiveStateGeneration

        // Weak across the await; see deinit.
        renderTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                MIQPreviewModel.renderBitmaps(
                    cursor: cursor,
                    planes: planesToRender,
                    interactiveState: interactiveState,
                    manual: manualBounds,
                    perVolume: perVolume,
                    cached: cachedAutoBounds
                )
            }.value
            guard let self, !Task.isCancelled else { return }
            self.apply(bitmaps: result.bitmaps)
            // Remember the auto window so a subsequent W/L drag starts from it,
            // and memoize it per timepoint for per-volume mode — unless the state
            // was swapped mid-render (4D expansion), which makes it stale.
            if manualBounds == nil, generation == self.interactiveStateGeneration {
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

    /// One cold parse in flight, shared by every preview that asks for the same
    /// cache key while it runs.
    @MainActor
    private final class SharedColdLoad {
        var task: Task<RawPreviewData, Error>!
        /// Previews still waiting. Only decremented on cancellation; a load that
        /// completes simply leaves the registry.
        var waiters = 0
    }

    private static var sharedColdLoads: [String: SharedColdLoad] = [:]

    /// Runs the cold parse for `key` once, however many previews ask for it while
    /// it runs. The Finder preview pane and the Space panel each create a
    /// controller for the same file; when the parse outlasts the gap between their
    /// requests (a network file, or a large `.mgz`/`.mif.gz`) both used to parse
    /// it — twice the bytes over the link, and twice the CPU and memory locally.
    /// A fast local load finishes first and the second preview hits the cache, so
    /// this changes nothing there.
    ///
    /// The shared task belongs to no single preview, so one leaving doesn't stop
    /// it for the others: a cancelled waiter just drops out, and only the last one
    /// out cancels the parse (which `runRead` forwards into the chunked network
    /// reads). A cancelled waiter still waits for the shared result
    /// before its `load()` returns; its caller has already been torn down.
    private static func sharedColdLoad(
        key: String,
        work: @escaping @MainActor () async throws -> RawPreviewData
    ) async throws -> RawPreviewData {
        let shared: SharedColdLoad
        if let existing = sharedColdLoads[key] {
            shared = existing
        } else {
            shared = SharedColdLoad()
            shared.task = Task { @MainActor in
                defer {
                    if MIQPreviewModel.sharedColdLoads[key] === shared {
                        MIQPreviewModel.sharedColdLoads[key] = nil
                    }
                }
                return try await work()
            }
            sharedColdLoads[key] = shared
        }
        shared.waiters += 1
        return try await withTaskCancellationHandler {
            try await shared.task.value
        } onCancel: {
            Task { @MainActor in
                shared.waiters -= 1
                guard shared.waiters == 0 else { return }
                // Unregister first so a new request starts a fresh parse instead
                // of joining the cancelled one.
                if MIQPreviewModel.sharedColdLoads[key] === shared {
                    MIQPreviewModel.sharedColdLoads[key] = nil
                }
                shared.task.cancel()
            }
        }
    }

    /// Runs a parse that reads `fileURL`'s data. On a network volume it goes through
    /// `NetworkReadLane` — one read at a time, the newest request first — and
    /// throws `NetworkReadLane.Superseded` if no preview wants the file any more;
    /// a local file is memory-mapped and runs straight away. `claimsNewest` is for
    /// work an interaction starts (4D expansion, cache-hit prep): it makes this
    /// file the newest request.
    private static func runRead<T: Sendable>(
        overNetwork: Bool,
        url: URL,
        navigating: Bool,
        claimsNewest: Bool,
        label: String,
        _ work: @Sendable @escaping (MIQParser) throws -> T
    ) async throws -> T {
        guard overNetwork else {
            return try await runCancelableDetached { try work(MIQParser()) }
        }
        return try await NetworkReadLane.shared.run(label, url: url, navigating: navigating, claimsNewest: claimsNewest) { readFinished in
            try work(MIQParser(onNetworkReadFinished: readFinished))
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
    /// `nil` ⇒ load normally (canonical NIfTI, or under threshold). The caller
    /// has already established that the file is on a network volume. Runs inside
    /// the detached task: the size stat can block on a hung mount.
    private nonisolated static func networkDeferralSizeBytes(fileURL: URL, kind: MIQFileKind?) -> Int? {
        guard let kind, !kind.supportsBoundedNetworkRead else { return nil }
        guard let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > MIQConfig.networkPreviewThresholdBytes else { return nil }
        return size
    }

    private nonisolated static func loadPreviewData(
        parser: MIQParser,
        fileURL: URL,
        options: RenderingOptions,
        maxDimension: Int
    ) throws -> RawPreviewData {
        try withSecurityScopedAccess(to: fileURL) {
            let image = try parser.parse(url: fileURL)
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
        parser: MIQParser,
        fileURL: URL,
        options: RenderingOptions,
        maxDimension: Int
    ) throws -> InteractivePreviewState {
        try withSecurityScopedAccess(to: fileURL) {
            let image = try parser.parse(url: fileURL)
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
        parser: MIQParser,
        fileURL: URL,
        options: RenderingOptions,
        maxDimension: Int,
        windowBounds: MIQIntensityWindowBounds?,
        segmentationLut: SegmentationLut?
    ) throws -> InteractivePreviewState {
        try withSecurityScopedAccess(to: fileURL) {
            let image = try parser.parse(url: fileURL, fullyDecompress: true)
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
        // Before 4D expansion, volumes > 0 read the zero backstop; a window
        // derived from zeros is degenerate, so keep volume 0's.
        if cursor.t > 0, !interactiveState.volume.containsAllVolumes {
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
        return MetadataEntry(field: .format, label: "Format", value: displayName)
    }

    #if DEBUG
    private nonisolated static func buildDateEntry() -> MetadataEntry? {
        guard let formatted = BuildDate.formatted(for: Bundle.main.executableURL) else { return nil }
        return MetadataEntry(field: nil, label: "DEBUG BUILD", value: formatted)
    }
    #endif
}
