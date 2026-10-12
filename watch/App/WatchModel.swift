import DarraOwlShared
import Foundation
import Observation
import WatchConnectivity

/// The watch's view of the Mac, through the iPhone. The iPhone pushes the
/// state; commands go to the iPhone, which signs and sends them.
@MainActor
@Observable
final class WatchModel: NSObject, WCSessionDelegate {
    static let shared = WatchModel()

    private(set) var snapshot: WatchLink.Snapshot?
    private(set) var busy = false
    /// Last command's answer, shown under the buttons for a few seconds.
    private(set) var message: String?
    private(set) var failed = false
    @ObservationIgnored private var messageToken = 0
    let demo = CommandLine.arguments.contains("-DarraOwlDemo")
    @ObservationIgnored private var started = false

    var state: MacState? { snapshot?.state }

    func start() {
        guard !started else { return }
        started = true
        if demo {
            snapshot = WatchDemo.snapshot(now: Date())
            return
        }
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func refresh() async {
        start()
        guard !demo, let reply = await request(.refresh) else { return }
        if let snapshot = reply.snapshot { apply(snapshot) }
    }

    /// Returns true when the Mac ran it (or the request left, when the Mac
    /// answers through iCloud).
    @discardableResult
    func send(_ kind: CommandKind) async -> Bool {
        start()
        guard !busy else {
            show("Une commande est déjà en cours.", failed: true)
            return false
        }
        busy = true
        defer { busy = false }
        show("\(kind.label)…", failed: false, keep: true)
        if demo {
            snapshot = WatchDemo.apply(kind, to: snapshot)
            show("\(kind.label) : fait.", failed: false)
            return true
        }
        guard let reply = await request(.command(kind)) else {
            show("iPhone injoignable.", failed: true)
            return false
        }
        if let snapshot = reply.snapshot { apply(snapshot) }
        show(reply.message, failed: !reply.ok)
        return reply.ok
    }

    /// A message goes after a few seconds (a failure stays longer).
    private func show(_ text: String?, failed: Bool, keep: Bool = false) {
        messageToken += 1
        let token = messageToken
        message = text
        self.failed = failed
        guard !keep, text != nil else { return }
        Task {
            try? await Task.sleep(for: .seconds(failed ? 10 : 5))
            if self.messageToken == token { self.message = nil }
        }
    }

    /// Background delivery from the iPhone (watchOS wakes the app for it).
    func drainPending() async {
        start()
        for _ in 0..<20 where WCSession.isSupported() && WCSession.default.hasContentPending {
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private func request(_ request: WatchLink.Request) async -> WatchLink.Reply? {
        let session = WCSession.default
        // An intent can run before the session finished activating.
        for _ in 0..<20 where session.activationState != .activated {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard session.activationState == .activated, session.isReachable, let data = try? WatchLink.encode(request) else { return nil }
        return await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            // @Sendable: WatchConnectivity calls these on its own queue. Left
            // to inference they would be main-actor closures, and Swift 6
            // stops the app when one runs elsewhere.
            session.sendMessage([WatchLink.key: data], replyHandler: { @Sendable reply in
                let decoded = (reply[WatchLink.key] as? Data).flatMap { try? WatchLink.decode(WatchLink.Reply.self, from: $0) }
                once.resume(decoded)
            }, errorHandler: { @Sendable _ in
                once.resume(nil)
            })
        }
    }

    private func apply(_ snapshot: WatchLink.Snapshot) {
        self.snapshot = snapshot
        let session = snapshot.state?.session
        ComplicationStore.save(ComplicationSnapshot(
            macName: snapshot.macName ?? snapshot.state?.macName ?? "Mac",
            online: snapshot.online,
            sessionStartedAt: session?.startedAt,
            sessionEndsAt: session?.endsAt,
            following: session?.watchingText,
            battery: snapshot.state?.powerSnapshot?.battery.percent,
            charging: snapshot.state?.powerSnapshot?.onExternalPower ?? false,
            updatedAt: snapshot.at
        ))
    }

    private func receive(_ context: [String: Any]) {
        guard let data = context[WatchLink.key] as? Data, let snapshot = try? WatchLink.decode(WatchLink.Snapshot.self, from: data) else { return }
        apply(snapshot)
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let context = Context(value: session.receivedApplicationContext)
        Task { @MainActor in self.receive(context.value) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let context = Context(value: applicationContext)
        Task { @MainActor in self.receive(context.value) }
    }

    /// The complication's update: the session started, moved or ended.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let context = Context(value: userInfo)
        Task { @MainActor in self.receive(context.value) }
    }
}

/// A WatchConnectivity dictionary handed to the main actor.
private struct Context: @unchecked Sendable {
    let value: [String: Any]
}

/// Resumes a continuation once, whichever WatchConnectivity handler fires.
private final class ResumeOnce: @unchecked Sendable {
    private var continuation: CheckedContinuation<WatchLink.Reply?, Never>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<WatchLink.Reply?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: WatchLink.Reply?) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}
