import DarraOwlShared
import Foundation
import Synchronization
import UIKit
import WatchConnectivity

/// The Apple Watch's way to the Mac: it shows what the iPhone pushes and asks
/// the iPhone to send commands, signed here. Commands that need Face ID are
/// refused: they stay on the iPhone.
@MainActor
final class WatchBridge: NSObject, WCSessionDelegate {
    static let shared = WatchBridge()

    private var lastPushed: Data?
    /// The session the watch face last heard about: a change is sent with
    /// the complication's own (budgeted) channel, so the face updates even
    /// while the watch app is closed.
    private var lastComplicationKey: String?
    /// The watch waits for an answer at most this long.
    static let replyWithin: Duration = .seconds(8)

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// The latest state, as the watch's application context.
    func push(_ snapshot: WatchLink.Snapshot) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled,
              let data = try? WatchLink.encode(snapshot), data != lastPushed
        else { return }
        do {
            try session.updateApplicationContext([WatchLink.key: data])
            lastPushed = data
        } catch {
            lastPushed = nil
        }
        let s = snapshot.state?.session
        let key = s.map { "\($0.id)-\($0.endsAt.timeIntervalSince1970)" } ?? "none"
        if key != lastComplicationKey, session.isComplicationEnabled, session.remainingComplicationUserInfoTransfers > 0 {
            lastComplicationKey = key
            session.transferCurrentComplicationUserInfo([WatchLink.key: data])
        }
    }

    private func handle(_ request: WatchLink.Request) async -> WatchLink.Reply {
        let runtime = PhoneRuntime.shared
        // Woken in the background by the watch: time to answer, and for a
        // command, to finish sending it (ended from the sending task).
        let background = BackgroundTime("DarraOwl watch")
        await runtime.start()
        switch request {
        case .refresh:
            if !runtime.isDemo { await runtime.model.tick() }
            background.end()
            let paired = runtime.model.mac != nil
            return WatchLink.Reply(ok: paired, message: paired ? nil : "Aucun Mac appairé sur l'iPhone.", snapshot: runtime.watchSnapshot())
        case let .command(kind):
            guard WatchLink.allowed(kind) else {
                background.end()
                return WatchLink.Reply(ok: false, message: WatchLink.needsPhone, snapshot: runtime.watchSnapshot())
            }
            guard runtime.model.mac != nil else {
                background.end()
                return WatchLink.Reply(ok: false, message: "Aucun Mac appairé sur l'iPhone.", snapshot: runtime.watchSnapshot())
            }
            guard !runtime.model.isBusy else {
                background.end()
                return WatchLink.Reply(ok: false, message: "L'iPhone envoie déjà une commande, réessaie.", snapshot: runtime.watchSnapshot())
            }
            // A direct link that died while the app was suspended is dropped
            // first: its 10 s wait would pass the watch's budget.
            if !runtime.isDemo { await runtime.model.tick() }
            let model = runtime.model
            let sending = Task {
                await model.send(kind)
                background.end()
            }
            // Through iCloud the Mac can take a minute: the watch gets an
            // answer within 8 s, and the new state follows by itself.
            guard await Self.finishes(sending, within: Self.replyWithin) else {
                return WatchLink.Reply(ok: true, message: "Demande envoyée, le Mac répond par iCloud.", snapshot: runtime.watchSnapshot(), pending: true)
            }
            let (ok, message): (Bool, String?) = switch model.outcome {
            case let .done(text): (true, text)
            case let .failed(text): (false, text)
            case .sending, .none: (false, "Pas de réponse du Mac.")
            }
            return WatchLink.Reply(ok: ok, message: message, snapshot: runtime.watchSnapshot())
        }
    }

    /// True when `task` ended in time. It is not cancelled otherwise: the
    /// command goes on, only the wait stops.
    private static func finishes(_ task: Task<Void, Never>, within limit: Duration) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = OnceFlag()
            Task {
                await task.value
                if once.claim() { continuation.resume(returning: true) }
            }
            Task {
                try? await Task.sleep(for: limit)
                if once.claim() { continuation.resume(returning: false) }
            }
        }
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            if let snapshot = PhoneRuntime.shared.watchSnapshot() { self.push(snapshot) }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// The user switched to another watch: start again with it.
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let reply = ReplySender(send: replyHandler)
        guard let data = message[WatchLink.key] as? Data, let request = try? WatchLink.decode(WatchLink.Request.self, from: data) else {
            reply.send([:])
            return
        }
        Task { @MainActor in
            let answer = await self.handle(request)
            reply.send([WatchLink.key: (try? WatchLink.encode(answer)) ?? Data()])
        }
    }
}

/// WatchConnectivity's reply block, called once from the main actor.
private struct ReplySender: @unchecked Sendable {
    let send: ([String: Any]) -> Void
}

/// Background time from UIKit, ended once, or by iOS when it runs out.
@MainActor
final class BackgroundTime {
    private var id: UIBackgroundTaskIdentifier = .invalid

    init(_ name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

/// Claimed once, from any thread.
final class OnceFlag: Sendable {
    private let done = Mutex(false)

    func claim() -> Bool {
        done.withLock { done in
            defer { done = true }
            return !done
        }
    }
}
