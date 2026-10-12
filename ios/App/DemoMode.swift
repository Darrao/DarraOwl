import CryptoKit
import DarraOwlPhoneKit
import DarraOwlShared
import Foundation

/// App Store screenshots and App Review: launched with `-DarraOwlDemo`, the
/// app shows a believable Mac without one. Never active otherwise.
enum DemoMode {
    static var isOn: Bool { CommandLine.arguments.contains("-DarraOwlDemo") }
    /// `-DarraOwlDemo -DarraOwlDemoOnboarding`: not paired yet.
    static var onboarding: Bool { CommandLine.arguments.contains("-DarraOwlDemoOnboarding") }

    @MainActor
    static func dependencies(forcePaired: Bool = false) -> PhoneModel.Dependencies {
        let onboarding = Self.onboarding && !forcePaired
        let mac = PairedMac(macID: macID, macName: "MacBook Pro", agreementKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                            endpoints: nil, pairedAt: Date())
        return .init(store: DemoStore(mac: onboarding ? nil : mac), direct: DemoDirect(), cloud: DemoCloud(), pairing: DemoPairing())
    }

    static let macID = UUID()

    static let demoAgents: [MacState.Agent] = {
        let now = Date()
        return [
            .init(tool: "claude", project: "site-vitrine", since: now.addingTimeInterval(-2300), waitingForApproval: true, pid: 4101),
            .init(tool: "codex", project: "api", since: now.addingTimeInterval(-900), waitingForApproval: false, pid: 4102),
        ]
    }()

    /// The demonstration Mac: every button changes it, as on a real one.
    struct Mac {
        var end: Date? = Date().addingTimeInterval(6420)
        /// One id per session, as on a real Mac (the watch counts on it).
        var sessionID = UUID()
        var watching: [Int32] = []
        var presence = MacState.Presence(active: false, until: nil, whileClosed: false)
        var muted = false
        var agents = DemoMode.demoAgents
        var containers: [MacState.Container] = [.init(id: "3f9a2c1b7d4e", name: "postgres"), .init(id: "8b1e5d2a9c0f", name: "redis")]
        var pausedApps = ["Slack", "WhatsApp"]
        var dockerPaused = false
        var settings = PowerSettings.default

        var state: MacState {
            let now = Date()
            let followed = watching.compactMap { pid in
                agents.first { $0.pid == pid }.map {
                    WatchedProcess(pid: pid, name: $0.tool, project: $0.project, startSeconds: 0, startMicros: 0)
                }
            }
            return MacState(
                macID: DemoMode.macID, macName: "MacBook Pro", updatedAt: now, power: .awake,
                session: end.map { Session(id: sessionID, startedAt: now.addingTimeInterval(-2400), endsAt: $0, origin: .phone, watching: followed) },
                powerSnapshot: PowerSnapshot(battery: .percent(82), onExternalPower: false, thermal: .nominal, lidClosed: true, minutesToEmpty: 310),
                lowPowerActive: end != nil, pausedApps: end == nil ? [] : pausedApps,
                network: .init(kind: .hotspot, name: "iPhone", sessionBytes: 184_000_000),
                agents: agents, containers: containers,
                dockerPaused: end != nil && dockerPaused, settings: settings, presence: presence, muted: muted,
                dockerRunning: true
            )
        }

