import CryptoKit
import DarraOwlShared
@testable import DarraOwlPhoneKit
import Foundation
import Synchronization
import Testing

final class Clock: Sendable {
    private let date = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    var now: Date { date.withLock { $0 } }
    func advance(_ s: Double) { date.withLock { $0 = $0.addingTimeInterval(s) } }
}

/// Sleeping only moves the fake clock.
struct ClockSleeper: Sleeper {
    let clock: Clock
    func sleep(seconds: Double) async {
        clock.advance(seconds)
        await Task.yield()
    }
}

@MainActor
final class FakePhoneStore: PhoneStore {
    let id: PhoneIdentity
    var mac: PairedMac?
    init() {
        id = PhoneIdentity(deviceID: UUID(), deviceName: "iPhone de test",
                           agreementKey: .init(), signingKey: .init(), biometric: SoftwareBiometricSigner())
    }
    func identity() throws -> PhoneIdentity { id }
    func pairedMac() -> PairedMac? { mac }
    func save(_ mac: PairedMac) throws { self.mac = mac }
    func forgetMac() throws { mac = nil }
}

@MainActor
final class FakeDirect: DirectLink {
    var path: ConnectionPath?
    var onState: ((MacState) -> Void)?
    var onResult: ((CommandResult) -> Void)?
    var onPathChange: ((ConnectionPath?) -> Void)?
    var connects = 0
    var sent: [SignedCommand] = []
    var reply: CommandResult.Status? = .executed
    var connectTo: ConnectionPath?

    func connect(to mac: PairedMac, identity: PhoneIdentity) {
        connects += 1
        path = connectTo
        onPathChange?(path)
    }
    func disconnect() { path = nil; onPathChange?(nil) }
    func send(_ command: SignedCommand) throws {
        sent.append(command)
        guard let reply, let env = try? LinkCoding.decoder().decode(CommandEnvelope.self, from: command.payload) else { return }
        let result = CommandResult(commandID: env.id, status: reply, message: nil, at: Date())
        Task { @MainActor in self.onResult?(result) }
    }
    func requestState() {}
}

@MainActor
final class FakeCloudLink: CloudLink {
    var problem: String?
    var state: (MacState, Endpoints?)?
    var sent: [SignedCommand] = []
    var answer: CommandResult.Status? = .executed
    var answerAfterPolls = 1
    var polls = 0
    var pairingResponse: PairingResponse?
    var pairingRequests: [PairingRequest] = []

    func accountProblem() async -> String? { problem }
    func fetchState(macID: UUID) async throws -> (state: MacState, endpoints: Endpoints?)? { state }
    func send(_ command: SignedCommand, macID: UUID) async throws { sent.append(command) }
    func result(for commandID: UUID) async throws -> CommandResult? {
        polls += 1
        guard let answer, polls >= answerAfterPolls else { return nil }
        return CommandResult(commandID: commandID, status: answer, message: answer == .executed ? nil : "Refusé", at: Date())
    }
    func sendPairing(_ request: PairingRequest) async throws -> String {
        pairingRequests.append(request)
        return "req-1"
    }
    func pairingResponse(requestID: String) async throws -> PairingResponse? { pairingResponse }
    var subscribed = 0
    func subscribeToEvents() async throws { subscribed += 1 }
}

@MainActor
final class FakePairingDirect: PairingDirect {
    var response: PairingResponse?
    var calls = 0
    func pair(_ request: PairingRequest, invite: PairingInvite) async throws -> PairingResponse {
        calls += 1
        guard let response else { throw URLError(.cannotConnectToHost) }
        return response
    }
}

@MainActor
struct PhoneRig {
    let clock = Clock()
    let store = FakePhoneStore()
    let direct = FakeDirect()
    let cloud = FakeCloudLink()
    let pairing = FakePairingDirect()
    let model: PhoneModel
    let macKey = Curve25519.KeyAgreement.PrivateKey()
    let macID = UUID()

    init() {
        let clock = clock
        model = PhoneModel(.init(store: store, direct: direct, cloud: cloud, pairing: pairing,
                                 now: { clock.now }, sleeper: ClockSleeper(clock: clock)))
    }

    var pairedMac: PairedMac {
        PairedMac(macID: macID, macName: "MacBook", agreementKey: macKey.publicKey.rawRepresentation,
                  endpoints: Endpoints(port: 52525, local: ["192.168.1.20"], tailscale: "100.100.1.2"), pairedAt: clock.now)
    }

    func invite(endpoints: Endpoints? = Endpoints(port: 60000, local: ["192.168.1.20"], tailscale: nil)) -> PairingInvite {
        PairingInvite(macID: macID, macName: "MacBook", macAgreementKey: macKey.publicKey.rawRepresentation,
                      secret: Data(repeating: 9, count: 32), expiresAt: clock.now.addingTimeInterval(300), endpoints: endpoints)
    }

