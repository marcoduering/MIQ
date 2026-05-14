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
    private var pendingActivationBeforeModel = false

    override var preferredContentSize: NSSize {
        get { NSSize(width: 700, height: 600) }
        set { }
    }

    override func loadView() {
        let root = MIQPreviewAppKitView(frame: NSRect(x: 0, y: 0, width: 700, height: 600))
        root.onSliceActivate = { [weak self] _ in
            guard let self else { return }
            if let model = self.model {
                model.toggleInteractionMode()
            } else {
                // Click landed before the model was created (Quick Look's view
                // is shown before preparePreviewOfFile schedules the load).
                // Remember the intent so it can be honored once the model exists.
                self.pendingActivationBeforeModel = true
            }
        }
        root.onSliceScroll = { [weak self] plane, step in
            self?.model?.stepSlice(plane: plane, deltaSteps: step)
        }
        root.onSliceCursorPosition = { [weak self] plane, point in
            self?.model?.updateCursor(plane: plane, normalizedPoint: point)
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
            case .ready:
                logger.notice("same URL requested with ready model; reusing existing preview")
                previewView?.update(from: model)
                return
            case .idle, .failed:
                break
            }
        }

        currentURL = url

        loadTask?.cancel()
        loadingIndicatorTask?.cancel()
        guard previewView != nil else {
            logger.error("preview root view missing")
            return
        }
        previewView?.hideStatus()
        logger.notice("using persistent AppKit preview root view")

        let model = MIQPreviewModel(url: url)
        model.onChange = { [weak self, weak model] in
            guard let self, let model else { return }
            let shouldFlushDisplay: Bool
            switch model.state {
            case .ready:
                shouldFlushDisplay = true
            case .idle, .loading, .failed:
                shouldFlushDisplay = false
            }
            self.refreshPreviewView(from: model, flushDisplay: shouldFlushDisplay)
        }
        self.model = model

        if pendingActivationBeforeModel {
            pendingActivationBeforeModel = false
            model.toggleInteractionMode()
        }

        loadingIndicatorTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.previewView?.showLoading()
        }

        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            logger.notice("starting async model load")
            await model.load()
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
