import Foundation

/// A preview as `NetworkReadLane` sees it.
@MainActor
protocol NetworkReadClient: AnyObject {
    /// The file the preview shows, or is about to show.
    var readURL: URL? { get }
    /// Between `viewWillAppear` and `viewDidDisappear`.
    var isShown: Bool { get }
    /// From the file's request until `viewDidDisappear`: the preview still wants
    /// its file (it may not have appeared yet).
    var wantsRead: Bool { get }
}

/// Serializes the reads of file data on network volumes across every preview in
/// this extension process. Its one hard rule: **a preview on screen never loses
/// its file.** Reads are held back, reordered or stopped and resumed — but only
/// a read no preview wants any more is ever dropped.
///
/// Why a lane at all: on a slow share (measured over VPN: ~25 MB/s) every MB MIQ
/// pulls delays Finder's own requests on the same mount; with several reads in
/// flight, or a large one running while the user moves on, the selection stops
/// advancing and Finder beachballs. Quick Look can show two previews at once
/// (the Space panel and the Finder preview pane, one lagging behind the other),
/// so "another file was requested" doesn't mean a preview left the screen —
/// dropping on that signal left previews black or stuck on "Loading…". The
/// rules:
///
/// - One read at a time.
/// - The newest request reads first. It is registered as soon as a preview asks
///   for a file (`requestStarted`), before the preview's stat/locality probe — a
///   probe once queued 2.75 s behind a 755 MB read in flight — and stops the read
///   in progress at its next chunk.
/// - A stopped read whose file a preview still wants (on screen, or requested and
///   not yet appeared) waits and resumes; one nobody wants is dropped
///   (`Superseded`). The preview that navigates always issues the newest
///   request, so the other one catches up afterwards, without the lane having to
///   tell the two apart.
/// - A read for a file on screen that isn't the newest request waits until no
///   request has arrived for `quietDelay`, so it never cuts into navigation.
///   Several such reads go newest first.
/// - While the user is navigating (another request within `navigationWindow`),
///   the newest request waits `dwell` before reading, so arrowing through files
///   starts no reads (measured: half of all files are left within 200 ms while
///   arrowing). After a pause it reads at once.
/// - The lane covers the read only: the parser reports when the bytes are in
///   (`MIQParser.onNetworkReadFinished`), after which decompressing and decoding
///   are never interrupted — a finished read is never thrown away.
///
/// Local files never come here: they are memory-mapped and don't contend for a link.
@MainActor
final class NetworkReadLane {
    static let shared = NetworkReadLane()

    /// Thrown to a request no preview wants any more. Its preview is off screen;
    /// if it comes back into view, it loads again.
    struct Superseded: Error {}

    /// How long the newest request waits for the user to stay on a file before
    /// reading, while navigating. Under the 300 ms after which the preview shows
    /// "Loading…".
    private static let dwell: Duration = .milliseconds(200)
    /// A request within this long of the previous one means the user is
    /// navigating (measured: 90% of file-to-file moves while arrowing were under
    /// 920 ms).
    private static let navigationWindow: TimeInterval = 1.0
    /// How long no request may arrive before an on-screen file that isn't the
    /// newest request reads — longer than `dwell`, so it never cuts into browsing.
    private static let quietDelay: TimeInterval = 0.5

    private let logger = MIQLogger.make(category: "lane")

    // MainActor-isolated (so Sendable): the cancellation handler and the parser's
    // read-finished callback capture it from other threads.
    @MainActor
    private final class Ticket {
        let label: String
        let url: URL
        /// Arrival order; higher is newer.
        let sequence: Int
        /// Dropped: no preview wants this file any more.
        var superseded = false
        /// Stopped for a newer request; waits for its turn again.
        var preempted = false
        var readFinished = false
        /// Set while the work runs.
        var cancelWork: (() -> Void)?

        init(label: String, url: URL, sequence: Int) {
            self.label = label
            self.url = url
            self.sequence = sequence
        }
    }

    private var newestURL: URL?
    private var lastRequestAt: Date?
    private var nextSequence = 0
    /// Every request waiting or running.
    private var tickets: [Ticket] = []
    /// The request whose read is running (possibly a stopped one unwinding).
    private var holder: Ticket?
    private var wakeups: [CheckedContinuation<Void, Never>] = []
    private var quietWake: Task<Void, Never>?
    /// Weak: a released preview wants nothing.
    private let clients = NSHashTable<AnyObject>.weakObjects()

    /// A preview asked for `url`. Makes it the newest request and stops whatever
    /// other read is in progress. Called before the preview's probe, for every
    /// request — its locality isn't known yet, and moving to a local file is
    /// moving on all the same. Returns whether the user is navigating, which
    /// decides whether this file's read waits `dwell`.
    func requestStarted(for url: URL, client: NetworkReadClient) -> Bool {
        let now = Date()
        let navigating = lastRequestAt.map { now.timeIntervalSince($0) < Self.navigationWindow } ?? false
        lastRequestAt = now
        newestURL = url
        clients.add(client)
        reevaluate(newRequest: true)
        return navigating
    }

    /// A preview appeared or disappeared: what is wanted may have changed.
    func clientVisibilityChanged(_ client: NetworkReadClient) {
        clients.add(client)
        reevaluate(newRequest: false)
    }

