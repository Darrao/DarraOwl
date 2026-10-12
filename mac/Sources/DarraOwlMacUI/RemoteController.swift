import AppKit
import CoreGraphics
import CryptoKit
import DarraOwlCore
import DarraOwlShared
import DarraOwlSystem
import DarraOwlXPC
import Foundation
import Observation

/// Everything the phone sees and can do: the direct encrypted server, the
/// iCloud mailbox, pairing. Commands are executed through the helper.
@MainActor
@Observable
public final class RemoteController: CommandTarget {
    public private(set) var invite: PairingInvite?
    public private(set) var devices: [PairedDevice] = []
    public private(set) var cloudProblem: String?
    /// The iCloud account has been looked at once (the link starts once the
    /// system component answers).
    public private(set) var cloudChecked = false
    /// Pairing or unpairing problem, kept until the next attempt.
    public private(set) var pairingProblem: String?
    public private(set) var macPower: MacState.Power = .awake
    /// Copies of the direct server's and hook server's state, so windows
    /// showing them refresh (those objects are not observable).
    public private(set) var serverPort: UInt16?
    public private(set) var serverProblem: String?
    public private(set) var connectedDevices: Set<UUID> = []
    public private(set) var hookListening = false
    public private(set) var containers: [MacState.Container] = []
    public private(set) var lastResult: CommandResult?

    @ObservationIgnored private unowned let model: AppModel
    @ObservationIgnored private let store = KeychainPairingStore()
    @ObservationIgnored private var hub: RemoteHub?
    @ObservationIgnored private var server: LinkServer?
    @ObservationIgnored private var cloud: CloudKitMailbox?
    @ObservationIgnored private let network = NetworkInfo()
    @ObservationIgnored private let docker = DockerControl()
    @ObservationIgnored private let audio = CoreAudioControl()
    @ObservationIgnored private let sleepGate = SleepGate()
    /// The last phone was unpaired and does not know it yet.
    @ObservationIgnored private var farewellPending = false
    /// A stop answered first, done 2 s later (lid closed).
    @ObservationIgnored private var stopDeferred = false
    @ObservationIgnored private let log = OSLogEngineLogger(category: "remote")
    @ObservationIgnored private var lastBroadcast: MacState?
    @ObservationIgnored private var tick = 0
    @ObservationIgnored private var started = false
    @ObservationIgnored private var lastStartAttempt: Date?
    @ObservationIgnored private var accountProblem: String?
    @ObservationIgnored private var lastBroadcastAt: Date?
    @ObservationIgnored private var events = EventCenter()
    @ObservationIgnored private var signals = AgentSignals()
    @ObservationIgnored private var agentsSeenInSession: (session: UUID?, tools: [String]) = (nil, [])
    @ObservationIgnored private(set) var hookServer: HookServer?
    public private(set) var agents: [AgentProcess] = []
    @ObservationIgnored private var dataMeter = DataMeter()
    public private(set) var sessionBytes: Int64?

    public let macName = Host.current().localizedName ?? "Mac"

    init(model: AppModel) {
        self.model = model
    }

    // MARK: Lifecycle

