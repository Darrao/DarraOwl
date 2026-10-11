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
    public private(set) var macPower: MacState.Power = .awake
    public private(set) var containers: [MacState.Container] = []
    public private(set) var lastResult: CommandResult?

    @ObservationIgnored private unowned let model: AppModel
    @ObservationIgnored private let store = KeychainPairingStore()
    @ObservationIgnored private var hub: RemoteHub!
    @ObservationIgnored private var server: LinkServer?
    @ObservationIgnored private var cloud: CloudKitMailbox?
    @ObservationIgnored private let network = NetworkInfo()
    @ObservationIgnored private let docker = DockerControl()
    @ObservationIgnored private let log = OSLogEngineLogger(category: "remote")
    @ObservationIgnored private var lastBroadcast: MacState?
    @ObservationIgnored private var tick = 0
    @ObservationIgnored private var started = false
    @ObservationIgnored private var accountProblem: String?
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

    var serverPort: UInt16? { server?.port }
    var serverProblem: String? { server?.lastError }
    var connectedDevices: Set<UUID> { server?.connectedDevices ?? [] }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        let identity: MacIdentity
        do {
            identity = try store.identity()
        } catch {
            cloudProblem = "Trousseau : \(error.localizedDescription)"
            return
        }
        let cloud = CloudKitMailbox(macID: identity.macID)
        self.cloud = cloud
        hub = RemoteHub(
            store: store, target: self, cloud: cloud,
            ledgerStore: JSONFileStore<CommandLedger>(directory: Self.appSupport, fileName: "commands.json"),
            clock: SystemClock(), log: log
        )
        hub.onResult = { [weak self] result in
            self?.lastResult = result
            self?.server?.broadcast(.result(result))
        }
        hub.onPaired = { [weak self] _, _ in
            guard let self else { return }
            self.devices = self.hub.pairedDevices()
            self.server?.stopPairing()
            self.invite = nil
            self.restartServer()
        }
        hub.onDeviceRemoved = { [weak self] id in
            self?.server?.disconnect(deviceID: id)
            self?.restartServer()
        }
        server = LinkServer(macID: identity.macID, macName: macName, handlers: .init(
            message: { [weak self] deviceID, message in await self?.answer(deviceID, message) },
            pairing: { [weak self] request in self?.pair(request) ?? PairingResponse(accepted: false, macID: identity.macID, macName: "", message: nil) },
            isPaired: { [weak self] id in self?.devices.contains { $0.id == id } ?? false }
        ))
        network.onChange = { [weak self] in self?.publishSoon() }
        let hooks = HookServer(token: HookToken.current()) { [weak self] parsed in self?.handleHook(parsed) }
        hooks.start()
        hookServer = hooks
        agents = AgentScanner.scan()
        network.start()
        devices = hub.pairedDevices()
        restartServer()
        observeSleep()
        Task {
            accountProblem = await cloud.accountProblem()
            await refreshContainers()
            await publish(force: true)
            await hub.pollCloud(macName: macName)
        }
    }

    /// Called every second by the app model.
    func everySecond() {
        guard started else { return }
        tick += 1
        if tick % 2 == 0 { Task { await publish() } }
        let pollEvery = model.session == nil ? 60 : 20
        if tick % pollEvery == 0 { Task { await hub.pollCloud(macName: macName) } }
        if tick % 30 == 0 { Task { await refreshContainers() } }
        if tick % 5 == 0 { checkEvents() }
        if tick % 10 == 0 { refreshAgents() }
        if tick % 3600 == 0 { Task { await cloud?.removeEvents(before: Date().addingTimeInterval(-86_400)) } }
        if let invite, Date() > invite.expiresAt { cancelInvite() }
        let problem = accountProblem ?? hub.cloudError.map { "iCloud : \($0)" }
        if problem != cloudProblem { cloudProblem = problem }
    }

    /// A silent push from CloudKit: the phone wrote something.
    func cloudChanged() {
        guard started else { return }
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
        guard let event, nobodyAtTheMac else { return }
        Task { await hub.post([event]) }
    }

    private var nobodyAtTheMac: Bool {
        if model.lidClosed { return true }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        return idle >= 60
    }

    var hookSnippet: String {
        ClaudeHook.settingsSnippet(port: HookServer.port, token: HookToken.current())
    }

    // MARK: Events

    private func checkEvents() {
        guard let status = model.status else { return }
        sessionBytes = dataMeter.update(session: status.session?.id, counter: NetworkInfo.byteCounter())
        let found = events.update(EventCenter.Input(
            now: Date(), session: status.session, power: status.power, networkUp: network.isUp,
            sessionBytes: sessionBytes, lastEnd: status.lastEnd, alerts: status.settings.alerts,
            agentsDuringSession: agentsSeenInSession.tools
        ))
        if !found.isEmpty || !hub.pendingEvents.isEmpty {
            Task { await hub.post(found) }
        }
    }

    // MARK: Pairing

    func showInvite() {
        guard let hub else { return }
        do {
            var endpoints = currentEndpoints()
            let invite = try hub.makeInvite(macName: macName, endpoints: endpoints)
            server?.startPairing(identity: LinkKeys.pairingIdentity(secret: invite.secret), key: LinkKeys.pairingKey(secret: invite.secret, macID: invite.macID))
            // The pairing listener has its own port; wait for it, then put it in the code.
            Task {
                for _ in 0..<20 where server?.pairingPort == nil {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard let port = server?.pairingPort, self.hub.invite?.secret == invite.secret else { return }
                endpoints?.port = port
                var withPort = invite
                withPort.endpoints = endpoints
                self.invite = withPort
            }
        } catch {
            cloudProblem = "Appairage : \(error.localizedDescription)"
        }
    }

    func cancelInvite() {
        hub?.cancelInvite()
        server?.stopPairing()
        invite = nil
    }

    func unpair(_ device: PairedDevice) {
        do {
            try hub.unpair(deviceID: device.id)
        } catch {
            cloudProblem = "Désappairage : \(error.localizedDescription)"
        }
        devices = hub.pairedDevices()
    }

    private func pair(_ request: PairingRequest) -> PairingResponse {
        hub.handlePairing(request, macName: macName, via: .direct)
    }

    // MARK: Direct link

    private func answer(_ deviceID: UUID, _ message: ClientMessage) async -> ServerMessage? {
        switch message {
        case .getState:
            return makeState().map { .state($0) }
        case let .command(signed):
            return .result(await hub.handle(signed, via: .direct, peer: deviceID))
        case .hello, .pair:
            return nil
        }
    }

    private func restartServer() {
        let keys = devices.compactMap { d in hub.linkKey(deviceID: d.id).map { (deviceID: d.id, key: $0) } }
        server?.start(keys: keys)
    }

    // MARK: State

    func makeState() -> MacState? {
        guard let status = model.status, let identity = try? store.identity() else { return nil }
        return MacState(
            macID: identity.macID, macName: macName, updatedAt: Date(), power: macPower,
            session: status.session, powerSnapshot: status.power, lowPowerActive: status.lowPowerHeld,
            pausedApps: Set(status.frozen.map(\.name)).sorted(),
            network: MacState.Network(kind: network.kind, sessionBytes: sessionBytes),
            agents: signals.states(agents, now: Date(), mask: status.settings.alerts.maskProjectNames),
            containers: containers,
            dockerPaused: status.frozen.contains { $0.bundleID == PausePolicy.dockerBundleID },
            settings: status.settings
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
        guard let state = makeState() else { return }
        if lastBroadcast.map({ !RemoteHub.sameContent($0, state) }) ?? true {
            server?.broadcast(.state(state))
            lastBroadcast = state
        }
        await hub.publishIfDue(state, endpoints: currentEndpoints(), force: force)
    }

    private func refreshContainers() async {
        containers = await docker.containers()
    }

    private func observeSleep() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.macPower = .goingToSleep
                await self?.publish(force: true)
            }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.macPower = .awake
                await self?.publish(force: true)
                if let self { await self.hub.pollCloud(macName: self.macName) }
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
        _ = try await model.sendHelper(.stop(reason: .userStopped))
    }

    public func sleepNow() async throws {
        // Brightness and sound first: the helper cannot put them back.
        if let changes = model.status?.userChanges, !changes.isEmpty {
            await model.lidCoordinator.restore(changes)
        }
        macPower = .goingToSleep
        await publish(force: true)
        _ = try await model.sendHelper(.sleepNow)
    }

    public func pauseDocker() async throws {
        guard model.session != nil else { throw RemoteError.notDuringSession }
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
}