        /// What the Mac would answer: nil when done, else why not.
        mutating func apply(_ kind: CommandKind) -> String? {
            switch kind {
            case let .startSession(m):
                guard end == nil else { return "Une session est déjà en cours." }
                end = Date().addingTimeInterval(CommandKind.seconds(m))
                sessionID = UUID()
            case let .extendSession(m):
                guard let current = end else { return "Aucune session en cours." }
                end = max(current, Date()).addingTimeInterval(CommandKind.seconds(m))
            case .stopSession, .sleepNow:
                end = nil
                watching = []
                dockerPaused = false
            case let .watchAgent(pid):
                if end == nil {
                    end = Date().addingTimeInterval(settings.maxSessionDuration)
                    sessionID = UUID()
                }
                if !watching.contains(pid) { watching.append(pid) }
            case let .stopAgent(pid):
                agents.removeAll { $0.pid == pid }
                watching.removeAll { $0 == pid }
            case let .startPresence(m):
                presence = .init(active: true, until: m.map { Date().addingTimeInterval(CommandKind.seconds($0)) }, whileClosed: presence.whileClosed)
            case .stopPresence:
                presence = .init(active: false, until: nil, whileClosed: presence.whileClosed)
            case let .setPresenceWhileClosed(on):
                presence.whileClosed = on
            case let .setMuted(value):
                muted = value
            case .pauseDocker:
                guard end != nil else { return "Possible seulement pendant une session." }
                dockerPaused = true
            case .resumeDocker:
                dockerPaused = false
            case let .stopContainer(id):
                containers.removeAll { $0.id == id }
            case .pauseApps:
                guard end != nil else { return "Possible seulement pendant une session." }
                pausedApps = ["Slack", "WhatsApp", "Discord"]
            case .resumeApps:
                pausedApps = []
            case let .updateLidSettings(lid):
                settings.lid = lid
            case let .updateBatteryFloors(lowPower, endFloor):
                settings.lowPowerFloor = lowPower
                settings.endFloor = endFloor
            case let .updateAlerts(alerts):
                settings.alerts = alerts
            case .displayOff, .lockScreen, .forgetThisDevice:
                break
            }
            return nil
        }
    }

}

@MainActor
private final class DemoStore: PhoneStore {
    let mac: PairedMac?
    let id = PhoneIdentity(deviceID: UUID(), deviceName: "iPhone", agreementKey: .init(), signingKey: .init(), biometric: SoftwareBiometricSigner())
    init(mac: PairedMac?) { self.mac = mac }
    func identity() throws -> PhoneIdentity { id }
    func pairedMac() -> PairedMac? { mac }
    func save(_ mac: PairedMac) throws {}
    func forgetMac() throws {}
}

@MainActor
private final class DemoDirect: DirectLink {
    var path: ConnectionPath?
    var onState: ((MacState) -> Void)?
    var onResult: ((CommandResult) -> Void)?
    var onPathChange: ((ConnectionPath?) -> Void)?
    private var mac = DemoMode.Mac()

    func connect(to mac: PairedMac, identity: PhoneIdentity) {
        path = .local
        onPathChange?(.local)
        onState?(self.mac.state)
    }

    func disconnect() {}

    func send(_ command: SignedCommand) throws {
        guard let env = try? LinkCoding.decoder().decode(CommandEnvelope.self, from: command.payload) else { return }
        let refusal = mac.apply(env.kind)
        let result = CommandResult(commandID: env.id, status: refusal == nil ? .executed : .failed, message: refusal, at: Date())
        let state = mac.state
        // Like a real Mac: the answer comes a moment later, not inside send().
        Task { @MainActor in
            self.onResult?(result)
            self.onState?(state)
        }
    }

    func requestState() { onState?(mac.state) }
}

@MainActor
private final class DemoCloud: CloudLink {
    func accountProblem() async -> String? { nil }
    func fetchState(macID: UUID) async throws -> (state: MacState, endpoints: Endpoints?)? { nil }
    func send(_ command: SignedCommand, macID: UUID) async throws {}
    func result(for commandID: UUID) async throws -> CommandResult? { nil }
    func sendPairing(_ request: PairingRequest) async throws -> String { "" }
    func pairingResponse(requestID: String) async throws -> PairingResponse? { nil }
    func subscribeToEvents() async throws {}
    func unsubscribeFromEvents() async throws {}
}

@MainActor
private final class DemoPairing: PairingDirect {
    func pair(_ request: PairingRequest, invite: PairingInvite) async throws -> PairingResponse {
        PairingResponse(accepted: true, macID: invite.macID, macName: invite.macName, message: nil)
    }
}
