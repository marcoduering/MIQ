import AppKit
import Foundation
import OSLog
import QuickLook
import QuickLookUI
import MIQCore

final class MIQPreviewController: NSViewController, QLPreviewingController {
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
            case .ready, .deferred:
                logger.notice("same URL requested with ready/deferred model; reusing existing preview")
                previewView?.update(from: model)
                return
            case .idle, .failed:
                break
            }
        }

        currentURL = url

        guard previewView != nil else {
            logger.error("preview root view missing")
            return
        }
        logger.notice("using persistent AppKit preview root view")

        let model = MIQPreviewModel(url: url)
        model.onChange = { [weak self, weak model] in
            guard let self, let model else { return }
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
            case .idle, .loading, .failed: shouldFlushDisplay = false
            }
            self.refreshPreviewView(from: model, flushDisplay: shouldFlushDisplay)
        }
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

        loadingIndicatorTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.previewView?.showLoading()
        }

        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            logger.notice("starting async model load (forceFullRead=\(forceFullRead, privacy: .public))")
            await model.load(forceFullRead: forceFullRead)
            self.loadingIndicatorTask?.cancel()
            guard !Task.isCancelled else {
                self.logger.notice("load task canceled before UI update")
                return
            }
            self.refreshPreviewView(from: model, flushDisplay: false)
            logger.notice("async model load finished")
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
