import DarraOwlCore
import DarraOwlShared
import DarraOwlXPC
import Foundation

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
        do {
            let status: EngineStatus
            switch request {
            case .status:
                status = await engine.status()
            case let .start(seconds, origin):
                status = try await engine.start(duration: seconds, origin: origin)
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
            case .restartIfIdle:
                status = await engine.status()
                if status.session == nil, !status.sleepHeld, !status.lowPowerHeld, status.frozen.isEmpty {
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