    /// Starts the link once the Keychain answers; retried every 30 s
    /// otherwise (a locked keychain at login).
    func start() {
        guard !started else { return }
        if let last = lastStartAttempt, Date().timeIntervalSince(last) < 30 { return }
        lastStartAttempt = Date()
        let identity: MacIdentity
        do {
            identity = try store.identity()
        } catch {
            cloudProblem = "Trousseau : \(error.localizedDescription)"
            return
        }
        started = true
        let cloud = CloudKitMailbox(macID: identity.macID)
        self.cloud = cloud
        let hub = RemoteHub(
            store: store, target: self, cloud: cloud,
            ledgerStore: JSONFileStore<CommandLedger>(directory: Self.appSupport, fileName: "commands.json"),
            clock: SystemClock(), log: log
        )
        self.hub = hub
        hub.mainEndpoints = { [weak self] in self?.mainEndpoints() }
        // Not when the command answered first and acts a moment later (sleep,
        // a stop with the lid closed): its state is not new yet, and its
        // result must leave before the Mac sleeps.
        hub.afterCommand = { [weak self] in
            guard let self, self.macPower != .goingToSleep, !self.stopDeferred else { return }
            await self.publish(force: true)
            // Queued behind a publish on its way: the result waits for it,
            // 3 s at most, so the phone reading the state after it sees this one.
            for _ in 0..<30 where self.hub?.isPublishing == true {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        hub.onResult = { [weak self] result in
            self?.lastResult = result
            self?.server?.broadcast(.result(result))
        }
        hub.onPaired = { [weak self] _, _ in
            guard let self, let hub = self.hub else { return }
            self.devices = hub.pairedDevices()
            self.farewellPending = false
            self.pairingProblem = nil
            self.server?.stopPairing()
            self.invite = nil
            self.restartServer()
        }
        hub.onDeviceRemoved = { [weak self] id in
            if let self, let hub = self.hub {
                self.devices = hub.pairedDevices()
                // Read for sure (not a Keychain error): no phone left.
                if let left = try? self.store.devices(), left.isEmpty {
                    self.farewellPending = true
                    Task { await self.publishFarewell() }
                }
            }
            self?.server?.disconnectAll()
            self?.restartServer()
        }
        server = LinkServer(macID: identity.macID, macName: macName, handlers: .init(
            message: { [weak self] deviceID, message in await self?.answer(deviceID, message) },
            pairing: { [weak self] request in self?.pair(request) ?? PairingResponse(accepted: false, macID: identity.macID, macName: "", message: nil) },
            isPaired: { [weak self] id in self?.devices.contains { $0.id == id } ?? false }
        ))
        network.onChange = { [weak self] in
            guard let self else { return }
            // Back online: iCloud is tried again at once, not after its back-off.
            if self.network.isUp { self.hub?.retryNow() }
            self.publishSoon()
        }
        if let token = HookToken.current() {
            let hooks = HookServer(token: token) { [weak self] parsed in self?.handleHook(parsed) }
            hooks.start()
            hookServer = hooks
        }
        agents = AgentScanner.scan()
        network.start()
        devices = hub.pairedDevices()
        restartServer()
        observeSleep()
        Task {
            accountProblem = await cloud.accountProblem()
            cloudChecked = true
            await refreshContainers()
            await publish(force: true)
            await hub.pollCloud(macName: macName)
        }
    }

    /// Where paired phones reach the main listener: its port once it runs,
    /// the fixed port before (the first pairing starts it).
    private func mainEndpoints() -> Endpoints? {
        EndpointPicker.endpoints(from: NetworkInfo.interfaces(), port: server?.port ?? LinkProtocol.defaultPort)
    }

    /// Called every second by the app model.
    func everySecond() {
        guard started, let hub else { return }
        tick += 1
        if tick % 2 == 0 { Task { await publish() } }
        let pollEvery = hub.cloudPollInterval(sessionRunning: model.session != nil)
        if tick % pollEvery == 0 { Task { await hub.pollCloud(macName: macName) } }
        if tick % 30 == 0 { Task { await refreshContainers() } }
        if tick % 5 == 0 { checkEvents() }
        if tick % 10 == 0 { refreshAgents() }
        if tick % 60 == 0, let cloud { Task { accountProblem = await cloud.accountProblem() } }
        if farewellPending, tick % 10 == 0 { Task { await publishFarewell() } }
        // Old events go two minutes after launch, then every hour.
        if tick % 3600 == 120 { Task { await cloud?.removeEvents(before: Date().addingTimeInterval(-86_400)) } }
        if let invite, Date() > invite.expiresAt { cancelInvite() }
        // Without a paired phone nothing goes to iCloud: an old error is moot.
        let problem = accountProblem ?? (devices.isEmpty ? nil : hub.cloudError.map { "iCloud : \($0)" })
        if problem != cloudProblem { cloudProblem = problem }
        // Mirrors of objects that are not observable.
        if server?.port != serverPort { serverPort = server?.port }
        if server?.lastError != serverProblem { serverProblem = server?.lastError }
        let connected = server?.connectedDevices ?? []
        if connected != connectedDevices { connectedDevices = connected }
        let listening = hookServer?.isListening ?? false
        if listening != hookListening { hookListening = listening }
        if hookServer == nil, tick % 30 == 0, let token = HookToken.current() {
            let hooks = HookServer(token: token) { [weak self] parsed in self?.handleHook(parsed) }
            hooks.start()
            hookServer = hooks
        } else if tick % 30 == 0, hookServer?.isListening == false {
            hookServer?.start()
        }
    }

    /// A silent push from CloudKit: the phone wrote something.
    func cloudChanged() {
        guard started, let hub else { return }
        hub.retryNow()
        Task { await hub.pollCloud(macName: macName) }
    }

    // MARK: Agents

    private func refreshAgents() {
        let found = AgentScanner.scan()
        if found != agents {
            agents = found
            publishSoon()
        }
        let session = model.status?.session?.id
        if agentsSeenInSession.session != session { agentsSeenInSession = (session, []) }
        if session != nil {
            for a in found where !agentsSeenInSession.tools.contains(a.tool) { agentsSeenInSession.tools.append(a.tool) }
        }
    }

    /// Claude Code hook: "finished" or "waiting for approval". Notifies the
    /// phone only when nobody is at the Mac (lid closed or 60 s idle).
    private func handleHook(_ parsed: ClaudeHook.Parsed) {
        let now = Date()
        let mask = model.status?.settings.alerts.maskProjectNames ?? false
        func project(_ cwd: String?) -> String {
            guard !mask, let cwd, case let name = URL(fileURLWithPath: cwd).lastPathComponent, !name.isEmpty, name != "/" else { return "Un projet" }
            return name
        }
        var event: MacEvent?
        switch parsed {
        case let .finished(cwd):
            if let cwd { signals.record(.finished, cwd: cwd, at: now) }
            event = MacEvent(kind: .agentDone, title: "Claude a fini", body: project(cwd), at: now)
        case let .waiting(cwd):
            if let cwd { signals.record(.waiting, cwd: cwd, at: now) }
            event = MacEvent(kind: .agentWaiting, title: "Claude attend ta validation", body: project(cwd), at: now)
        case .ignored:
            break
        }
        publishSoon()
        guard let event, nobodyAtTheMac, let hub, !devices.isEmpty else { return }
        Task { await hub.post([event]) }
    }

    private var nobodyAtTheMac: Bool {
        model.lidClosed || UserIdle.seconds() >= 60
    }

    // MARK: Events

    private func checkEvents() {
        guard let hub, let found = collectEvents() else { return }
        if !found.isEmpty || !hub.pendingEvents.isEmpty {
            Task { await hub.post(found) }
        }
    }

    /// The events of the moment, nil when nobody is to be told.
    /// The macOS session's lock, as loginwindow reports it (the key is only
    /// there while locked).
    private static func screenLocked() -> Bool? {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        return info["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    private func collectEvents() -> [MacEvent]? {
        guard let status = model.status else { return nil }
        sessionBytes = dataMeter.update(session: status.session?.id, counter: NetworkInfo.byteCounter())
        let found = events.update(EventCenter.Input(
            now: Date(), session: status.session, power: status.power, networkUp: network.isUp,
            // After the end, the ended session's total, for its recap.
            sessionBytes: sessionBytes ?? dataMeter.lastSessionTotal, lastEnd: status.lastEnd, alerts: status.settings.alerts,
            agentsDuringSession: agentsSeenInSession.tools,
            screenLocked: Self.screenLocked(), presenceActive: model.presenceActive, userIdle: UserIdle.seconds()
        ))
        // No paired phone: nobody to tell, nothing goes to iCloud.
        return devices.isEmpty ? nil : found
    }

    /// The Mac is about to sleep: what the phone should know leaves first,
    /// a session that just ended with the lid closed included (the helper is
    /// asked afresh), with its recap. A few seconds at most (SleepGate).
    private func beforeSleep() async {
        macPower = .goingToSleep
        guard started, let hub else { return }
        // The status only: restoring brightness now would spend the time.
        await model.fetchStatus()
        if let found = collectEvents(), !found.isEmpty || !hub.pendingEvents.isEmpty {
            await hub.post(found)
        }
        await publish(force: true)
        // A publish or a sender already on its way (the forced state then
        // goes right after it): a moment for them.
        for _ in 0..<30 where hub.isPublishing || !hub.pendingEvents.isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// The last phone was unpaired: one last state, listing no phone, so a
    /// phone that only reads iCloud forgets this Mac. Retried until it went.
    private func publishFarewell() async {
        guard farewellPending, devices.isEmpty, let state = makeState(), let hub else { return }
        if await hub.publishIfDue(state, endpoints: nil, force: true) { farewellPending = false }
    }

    // MARK: Pairing

    func showInvite() {
        guard let hub else {
            pairingProblem = "Appairage impossible : \(cloudProblem ?? "le trousseau ne répond pas.")"
            return
        }
        pairingProblem = nil
        do {
            let invite = try hub.makeInvite(macName: macName, endpoints: nil)
            let listening = server?.startPairing(identity: LinkKeys.pairingIdentity(secret: invite.secret),
                                                 key: LinkKeys.pairingKey(secret: invite.secret, macID: invite.macID)) ?? false
            if !listening { pairingProblem = "Appairage direct indisponible : le code passera par iCloud." }
            // The pairing listener has its own port; wait for it, then put it
            // and this Mac's addresses in the code. Without it, the code still
            // works through iCloud.
            Task {
                for _ in 0..<30 where server?.pairingPort == nil {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard hub.invite?.secret == invite.secret else { return }
                var shown = invite
                if let port = server?.pairingPort {
                    shown.endpoints = EndpointPicker.endpoints(from: NetworkInfo.interfaces(), port: port)
                } else if listening {
                    pairingProblem = "Appairage direct indisponible : le code passera par iCloud."
                }
                self.invite = shown
            }
        } catch {
            pairingProblem = "Appairage : \(error.localizedDescription)"
        }
    }

    func cancelInvite() {
        hub?.cancelInvite()
        server?.stopPairing()
        invite = nil
    }

    func unpair(_ device: PairedDevice) {
        guard let hub else { return }
        do {
            try hub.unpair(deviceID: device.id)
            pairingProblem = nil
        } catch {
            pairingProblem = "Désappairage : \(error.localizedDescription)"
        }
        devices = hub.pairedDevices()
    }

    private func pair(_ request: PairingRequest) -> PairingResponse {
        guard let hub else {
            return PairingResponse(accepted: false, macID: request.macID, macName: macName, message: "Le Mac n'est pas prêt.")
        }
        return hub.handlePairing(request, macName: macName, via: .direct)
    }

    // MARK: Direct link

    private func answer(_ deviceID: UUID, _ message: ClientMessage) async -> ServerMessage? {
        switch message {
        case .getState:
            return makeState().map { .state($0) }
        case let .command(signed):
            guard let hub else { return nil }
            return .result(await hub.handle(signed, via: .direct, peer: deviceID))
        case .hello, .pair:
            return nil
        }
    }

    private func restartServer() {
        guard let hub else { return }
        let keys = devices.compactMap { d in hub.linkKey(deviceID: d.id).map { (deviceID: d.id, key: $0) } }
        server?.start(keys: keys)
    }

    // MARK: State

    func makeState() -> MacState? {
        guard let status = model.status, let identity = try? store.identity() else { return nil }
        let mask = status.settings.alerts.maskProjectNames
        var session = status.session
        if mask, let watching = session?.watching {
            session?.watching = watching.map { var p = $0; p.project = nil; return p }
        }
        // Compose names start with the project folder: masked with the rest.
        let shownContainers = mask ? containers.map { var c = $0; c.name = "Conteneur \(c.id.prefix(6))"; return c } : containers
        return MacState(
            macID: identity.macID, macName: macName, updatedAt: Date(), power: macPower,
            session: session, powerSnapshot: status.power, lowPowerActive: status.lowPowerHeld,
            pausedApps: Set(status.frozen.map(\.name)).sorted(),
            network: MacState.Network(kind: network.kind, sessionBytes: sessionBytes),
            agents: signals.states(agents, now: Date(), mask: mask),
            containers: shownContainers,
            dockerPaused: status.frozen.contains { $0.bundleID == PausePolicy.dockerBundleID },
            settings: status.settings,
            presence: MacState.Presence(active: model.presenceActive, until: model.presenceUntil, whileClosed: model.presenceWhileClosed),
            muted: (try? audio.readDefaultOutput())?.muted,
            dockerRunning: NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == PausePolicy.dockerBundleID },
            pairedDevices: devices.map(\.id)
        )
    }

    private func currentEndpoints() -> Endpoints? {
        guard let port = server?.port else { return nil }
        return EndpointPicker.endpoints(from: NetworkInfo.interfaces(), port: port)
    }

    private func publishSoon() {
        Task { await publish() }
    }

    private func publish(force: Bool = false) async {
        guard let state = makeState(), let hub else { return }
        // On change, and every 30 s: a phone that hears nothing for a minute
        // knows the link is dead even when no TCP error came.
        let stale = lastBroadcastAt.map { Date().timeIntervalSince($0) >= 30 } ?? true
        if stale || (lastBroadcast.map({ !RemoteHub.sameContent($0, state) }) ?? true) {
            server?.broadcast(.state(state))
            lastBroadcast = state
            lastBroadcastAt = Date()
        }
        // No paired phone: nothing to publish to iCloud.
        guard !devices.isEmpty else { return }
        await hub.publishIfDue(state, endpoints: currentEndpoints(), force: force)
    }

    private func refreshContainers() async {
        containers = await docker.containers()
    }

    private func observeSleep() {
        sleepGate.willSleep = { [weak self] done in
            guard let self else {
                done()
                return
            }
            Task { @MainActor in
                await self.beforeSleep()
                done()
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        if !sleepGate.start() {
            // No IOKit power notifications: the plain announcement, unwaited.
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.beforeSleep() }
            }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.macPower = .awake
                self.hub?.retryNow()
                await self.publish(force: true)
                if let hub = self.hub { await hub.pollCloud(macName: self.macName) }
            }
        }
    }

    static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "DarraOwl")
    }

    // MARK: CommandTarget

    public var currentSettings: PowerSettings? { model.status?.settings }
    public var containerIDs: [String] { containers.map(\.id) }

    public func startSession(seconds: TimeInterval) async throws {
        _ = try await model.sendHelper(.start(seconds: seconds, origin: .phone))
    }

    public func extendSession(seconds: TimeInterval) async throws {
        _ = try await model.sendHelper(.extend(seconds: seconds))
    }

    public func stopSession() async throws {
        // Lid closed: the Mac sleeps as soon as the session ends, before the
        // answer could leave. It leaves first and the stop follows, as for
        // sleepNow, so the phone never reads "pas de réponse" for a stop
        // that worked.
        if model.lidClosed, let status = model.status, status.session != nil {
            stopDeferred = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                do {
                    _ = try await model.sendHelper(.stop(reason: .userStopped))
                } catch {
                    log.error("stop after answering failed: \(error.localizedDescription)")
                }
                stopDeferred = false
            }
            return
        }
        _ = try await model.sendHelper(.stop(reason: .userStopped))
    }

