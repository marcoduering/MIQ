import AppKit
import Foundation
import OSLog
import QuickLook
import QuickLookUI
import MIQCore

final class MIQPreviewController: NSViewController, QLPreviewingController {
    private let logger = MIQLogger.make(category: "preview")
    private var previewView: MIQPreviewAppKitView?
    private var loadTask: Task<Void, Never>?
    private var loadingIndicatorTask: Task<Void, Never>?
    private var currentURL: URL?
    private var automaticTerminationDisabled = false

    override var preferredContentSize: NSSize {
        get { NSSize(width: 700, height: 600) }
        set { }
    }

    override func loadView() {
        let root = MIQPreviewAppKitView(frame: NSRect(x: 0, y: 0, width: 700, height: 600))
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

        if currentURL == url {
            logger.notice("same URL requested again; keeping existing root view")
        } else {
            currentURL = url
        }

        loadTask?.cancel()
        loadingIndicatorTask?.cancel()
        guard previewView != nil else {
            logger.error("preview root view missing")
            return
        }
        logger.notice("using persistent AppKit preview root view")

        let model = MIQPreviewModel(url: url)

        loadingIndicatorTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
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
            self.previewView?.update(from: model)
            logger.notice("async model load finished")
        }
    }

    deinit {
        if automaticTerminationDisabled {
            ProcessInfo.processInfo.enableAutomaticTermination("Quick Look preview active")
        }
    }
}
