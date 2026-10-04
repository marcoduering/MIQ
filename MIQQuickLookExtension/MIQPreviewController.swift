import AppKit
import Foundation
import OSLog
import QuickLook
import QuickLookUI
import MIQCore

final class MIQPreviewController: NSViewController, QLPreviewingController, NetworkReadClient {
    private let logger = MIQLogger.make(category: "preview")
    private var previewView: MIQPreviewAppKitView?
    private var model: MIQPreviewModel?
    private var loadTask: Task<Void, Never>?
    private var loadingIndicatorTask: Task<Void, Never>?
    private var currentURL: URL?
    private var automaticTerminationDisabled = false

    override var preferredContentSize: NSSize {
        get { NSSize(width: 700, height: 600) }
        set { /* read-only override; caller uses preferredContentSize getter only */ }
    }

    override func loadView() {
        let root = MIQPreviewAppKitView(frame: NSRect(x: 0, y: 0, width: 700, height: 600))
        root.onSliceScrollGestureBegan = { [weak self] in
            self?.model?.scrollGestureBegan()
        }
        root.onSliceScroll = { [weak self] plane, step in
            self?.model?.stepSlice(plane: plane, deltaSteps: step)
        }
        root.onSliceVolumeScroll = { [weak self] step in
            self?.model?.stepVolume(deltaSteps: step)
        }
        root.onVolumeSeek = { [weak self] index in
            self?.model?.setVolume(to: index)
        }
        root.onSliceCursorPosition = { [weak self] plane, point in
            self?.model?.updateCursor(plane: plane, normalizedPoint: point)
        }
        root.onSliceWindowAdjust = { [weak self] deltaX, deltaY in
            self?.model?.adjustWindow(deltaX: deltaX, deltaY: deltaY)
        }
        root.onLoadAnyway = { [weak self] in
            // The "Load preview" button on the deferred-network placeholder:
            // re-run the load with the gate bypassed so the full read proceeds.
            self?.beginLoad(forceFullRead: true)
        }
        self.previewView = root
        self.view = root
    }

    /// Between `viewWillAppear` and `viewDidDisappear`. Quick Look can show two
    /// previews at once (the Space panel and the Finder pane, one lagging behind
    /// the other); `NetworkReadLane` never drops the read of a file on screen.
    private var isOnScreen = false
    /// Set by `viewDidDisappear`, cleared by a new request or reappearing: until
    /// then the preview still wants its file, even before it first appears.
    private var hasDisappeared = false

    var readURL: URL? { currentURL }
    var isShown: Bool { isOnScreen }
    var wantsRead: Bool { !hasDisappeared }

    override func viewWillAppear() {
        super.viewWillAppear()
        isOnScreen = true
        hasDisappeared = false
        NetworkReadLane.shared.clientVisibilityChanged(self)
        // Its read was dropped while it was off screen: load again.
        if model?.loadSuperseded == true {
            logger.notice("reloading dropped preview")
            beginLoad(forceFullRead: false)
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        isOnScreen = false
        hasDisappeared = true
        NetworkReadLane.shared.clientVisibilityChanged(self)
    }

    nonisolated func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        nonisolated(unsafe) let completion = handler
        logger.notice("preparePreviewOfFile called for: \(url.path, privacy: .public)")

        guard MIQFileKind(url: url) != nil else {
            logger.notice("declining unsupported preview file: \(url.path, privacy: .public)")
            completion(MIQError.unsupportedFileFormat)
            return
        }

        Task { @MainActor [weak self] in
            self?.prepareAndStartLoading(url: url)
        }
        logger.notice("preparePreviewOfFile completion returned")
        completion(nil)
    }