    /// Answers first, sleeps 2 s later: a Mac asleep cannot send the result,
    /// and the phone would show "pas de réponse" for a command that worked.
    public func sleepNow() async throws {
        // Brightness and sound first: the helper cannot put them back.
        if let changes = model.status?.userChanges, !changes.isEmpty {
            await model.lidCoordinator.restore(changes)
        }
        macPower = .goingToSleep
        await publish(force: true)
        Task {
            try? await Task.sleep(for: .seconds(2))
            do {
                _ = try await model.sendHelper(.sleepNow)
            } catch {
                log.error("sleep now failed: \(error.localizedDescription)")
                macPower = .awake
                await publish(force: true)
            }
        }
    }

    public func pauseDocker() async throws {
        guard let status = model.status, status.session != nil else { throw RemoteError.notDuringSession }
        // Already paused: nothing to do.
        if status.frozen.contains(where: { $0.bundleID == PausePolicy.dockerBundleID }) { return }
        try await model.lidCoordinator.pauseDocker()
    }

    public func resumeDocker() async throws {
        try await model.lidCoordinator.resumeDocker()
    }

    public func stopContainer(id: String) async throws {
        try await docker.stop(id: id)
        await refreshContainers()
    }

    public func updateSettings(_ settings: PowerSettings) async throws {
        _ = try await model.sendHelper(.updateSettings(settings))
    }

