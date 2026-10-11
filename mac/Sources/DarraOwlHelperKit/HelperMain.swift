import DarraOwlCore
import DarraOwlShared
import DarraOwlSystem
import DarraOwlXPC
import Foundation

/// Entry point of the privileged helper (launchd daemon, root, RunAtLoad,
/// KeepAlive). It restores the machine whether or not the app is running.
public enum HelperMain {
    public static let stateDirectory = URL(fileURLWithPath: "/Library/Application Support/DarraOwl", isDirectory: true)

    nonisolated(unsafe) private static var retained: [AnyObject] = []

    public static func run() -> Never {
        let log = OSLogEngineLogger(category: "helper")
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev"
        let engine = SessionEngine(.init(
            power: PmsetPowerControl(),
            source: IOPSPowerSource(),
            processes: SysctlProcessControl(),
            clock: SystemClock(),
            journalStore: JSONFileStore<Journal>(directory: stateDirectory, fileName: "journal.json"),
            settingsStore: JSONFileStore<PowerSettings>(directory: stateDirectory, fileName: "settings.json"),
            log: log
        ))
        let ticker = Ticker()
        log.info("helper \(build) starting")

        // SIGTERM (unregistered, shutdown, update): end the session and undo
        // everything before exiting. launchd waits for us.
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler {
            Task {
                log.info("SIGTERM: ending any session")
                await engine.handleTermination()
                exit(0)
            }
        }
        term.resume()
        retained.append(term as AnyObject)

        let thermal = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil
        ) { _ in
            Task { await ticker.kick() }
        }
        retained.append(thermal as AnyObject)

        // The check loop runs even when no client may connect: restoring the
        // machine never depends on XPC.
        let binary = BinaryIdentity.current()
        Task {
            _ = await engine.reconcile()
            while true {
                let delay = await engine.nextCheckDelay()
                await ticker.wait(seconds: delay)
                let status = await engine.evaluate()
                // An update replaced our binary: the app can no longer verify
                // this process, so step aside as soon as nothing is held and
                // let launchd (KeepAlive) start the new one.
                if let binary, binary.wasReplaced(),
                   status.session == nil, !status.sleepHeld, !status.lowPowerHeld, status.frozen.isEmpty {
                    log.info("binary replaced by an update, restarting")
                    exit(0)
                }
            }
        }

        if let team = CodeRequirements.currentTeamID(), let requirement = CodeRequirements.client(teamID: team) {
            let delegate = ListenerDelegate(engine: engine, build: build, ticker: ticker, log: log)
            let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
            listener.setConnectionCodeSigningRequirement(requirement)
            listener.delegate = delegate
            listener.resume()
            retained.append(contentsOf: [delegate, listener])
            log.info("listening on \(HelperConstants.machServiceName) for team \(team)")
        } else {
            log.error("helper is not signed with a Team ID: no client is accepted, the check loop still runs")
        }

        RunLoop.main.run()
        fatalError("main run loop returned")
    }
}
