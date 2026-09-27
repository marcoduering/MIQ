import Foundation

/// A preview whose read `NetworkReadLane` dropped for a newer file's.
@MainActor
protocol NetworkReadRetrying: AnyObject {
    /// The file whose read was superseded.
    var retryURL: URL? { get }
    /// Still on screen, with its load still superseded.
    var wantsNetworkReadRetry: Bool { get }
    /// Starts the load again (as the lane's newest request).
    func retryNetworkRead()
}

/// Serializes the reads of file data on network volumes across every preview in
/// this extension process, putting Finder navigation first: only the newest
/// request reads, and only once the user has paused on it.
///
/// On a slow share (measured over VPN: ~25 MB/s) every MB MIQ pulls delays
/// Finder's own requests on the same mount, which is what stops the selection
/// from advancing while the user arrows through a folder. Quick Look also gives
/// no reliable "the user left this preview" signal (two or three hosts preview
/// at once, one lagging behind; a left-behind controller is released 0.5–1.5 s
/// late), so the lane doesn't try to tell which previews still matter:
///
/// - A request for a new file supersedes every request for other files: a read in
///   progress stops at its next chunk. This happens as soon as a preview asks for
///   a file (`requestStarted(for:)`), before its stat/locality probe — that probe
///   queued 2.75 s behind a 755 MB read in flight, which ran on unhindered and
///   left Quick Look's pane empty meanwhile. Requests for the same file never
///   supersede each other: the Finder pane and the Space panel each ask for it.
///   The superseded caller gets `Superseded`. A superseded preview that is still
///   on screen — Quick Look can show two, one lagging behind the other — parks
///   itself (`parkForRetry`) and is retried once the link has been quiet for
///   `quietDelay`, one at a time, newest first. Off-screen ones are never retried
///   from here; coming back into view restarts them.
/// - While the user is navigating — another request arrived within
///   `navigationWindow` — a request waits `dwell` before touching the link, so
///   arrowing through files starts no reads (measured: half of all files are left
///   within 200 ms while arrowing). After a pause it reads at once: a burst of
///   arrowing costs at most one stopped read, its first file's.
/// - At most one read runs at a time: a request also waits for a superseded read
///   to finish unwinding.
/// - The lane covers the read only: the parser reports when the bytes are in
///   (`MIQParser.onNetworkReadFinished`), after which the decompress/decode phase
///   is no longer interrupted — a finished read is never thrown away.
///
/// Local files never come here: they are memory-mapped and don't contend for a link.
@MainActor
final class NetworkReadLane {
    static let shared = NetworkReadLane()

    /// Thrown to a request that a newer one replaced before it finished reading.
    struct Superseded: Error {}

    /// How long a request waits for the user to stay on a file before reading,
    /// while navigating. Under the 300 ms after which the preview shows "Loading…".
    private static let dwell: Duration = .milliseconds(200)
    /// A request within this long of the previous one means the user is
    /// navigating (measured: 90% of file-to-file moves while arrowing were under
    /// 920 ms).
    private static let navigationWindow: TimeInterval = 1.0
    /// How long the link must stay unused before a parked preview is retried —
    /// longer than `dwell`, so it never cuts into active browsing.
    private static let quietDelay: Duration = .milliseconds(500)

    private let logger = MIQLogger.make(category: "lane")

    // MainActor-isolated (so Sendable): the cancellation handler and the parser's
    // read-finished callback capture it from other threads.
    @MainActor
    private final class Ticket {
        let label: String
        let url: URL
        var superseded = false
        var readFinished = false
        /// Set while the work runs.
        var cancelWork: (() -> Void)?

        init(label: String, url: URL) {
            self.label = label
            self.url = url
        }
    }

    /// The request whose work is running (possibly a superseded one unwinding).
    private var holder: Ticket?
    /// Requests waiting for `holder` to finish.
    private var holderWaiters: [CheckedContinuation<Void, Never>] = []
    private var pending: [Ticket] = []

    private struct Parked {
        weak var preview: NetworkReadRetrying?
    }
    /// Oldest first.
    private var parked: [Parked] = []
    private var quietTask: Task<Void, Never>?
    private var lastRequestAt: Date?

    /// A preview asked for `url`, i.e. the user moved to it: stops the reads of
    /// every other file right away and restarts the quiet timer. Returns whether
    /// the user is navigating — another file was requested within
    /// `navigationWindow` — which decides whether this file's read waits `dwell`.
    /// Called for every request, local or network: its locality isn't known yet,
    /// and moving to a local file is moving on all the same.
    func requestStarted(for url: URL) -> Bool {
        let now = Date()
        let navigating = lastRequestAt.map { now.timeIntervalSince($0) < Self.navigationWindow } ?? false
        lastRequestAt = now
        for ticket in pending where ticket.url != url {
            supersede(ticket)
        }
        pending.removeAll { $0.url != url }
        // Restart the quiet timer rather than only cancelling it: a request that
        // never reaches `run` (a cache hit, a local file) must not strand the
        // parked previews. One that does reach `run` cancels it there.
        quietTask?.cancel()
        quietTask = nil
        scheduleRetryWhenQuiet()
        return navigating
    }

