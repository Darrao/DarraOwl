import DarraOwlShared
import Foundation
import WatchConnectivity

/// The Apple Watch's way to the Mac: it shows what the iPhone pushes and asks
/// the iPhone to send commands, signed here. Commands that need Face ID are
/// refused: they stay on the iPhone.
@MainActor
final class WatchBridge: NSObject, WCSessionDelegate {
    static let shared = WatchBridge()

    private var lastPushed: Data?

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// The latest state, as the watch's application context.
    func push(_ snapshot: WatchLink.Snapshot) {
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated, session.isPaired, session.isWatchAppInstalled,
              let data = try? WatchLink.encode(snapshot), data != lastPushed
        else { return }
        do {
            try session.updateApplicationContext([WatchLink.key: data])
            lastPushed = data
        } catch {
            lastPushed = nil
        }
    }

    private func handle(_ request: WatchLink.Request) async -> WatchLink.Reply {
        let runtime = PhoneRuntime.shared
        await runtime.start()
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
            await runtime.model.send(kind)
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
