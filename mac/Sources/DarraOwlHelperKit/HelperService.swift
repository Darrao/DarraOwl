import DarraOwlCore
import DarraOwlShared
import DarraOwlXPC
import Foundation
import SystemConfiguration

/// Wakes the helper's check loop early: after a request changed the end time,
/// or on a thermal event.
actor Ticker {
    private var waiter: (id: Int, continuation: CheckedContinuation<Void, Never>)?
    private var nextID = 0
    private var kicked = false

    /// Returns after `seconds`, or as soon as `kick()` is called.
    func wait(seconds: TimeInterval) async {
        if kicked {
            kicked = false
            return
        }
        nextID += 1
        let id = nextID
        await withCheckedContinuation { continuation in
            waiter = (id, continuation)
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                self.resume(id)
            }
        }
    }

    func kick() {
        if let waiter {
            resume(waiter.id)
        } else {
            kicked = true
        }
    }

    private func resume(_ id: Int) {
        guard let waiter, waiter.id == id else { return }
        self.waiter = nil
        waiter.continuation.resume()
    }
}

/// The object exported over XPC. Decodes a request, runs it on the engine,
/// encodes the answer. Only reachable by code that passed the listener's
/// code signing requirement.
public final class HelperService: NSObject, HelperXPCProtocol, Sendable {
    let engine: SessionEngine
    let build: String
    let ticker: Ticker
    let log: any EngineLogging
    /// Effective uid of the connected client, from the kernel's audit token.
    /// Only that user's processes can be paused through this connection.
    let clientUID: UInt32

    init(engine: SessionEngine, build: String, ticker: Ticker, log: any EngineLogging, clientUID: UInt32) {
        self.engine = engine
        self.build = build
        self.ticker = ticker
        self.log = log
        self.clientUID = clientUID
    }

    public func handle(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        Task {
            let response = await self.process(request)
            reply((try? HelperCoding.encode(response)) ?? Data())
        }
    }

    func process(_ data: Data) async -> HelperResponse {
        let request: HelperRequest
        do {
            request = try HelperCoding.decode(HelperRequest.self, from: data)
        } catch {
            log.error("rejected undecodable request")
            return HelperResponse(helperBuild: build, status: nil, error: "Requête invalide.")
        }
        // Reading is open to any client; changing anything is for the user
        // at the screen (or root): another account on this Mac cannot stop,
        // extend or reconfigure the owner's session. At the login window
        // nobody is at the screen: only the session's owner may act.
        if request != .status, clientUID != 0 {
            let console = Self.consoleUID()
            let allowed = if let console { clientUID == console } else { await engine.sessionOwner() == clientUID }
            if !allowed {
                log.error("refused \(String(describing: request).prefix(40)) from uid \(clientUID), console is \(console.map(String.init) ?? "loginwindow")")
                return HelperResponse(helperBuild: build, status: await engine.status(), error: "Réservé à l'utilisateur connecté à l'écran du Mac.")
            }
        }
        do {
            let status: EngineStatus
            switch request {
            case .status:
                status = await engine.status()
            case let .start(seconds, origin):
                status = try await engine.start(duration: seconds, origin: origin, requesterUID: clientUID)
            case let .extend(seconds):
                status = try await engine.extend(by: seconds)
            case let .stop(reason):
                // Clients may only stop for these reasons; the others are the helper's.
                let allowed: Set<SessionEndReason> = [.userStopped, .appQuit]
                status = try await engine.stop(reason: allowed.contains(reason) ? reason : .userStopped)
            case let .updateSettings(settings):
                status = try await engine.updateSettings(settings)
            case .prepareUninstall:
                status = await engine.prepareUninstall()
            case let .recordUserChanges(changes):
                status = try await engine.recordUserChanges(changes)
            case let .clearUserChanges(kinds):
                status = await engine.clearUserChanges(kinds)
            case let .freeze(groups):
                status = try await engine.freeze(groups, requesterUID: clientUID)
            case let .resume(bundleID):
                status = await engine.resume(onlyBundleID: bundleID)
            case .sleepNow:
                status = try await engine.sleepNow()
            case .lidChanged:
                status = await engine.evaluate()
            case let .watch(process, seconds, origin):
                let allowed: Set<SessionOrigin> = [.agent, .cli]
                status = try await engine.watch(process, seconds: seconds, origin: allowed.contains(origin) ? origin : .agent, requesterUID: clientUID)
            case let .release(pid):
                status = await engine.release(pid: pid)
            case let .displays(external):
                status = await engine.setExternalDisplay(external)
            case .restartIfIdle:
                // Checked and claimed in one turn: nothing can start between
                // the check and the exit.
                let idle = await engine.shutDownIfIdle()
                status = await engine.status()
                if idle {
                    log.info("restarting for update")
                    Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        exit(0)
                    }
                }
            }
            await ticker.kick()
            return HelperResponse(helperBuild: build, status: status, error: nil)
        } catch {
            await ticker.kick()
            return HelperResponse(helperBuild: build, status: await engine.status(), error: error.localizedDescription)
        }
    }
}

extension HelperService {
    /// uid of the user logged in at the screen, nil at the login window.
    static func consoleUID() -> UInt32? {
        var uid: uid_t = 0
        guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as String?, name != "loginwindow" else { return nil }
        return uid
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate, Sendable {
    let engine: SessionEngine
    let build: String
    let ticker: Ticker
    let log: any EngineLogging

    init(engine: SessionEngine, build: String, ticker: Ticker, log: any EngineLogging) {
        self.engine = engine
        self.build = build
        self.ticker = ticker
        self.log = log
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: HelperXPCProtocol.self)
        connection.exportedObject = HelperService(
            engine: engine, build: build, ticker: ticker, log: log,
            clientUID: connection.effectiveUserIdentifier
        )
        connection.resume()
        return true
    }
}