    func state(power: MacState.Power = .awake, at date: Date? = nil) -> MacState {
        MacState(macID: macID, macName: "MacBook", updatedAt: date ?? clock.now, power: power, session: nil,
                 powerSnapshot: nil, lowPowerActive: false, pausedApps: [], network: nil, dockerPaused: false, settings: .default)
    }

    func paired() async -> PhoneRig {
        store.mac = pairedMac
        await model.start()
        return self
    }
}

@MainActor
@Suite struct PhoneCommandTests {
    @Test func directPathFirst() async throws {
        let rig = PhoneRig()
        rig.direct.connectTo = .local
        _ = await rig.paired()
        #expect(rig.model.directPath == .local)

        await rig.model.send(.extendSession(minutes: 60))

        #expect(rig.direct.sent.count == 1)
        #expect(rig.cloud.sent.isEmpty)
        #expect(rig.model.outcome == .done("Prolonger de 1 h : fait."))
    }

    @Test func cloudWhenNoDirectPath() async throws {
        let rig = await PhoneRig().paired()
        rig.cloud.answerAfterPolls = 3
        await rig.model.send(.stopSession)
        #expect(rig.cloud.sent.count == 1)
        #expect(rig.cloud.polls == 3)
        #expect(rig.model.outcome == .done("Arrêter la session : fait."))
    }

    @Test func noDirectAnswerFallsBackToCloudWithTheSameCommand() async throws {
        let rig = PhoneRig()
        rig.direct.connectTo = .tailscale
        rig.direct.reply = nil
        _ = await rig.paired()
        await rig.model.send(.stopSession)
        #expect(rig.direct.sent.count == 1)
        #expect(rig.cloud.sent == rig.direct.sent, "same id, so the Mac runs it at most once")
    }

    @Test func noAnswerBeforeExpiry() async throws {
        let rig = await PhoneRig().paired()
        rig.cloud.answer = nil
        await rig.model.send(.stopSession)
        guard case .failed = rig.model.outcome else { Issue.record("expected failure"); return }
    }

    @Test func refusalShowsTheMacMessage() async throws {
        let rig = await PhoneRig().paired()
        rig.cloud.answer = .rejected
        await rig.model.send(.startSession(minutes: 60))
        #expect(rig.model.outcome == .failed("Refusé"))
    }

    @Test func signaturesVerifyAndSensitiveCommandsCarryFaceID() async throws {
        let rig = await PhoneRig().paired()
        await rig.model.send(.sleepNow)
        let signed = try #require(rig.cloud.sent.first)
        let id = rig.store.id
        #expect(id.signingKey.publicKey.isValidSignature(signed.signature, for: signed.payload))
        let bio = try P256.Signing.ECDSASignature(derRepresentation: try #require(signed.biometricSignature))
        let bioKey = try P256.Signing.PublicKey(x963Representation: id.biometric.publicKey)
        #expect(bioKey.isValidSignature(bio, for: signed.payload))
        let env = try LinkCoding.decoder().decode(CommandEnvelope.self, from: signed.payload)
        #expect(env.macID == rig.macID)
        #expect(env.expiresAt.timeIntervalSince(env.issuedAt) == 60)
    }

    @Test func fireSendsWithoutWaiting() async throws {
        let rig = await PhoneRig().paired()
        rig.cloud.answer = nil
        #expect(await rig.model.fire(.extendSession(minutes: 60)))
        #expect(rig.cloud.sent.count == 1)
        #expect(rig.cloud.polls == 0)
    }

    @Test func stateChangesAreReported() async throws {
        let rig = PhoneRig()
        rig.direct.connectTo = .local
        _ = await rig.paired()
        var seen: MacState?
        rig.model.onStateChange = { seen = $0 }
        rig.direct.onState?(rig.state())
        #expect(seen?.macName == "MacBook")
    }

    @Test func plainCommandsHaveNoFaceIDSignature() async throws {
        let rig = await PhoneRig().paired()
        await rig.model.send(.extendSession(minutes: 30))
        #expect(rig.cloud.sent.first?.biometricSignature == nil)
    }
}

@MainActor
@Suite struct PhonePairingTests {
    @Test func pairsDirectlyWhenTheMacIsReachable() async throws {
        let rig = PhoneRig()
        rig.pairing.response = PairingResponse(accepted: true, macID: rig.macID, macName: "MacBook Pro", message: nil)
        await rig.model.pair(url: try rig.invite().url())
        #expect(rig.model.mac?.macName == "MacBook Pro")
        #expect(rig.store.mac?.agreementKey == rig.macKey.publicKey.rawRepresentation)
        #expect(rig.cloud.pairingRequests.isEmpty)
    }