    public var agentPIDs: [Int32] { agents.map(\.pid) }

    public func watchAgent(pid: Int32) async throws {
        guard let agent = agents.first(where: { $0.pid == pid }), let request = AppModel.watchRequest(agent) else {
            throw RemoteError.unknownAgent
        }
        _ = try await model.sendHelper(request)
    }

    public func stopAgent(pid: Int32) async throws {
        // Still the agent that was published: same pid, same start second.
        guard let agent = agents.first(where: { $0.pid == pid }),
              case let .present(state) = SysctlProcessControl().lookup(pid),
              state.uid == getuid(),
              state.identity.startSeconds == Int64(agent.startedAt.timeIntervalSince1970)
        else { throw RemoteError.unknownAgent }
        let outcome = await AgentStopper(processes: SysctlProcessControl()).stop(pid: pid, identity: state.identity)
        refreshAgents()
        if outcome == .stillRunning { throw RemoteError.agentStillRunning }
    }

    public func startPresence(seconds: TimeInterval?) async throws {
        if seconds != nil, model.updateInstalling { throw HelperRefusal(message: AppModel.updatingMessage) }
        model.startPresence(duration: seconds)
        if let error = model.lastError, !model.presenceActive { throw HelperRefusal(message: error) }
        publishSoon()
    }

    public func stopPresence() async throws {
        model.stopPresence()
        publishSoon()
    }

    public func setPresenceWhileClosed(_ on: Bool) async throws {
        model.setPresenceWhileClosed(on)
        publishSoon()
    }

    public func displayOff() async throws {
        model.displayOffFromPhone()
    }

    public func lockScreen() async throws {
        guard ScreenLock.lockNow() else { throw RemoteError.lockUnavailable }
    }

    public func setMuted(_ muted: Bool) async throws {
        try await model.lidCoordinator.setMuted(muted, saved: model.status?.userChanges.audio ?? [])
        publishSoon()
    }

    public func pauseApps() async throws {
        guard let status = model.status, status.session != nil else { throw RemoteError.notDuringSession }
        let keeping = Set(agents.map(\.pid)).union(status.session?.watching.map(\.pid) ?? [])
        try await model.lidCoordinator.pauseApps(status.settings.lid.pausedApps, alreadyPaused: Set(status.frozen.map(\.bundleID)), keeping: keeping)
    }

    public func resumeApps() async throws {
        try await model.lidCoordinator.resumeApps(model.status?.frozen.map(\.bundleID) ?? [])
    }
}
