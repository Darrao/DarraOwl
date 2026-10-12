import DarraOwlShared
import Foundation
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
        // Woken in the background by the watch: keep running until the answer.
        let task = UIApplication.shared.beginBackgroundTask(withName: "DarraOwl watch")
        defer { if task != .invalid { UIApplication.shared.endBackgroundTask(task) } }
        await runtime.start()
        guard !runtime.isDemo else {
            return WatchLink.Reply(ok: false, message: "L'iPhone montre la démonstration : il ne pilote aucun Mac.", snapshot: nil)
        }
        switch request {
        case .refresh:
            await runtime.model.tick()
            return WatchLink.Reply(ok: true, message: nil, snapshot: runtime.watchSnapshot())
        case let .command(kind):
            guard WatchLink.allowed(kind) else {
                return WatchLink.Reply(ok: false, message: WatchLink.needsPhone, snapshot: runtime.watchSnapshot())
            }
            guard runtime.model.mac != nil else {
                return WatchLink.Reply(ok: false, message: "Aucun Mac appairé sur l'iPhone.", snapshot: nil)
            }
            guard !runtime.model.isBusy else {
                return WatchLink.Reply(ok: false, message: "L'iPhone envoie déjà une commande, réessaie.", snapshot: runtime.watchSnapshot())
            }
            // Through iCloud the Mac can take a minute: the watch gets an
            // answer within 8 s, and the new state follows by itself.
            let sending = Task { await runtime.model.send(kind) }
            let finished = await withTaskGroup(of: Bool.self) { group in
                group.addTask { await sending.value; return true }
                group.addTask { try? await Task.sleep(for: Self.replyWithin); return false }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            guard finished else {
                return WatchLink.Reply(ok: true, message: "Demande envoyée, le Mac répond par iCloud.", snapshot: runtime.watchSnapshot())
            }
            let (ok, message): (Bool, String?) = switch runtime.model.outcome {
            case let .done(text): (true, text)
            case let .failed(text): (false, text)
            case .sending, .none: (false, "Pas de réponse du Mac.")
            }
            return WatchLink.Reply(ok: ok, message: message, snapshot: runtime.watchSnapshot())
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
