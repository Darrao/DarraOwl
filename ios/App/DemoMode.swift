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

    static func state(sessionEnd: Date?) -> MacState {
        let now = Date()
        return MacState(
            macID: macID, macName: "MacBook Pro", updatedAt: now, power: .awake,
            session: sessionEnd.map { Session(startedAt: now.addingTimeInterval(-2400), endsAt: $0, origin: .phone) },
            powerSnapshot: PowerSnapshot(battery: .percent(82), onExternalPower: false, thermal: .nominal, lidClosed: true, minutesToEmpty: 310),
            lowPowerActive: true, pausedApps: ["Slack", "WhatsApp"],
            network: .init(kind: .hotspot, name: "iPhone", sessionBytes: 184_000_000),
            agents: [
                .init(tool: "claude", project: "site-vitrine", since: now.addingTimeInterval(-2300), waitingForApproval: true),
                .init(tool: "codex", project: "api", since: now.addingTimeInterval(-900), waitingForApproval: false),
            ],
            containers: [.init(id: "3f9a2c1b7d4e", name: "postgres"), .init(id: "8b1e5d2a9c0f", name: "redis")],
            dockerPaused: false, settings: .default
        )
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
    private var end: Date? = Date().addingTimeInterval(6420)

    func connect(to mac: PairedMac, identity: PhoneIdentity) {
        path = .local
        onPathChange?(.local)
        onState?(DemoMode.state(sessionEnd: end))
    }

    func disconnect() {}

    func send(_ command: SignedCommand) throws {
        guard let env = try? LinkCoding.decoder().decode(CommandEnvelope.self, from: command.payload) else { return }
        switch env.kind {
        case let .extendSession(m): end = (end ?? Date()).addingTimeInterval(TimeInterval(m * 60))
        case let .startSession(m): end = Date().addingTimeInterval(TimeInterval(m * 60))
        case .stopSession, .sleepNow: end = nil
        default: break
        }
        onResult?(CommandResult(commandID: env.id, status: .executed, message: nil, at: Date()))
        onState?(DemoMode.state(sessionEnd: end))
    }

    func requestState() { onState?(DemoMode.state(sessionEnd: end)) }
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
}

@MainActor
private final class DemoPairing: PairingDirect {
    func pair(_ request: PairingRequest, invite: PairingInvite) async throws -> PairingResponse {
        PairingResponse(accepted: true, macID: invite.macID, macName: invite.macName, message: nil)
    }
}