    /// Runs `work` on a detached task when it is this request's turn (after
    /// `dwell` when `navigating`). `claimsNewest` makes it the newest request —
    /// for work started by an interaction with the preview, not by a file
    /// request. `work` receives the callback to hand to
    /// `MIQParser(onNetworkReadFinished:)`. Throws `Superseded` if no preview
    /// wants the file any more, `CancellationError` if the caller was cancelled.
    func run<T: Sendable>(
        _ label: String,
        url: URL,
        navigating: Bool,
        claimsNewest: Bool,
        _ work: @Sendable @escaping (_ readFinished: @escaping @Sendable () -> Void) throws -> T
    ) async throws -> T {
        nextSequence += 1
        let ticket = Ticket(label: label, url: url, sequence: nextSequence)
        tickets.append(ticket)
        if claimsNewest {
            newestURL = url
            reevaluate(newRequest: true)
        }
        defer {
            tickets.removeAll { $0 === ticket }
            wakeAll()
        }
        let readFinished: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.markReadFinished(ticket) }
        }
        return try await withTaskCancellationHandler {
            let arrived = Date()
            if navigating { try await Task.sleep(for: Self.dwell) }
            while true {
                while !canStart(ticket) {
                    try Task.checkCancellation()
                    if ticket.superseded || !isWanted(ticket.url) {
                        ticket.superseded = true
                        logger.notice("\(ticket.label, privacy: .public): dropped before reading, no preview wants it")
                        throw Superseded()
                    }
                    scheduleQuietWakeIfNeeded()
                    await withCheckedContinuation { wakeups.append($0) }
                }
                try Task.checkCancellation()

                holder = ticket
                ticket.preempted = false
                let start = Date()
                let role = ticket.url == newestURL ? "newest" : "on screen"
                logger.notice("\(ticket.label, privacy: .public) [\(role, privacy: .public)]: reading after \(Self.ms(since: arrived), privacy: .public) ms")
                let task = Task.detached(priority: .userInitiated) { try work(readFinished) }
                ticket.cancelWork = { task.cancel() }
                // Stopped or cancelled between the checks above and now: those
                // paths found no work to cancel.
                if Task.isCancelled || ticket.superseded || ticket.preempted { task.cancel() }
                let result = await task.result
                ticket.cancelWork = nil
                release(ticket)

                switch result {
                case .success(let value):
                    logger.notice("\(ticket.label, privacy: .public): done in \(Self.ms(since: start), privacy: .public) ms")
                    return value
                case .failure(let error):
                    if error is CancellationError, !Task.isCancelled {
                        if ticket.superseded {
                            logger.notice("\(ticket.label, privacy: .public): dropped after \(Self.ms(since: start), privacy: .public) ms of reading, no preview wants it")
                            throw Superseded()
                        }
                        if ticket.preempted {
                            logger.notice("\(ticket.label, privacy: .public): stopped for a newer request after \(Self.ms(since: start), privacy: .public) ms, waiting")
                            continue
                        }
                    }
                    throw error
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                ticket.cancelWork?()
                self?.wakeAll()
            }
        }
    }

    private var liveClients: [NetworkReadClient] {
        clients.allObjects.compactMap { $0 as? NetworkReadClient }
    }

    private func isWanted(_ url: URL) -> Bool {
        url == newestURL || liveClients.contains { $0.readURL == url && $0.wantsRead }
    }

    private func isShown(_ url: URL) -> Bool {
        liveClients.contains { $0.readURL == url && $0.isShown }
    }

    private var isQuiet: Bool {
        guard let last = lastRequestAt else { return true }
        return Date().timeIntervalSince(last) >= Self.quietDelay
    }

    private func canStart(_ ticket: Ticket) -> Bool {
        guard holder == nil, !ticket.superseded else { return false }
        if ticket.url == newestURL { return true }
        guard isShown(ticket.url), isQuiet else { return false }
        let others = tickets.filter { $0 !== ticket && !$0.superseded && !$0.readFinished }
        if others.contains(where: { $0.url == newestURL }) { return false }
        return !others.contains { $0.sequence > ticket.sequence && isShown($0.url) }
    }

    /// Drops the requests no preview wants; on a new request, also stops the
    /// read in progress unless it is for the newest file.
    private func reevaluate(newRequest: Bool) {
        for ticket in tickets where !ticket.superseded && !ticket.readFinished {
            if !isWanted(ticket.url) {
                ticket.superseded = true
                ticket.cancelWork?()
            } else if newRequest, ticket === holder, ticket.url != newestURL, !ticket.preempted {
                ticket.preempted = true
                ticket.cancelWork?()
            }
        }
        wakeAll()
    }

    private func release(_ ticket: Ticket) {
        guard holder === ticket else { return }
        holder = nil
        wakeAll()
    }

    private func markReadFinished(_ ticket: Ticket) {
        guard !ticket.superseded, !ticket.preempted else { return }
        ticket.readFinished = true
        release(ticket)
    }

    private func wakeAll() {
        let waiters = wakeups
        wakeups = []
        for waiter in waiters { waiter.resume() }
    }

    /// An on-screen read held back only by the quiet period needs a wake-up when
    /// that period ends; nothing else would come.
    private func scheduleQuietWakeIfNeeded() {
        guard quietWake == nil, let last = lastRequestAt else { return }
        let remaining = Self.quietDelay - Date().timeIntervalSince(last)
        guard remaining > 0 else { return }
        quietWake = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(remaining * 1000) + 10))
            guard let self else { return }
            self.quietWake = nil
            self.wakeAll()
        }
    }

    private static func ms(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }
}