    /// Runs `work` on a detached task once no other read is running (after
    /// `dwell` when `navigating`). `work` receives the callback to hand
    /// to `MIQParser(onNetworkReadFinished:)`. Throws `Superseded` if a newer
    /// request replaced this one, `CancellationError` if the caller was cancelled.
    func run<T: Sendable>(
        _ label: String,
        url: URL,
        navigating: Bool,
        _ work: @Sendable @escaping (_ readFinished: @escaping @Sendable () -> Void) throws -> T
    ) async throws -> T {
        let ticket = Ticket(label: label, url: url)
        let now = Date()
        for other in pending where other.url != url { supersede(other) }
        pending.removeAll { $0.url != url }
        pending.append(ticket)
        quietTask?.cancel()
        quietTask = nil
        defer {
            pending.removeAll { $0 === ticket }
            scheduleRetryWhenQuiet()
        }

        let readFinished: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.markReadFinished(ticket) }
        }
        return try await withTaskCancellationHandler {
            if navigating { try await Task.sleep(for: Self.dwell) }
            while holder != nil, !ticket.superseded {
                await withCheckedContinuation { holderWaiters.append($0) }
            }
            try Task.checkCancellation()
            guard !ticket.superseded else {
                logger.notice("\(ticket.label, privacy: .public): superseded before reading")
                throw Superseded()
            }

            holder = ticket
            let start = Date()
            logger.notice("\(ticket.label, privacy: .public): reading after \(Self.ms(since: now), privacy: .public) ms")
            let task = Task.detached(priority: .userInitiated) { try work(readFinished) }
            ticket.cancelWork = { task.cancel() }
            // Cancelled or superseded between the checks above and now: the
            // handlers found no work to cancel.
            if Task.isCancelled || ticket.superseded { task.cancel() }
            let result = await task.result
            ticket.cancelWork = nil
            release(ticket)

            switch result {
            case .success(let value):
                logger.notice("\(ticket.label, privacy: .public): done in \(Self.ms(since: start), privacy: .public) ms")
                return value
            case .failure(let error):
                if error is CancellationError, ticket.superseded, !Task.isCancelled {
                    logger.notice("\(ticket.label, privacy: .public): superseded after \(Self.ms(since: start), privacy: .public) ms of reading")
                    throw Superseded()
                }
                throw error
            }
        } onCancel: {
            Task { @MainActor in ticket.cancelWork?() }
        }
    }

    private func supersede(_ ticket: Ticket) {
        // Past its read: decompressing and decoding no longer touch the link.
        guard !ticket.readFinished else { return }
        ticket.superseded = true
        ticket.cancelWork?()
        // Wake it if it is waiting for the holder, so it can report `Superseded`.
        let waiters = holderWaiters
        holderWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    /// Frees the lane; waiters re-check whether it is their turn.
    private func release(_ ticket: Ticket) {
        guard holder === ticket else { return }
        holder = nil
        let waiters = holderWaiters
        holderWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private func markReadFinished(_ ticket: Ticket) {
        guard !ticket.superseded else { return }
        ticket.readFinished = true
        release(ticket)
        scheduleRetryWhenQuiet()
    }

    /// `url` was just read and its preview cached: every parked preview of that
    /// file is retried now — a cache hit, no read. Otherwise one would wait its
    /// turn behind other retries (measured: a black `FLAIR_5` for 27 s, behind a
    /// 641 MB retry, although the Space panel had loaded it in 1.1 s).
    func fileLoaded(_ url: URL) {
        let same = parked.compactMap(\.preview).filter { $0.retryURL == url }
        parked.removeAll { $0.preview == nil || $0.preview?.retryURL == url }
        for preview in same where preview.wantsNetworkReadRetry {
            preview.retryNetworkRead()
        }
    }

    /// Retries `preview` once the link has been quiet for `quietDelay`, if it is
    /// still on screen and superseded then.
    func parkForRetry(_ preview: NetworkReadRetrying) {
        parked.removeAll { $0.preview == nil || $0.preview === preview }
        parked.append(Parked(preview: preview))
        scheduleRetryWhenQuiet()
    }

    private func scheduleRetryWhenQuiet() {
        guard pending.isEmpty, holder == nil, quietTask == nil, !parked.isEmpty else { return }
        quietTask = Task { [weak self] in
            try? await Task.sleep(for: Self.quietDelay)
            guard !Task.isCancelled, let self else { return }
            self.quietTask = nil
            self.retryNewestParked()
        }
    }

    private func retryNewestParked() {
        guard pending.isEmpty, holder == nil else { return }
        while let entry = parked.popLast() {
            guard let preview = entry.preview else { continue }
            if preview.wantsNetworkReadRetry {
                preview.retryNetworkRead()
                return
            }
            // Off screen or no longer superseded: nothing to retry.
        }
    }

    private static func ms(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }
}