    @MainActor
    private func prepareAndStartLoading(url: URL) {
        if !automaticTerminationDisabled {
            ProcessInfo.processInfo.disableAutomaticTermination("Quick Look preview active")
            automaticTerminationDisabled = true
            logger.notice("automatic termination disabled")
        }

        if currentURL == url, let model {
            switch model.state {
            case .loading:
                logger.notice("same URL requested while load is in progress; reusing existing model")
                return
            case .ready, .deferred, .noFiniteVoxels:
                logger.notice("same URL requested with ready/deferred model; reusing existing preview")
                previewView?.update(from: model)
                return
            case .idle, .failed:
                break
            }
        }

        currentURL = url
        hasDisappeared = false

        guard previewView != nil else {
            logger.error("preview root view missing")
            return
        }
        logger.notice("using persistent AppKit preview root view")

        let model = MIQPreviewModel(url: url)
        model.onChange = { [weak self, weak model] in
            // Identity check, not just liveness: Quick Look reuses this controller
            // for a new URL, and cancelling the previous `loadTask` does not stop a
            // local mmap parse already running inside `runCancelableDetached` (only
            // the chunked network reads poll cancellation). That parse still reaches
            // `state = .ready; onChange?()`, so without this guard the old file's
            // slices would land in the window now showing the new one.
            guard let self, let model, self.model === model else { return }
            // Force a synchronous flush only for the initial display so QuickLook
            // sees the first frame quickly. Once the user has started interacting
            // the flush becomes a bottleneck: it blocks the main thread on every
            // onChange (twice per scroll step), starving scroll event processing.
            // AppKit's normal display cycle (needsDisplay = true) is sufficient
            // during interaction — updates land within one frame (~16 ms).
            let shouldFlushDisplay: Bool
            switch model.state {
            case .ready: shouldFlushDisplay = !model.hasInteracted
            case .deferred: shouldFlushDisplay = true  // show the placeholder promptly
            case .noFiniteVoxels: shouldFlushDisplay = true  // likewise: the message is the first frame
            case .idle, .loading, .failed: shouldFlushDisplay = false
            }
            self.refreshPreviewView(from: model, flushDisplay: shouldFlushDisplay)
        }
        // Defensive: Quick Look has so far always used a fresh controller per file,
        // but if it ever reuses this one, don't leave the old model's work running.
        self.model?.cancelInFlightWork()
        self.model = model

        beginLoad(forceFullRead: false)
    }

    /// Starts (or restarts) the async model load with its delayed loading
    /// indicator. Reused by the cold path and by the deferred-network
    /// placeholder's "Load preview" button (`forceFullRead: true`).
    @MainActor
    private func beginLoad(forceFullRead: Bool) {
        guard let model else { return }
        loadTask?.cancel()
        loadingIndicatorTask?.cancel()
        previewView?.hideStatus()
        let started = Date()
        // Before the model's probe: the lane stops other files' reads now, or the
        // probe's stat queues behind them on the share.
        let navigating = currentURL.map { NetworkReadLane.shared.requestStarted(for: $0, client: self) } ?? false

        loadingIndicatorTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.previewView?.showLoading()
        }

        // `self` stays weak across the await: holding the controller for the whole
        // load kept `deinit` (which cancels this task) from running when Quick Look
        // dismissed the preview mid-load, so a dismissed network read ran on.
        loadTask = Task { @MainActor [weak self, logger] in
            logger.notice("starting async model load (forceFullRead=\(forceFullRead, privacy: .public))")
            await model.load(forceFullRead: forceFullRead, navigating: navigating)
            guard let self else { return }
            self.loadingIndicatorTask?.cancel()
            guard !Task.isCancelled, self.model === model else {
                logger.notice("load task canceled or superseded before UI update")
                return
            }
            self.refreshPreviewView(from: model, flushDisplay: false)
            let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
            logger.notice("async model load finished in \(elapsedMs, privacy: .public) ms, state=\(String(describing: model.state), privacy: .public)")
        }
    }

    @MainActor
    private func refreshPreviewView(from model: MIQPreviewModel, flushDisplay: Bool) {
        previewView?.update(from: model)
        guard flushDisplay, let previewView else { return }
        previewView.layoutSubtreeIfNeeded()
        previewView.displayIfNeeded()
        previewView.window?.displayIfNeeded()
    }

    deinit {
        loadTask?.cancel()
        loadingIndicatorTask?.cancel()
        if automaticTerminationDisabled {
            ProcessInfo.processInfo.enableAutomaticTermination("Quick Look preview active")
        }
    }
}