    @Test func fallsBackToCloud() async throws {
        let rig = PhoneRig()
        rig.cloud.pairingResponse = PairingResponse(accepted: true, macID: rig.macID, macName: "MacBook", message: nil)
        await rig.model.pair(url: try rig.invite().url())
        #expect(rig.pairing.calls == 1)
        #expect(rig.cloud.pairingRequests.count == 1)
        #expect(rig.model.mac != nil)
    }

    @Test func pairingSubscribesToEvents() async throws {
        let rig = PhoneRig()
        rig.pairing.response = PairingResponse(accepted: true, macID: rig.macID, macName: "MacBook", message: nil)
        await rig.model.pair(url: try rig.invite().url())
        #expect(rig.cloud.subscribed == 1)
    }

    @Test func notificationButtonsSendCommands() async throws {
        let rig = await PhoneRig().paired()
        await rig.model.handleNotificationAction(MacEvent.extendAction)
        await rig.model.handleNotificationAction(MacEvent.stopAction)
        let kinds = try rig.cloud.sent.map { try LinkCoding.decoder().decode(CommandEnvelope.self, from: $0.payload).kind }
        #expect(kinds == [.extendSession(minutes: 60), .stopSession])
    }

    @Test func refusalIsShown() async throws {
        let rig = PhoneRig()
        rig.pairing.response = PairingResponse(accepted: false, macID: rig.macID, macName: "MacBook", message: "Code invalide.")
        await rig.model.pair(url: try rig.invite().url())
        #expect(rig.model.mac == nil)
        #expect(rig.model.pairingError == "Code invalide.")
    }

    @Test func expiredCodeIsRefusedLocally() async throws {
        let rig = PhoneRig()
        let url = try rig.invite().url()
        rig.clock.advance(301)
        await rig.model.pair(url: url)
        #expect(rig.pairing.calls == 0)
        #expect(rig.model.pairingError?.contains("expiré") == true)
    }

    @Test func foreignLinkIsRefused() async {
        let rig = PhoneRig()
        await rig.model.pair(url: URL(string: "https://example.com/pair")!)
        #expect(rig.model.pairingError == "Ce code n'est pas un code DarraOwl.")
    }

    @Test func phoneAndMacDeriveTheSameLinkKey() throws {
        let rig = PhoneRig()
        let id = rig.store.id
        let phoneKey = try id.linkKey(for: rig.pairedMac)
        let macShared = try rig.macKey.sharedSecretFromKeyAgreement(with: id.agreementKey.publicKey)
        #expect(phoneKey == LinkKeys.linkKey(shared: macShared, macID: rig.macID, deviceID: id.deviceID))
    }

    @Test func unpairForgetsTheMac() async {
        let rig = await PhoneRig().paired()
        rig.model.unpair()
        #expect(rig.store.mac == nil && rig.model.mac == nil)
    }
}

@MainActor
@Suite struct PresenceAndStateTests {
    @Test func presence() {
        let rig = PhoneRig()
        let now = rig.clock.now
        #expect(MacPresence.from(state: nil, directPath: .local, now: now) == .online(.local))
        #expect(MacPresence.from(state: nil, directPath: nil, now: now) == .unknown)
        #expect(MacPresence.from(state: rig.state(at: now.addingTimeInterval(-100)), directPath: nil, now: now) == .online(.icloud))
        #expect(MacPresence.from(state: rig.state(at: now.addingTimeInterval(-200)), directPath: nil, now: now) == .lastSeen(now.addingTimeInterval(-200)))
        #expect(MacPresence.from(state: rig.state(power: .asleep, at: now.addingTimeInterval(-10)), directPath: nil, now: now) == .asleep(since: now.addingTimeInterval(-10)))
    }

    @Test func cloudStateUpdatesEndpoints() async {
        let rig = PhoneRig()
        let newEndpoints = Endpoints(port: 52525, local: ["172.20.10.3"], tailscale: nil)
        rig.cloud.state = (rig.state(), newEndpoints)
        _ = await rig.paired()
        #expect(rig.model.state?.macName == "MacBook")
        #expect(rig.store.mac?.endpoints == newEndpoints)
    }

    @Test func stateFromAnotherMacIsIgnored() async {
        let rig = PhoneRig()
        rig.direct.connectTo = .local
        _ = await rig.paired()
        var other = rig.state()
        other.macID = UUID()
        rig.direct.onState?(other)
        #expect(rig.model.state == nil)
    }

    @Test func candidatesLocalThenTailscale() {
        let c = PathPlanner.candidates(endpoints: Endpoints(port: 52525, local: ["192.168.1.20", "172.20.10.3"], tailscale: "100.64.1.1"))
        #expect(c.map(\.path) == [.local, .local, .tailscale])
        #expect(PathPlanner.candidates(endpoints: nil).isEmpty)
    }
}
