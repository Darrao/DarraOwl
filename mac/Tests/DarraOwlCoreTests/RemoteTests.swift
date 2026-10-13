import CryptoKit
@testable import DarraOwlCore
import DarraOwlShared
import Foundation
import Testing

/// A phone with real keys, in memory. The Secure Enclave key is a software
/// P-256 key here.
struct TestPhone {
    let id = UUID()
    let agreement = Curve25519.KeyAgreement.PrivateKey()
    let signing = Curve25519.Signing.PrivateKey()
    let biometric = P256.Signing.PrivateKey()

    func pairingRequest(for invite: PairingInvite, at date: Date, secret: Data? = nil) -> PairingRequest {
        PairingRequest(
            macID: invite.macID, deviceID: id, deviceName: "iPhone de test",
            agreementKey: agreement.publicKey.rawRepresentation, signingKey: signing.publicKey.rawRepresentation,
            biometricKey: biometric.publicKey.x963Representation, createdAt: date, secret: secret ?? invite.secret
        )
    }

    var device: PairedDevice {
        PairedDevice(id: id, name: "iPhone", agreementKey: agreement.publicKey.rawRepresentation,
                     signingKey: signing.publicKey.rawRepresentation, biometricKey: biometric.publicKey.x963Representation,
                     pairedAt: Date(timeIntervalSince1970: 0))
    }

    func sign(_ kind: CommandKind, mac: UUID, at date: Date, id: UUID = UUID(), faceID: Bool = false, lifetime: TimeInterval = 60) throws -> SignedCommand {
        let envelope = CommandEnvelope(id: id, kind: kind, deviceID: self.id, macID: mac, issuedAt: date, lifetime: lifetime)
        let payload = try LinkCoding.encoder().encode(envelope)
        return SignedCommand(
            deviceID: self.id, payload: payload,
            signature: try signing.signature(for: payload),
            biometricSignature: faceID ? try biometric.signature(for: payload).derRepresentation : nil
        )
    }
}

@MainActor
final class FakePairingStore: PairingStore {
    let mac = MacIdentity(macID: UUID(), agreementKey: Curve25519.KeyAgreement.PrivateKey())
    var stored: [PairedDevice] = []
    func identity() throws -> MacIdentity { mac }
    func devices() throws -> [PairedDevice] { stored }
    func add(_ device: PairedDevice) throws { stored.removeAll { $0.id == device.id }; stored.append(device) }
    func remove(deviceID: UUID) throws { stored.removeAll { $0.id == deviceID } }
}

@MainActor
final class FakeTarget: CommandTarget {
    var calls: [String] = []
    var currentSettings: PowerSettings? = .default
    var containerIDs: [String] = ["0123456789ab"]
    var fail = false
    /// When set, every command waits at this gate before it is recorded.
    var gate: AsyncGate?
    func record(_ s: String) async throws {
        if let gate { await gate.pass() }
        if fail { throw FakeError(message: "refusé") }
        calls.append(s)
    }
    func startSession(seconds: TimeInterval) async throws { try await record("start \(Int(seconds))") }
    func extendSession(seconds: TimeInterval) async throws { try await record("extend \(Int(seconds))") }
    func stopSession() async throws { try await record("stop") }
    func sleepNow() async throws { try await record("sleep") }
    func pauseDocker() async throws { try await record("pauseDocker") }
    func resumeDocker() async throws { try await record("resumeDocker") }
    func stopContainer(id: String) async throws { try await record("stopContainer \(id)") }
    func updateSettings(_ settings: PowerSettings) async throws { try await record("settings \(settings.lowPowerFloor)/\(settings.endFloor)"); currentSettings = settings }
    var agentPIDs: [Int32] = [4242]
    func watchAgent(pid: Int32) async throws { try await record("watch \(pid)") }
    func stopAgent(pid: Int32) async throws { try await record("stopAgent \(pid)") }
    func startPresence(seconds: TimeInterval?) async throws { try await record("presence \(seconds.map { Int($0) } ?? -1)") }
    func stopPresence() async throws { try await record("stopPresence") }
    func displayOff() async throws { try await record("displayOff") }
    func lockScreen() async throws { try await record("lock") }
    func setMuted(_ muted: Bool) async throws { try await record("muted \(muted)") }
    func pauseApps() async throws { try await record("pauseApps") }
    func resumeApps() async throws { try await record("resumeApps") }
    func setPresenceWhileClosed(_ on: Bool) async throws { try await record("whileClosed \(on)") }
    func answerAgentRequest(id: UUID, allow: Bool) async throws { try await record("agent \(allow ? "allow" : "deny")") }
}

@MainActor
final class FakeCloud: CloudMailbox {
    var published: [MacState] = []
    var failPublish = false
    var inbox = CloudInbox()
    var results: [CommandResult] = []
    var pairings: [PairingResponse] = []
    var discarded: [String] = []
    /// When set, publishing waits at this gate.
    var publishGate: AsyncGate?
    func publish(state: MacState, endpoints: Endpoints?) async throws {
        if let publishGate { await publishGate.pass() }
        if failPublish { throw FakeError(message: "Couldn't get container configuration") }
        published.append(state)
    }
    func fetchInbox() async throws -> CloudInbox { defer { inbox = CloudInbox() }; return inbox }
    var failDeliver = false
    func deliver(result: CommandResult) async throws {
        if failDeliver { throw FakeError(message: "offline") }
        results.append(result)
    }
    func deliver(pairing: PairingResponse, requestID: String) async throws { pairings.append(pairing) }
    func discard(itemIDs: [String]) async throws { discarded += itemIDs }
    var events: [MacEvent] = []
    var failEvents = false
    /// When set, posting waits at this gate.
    var postGate: AsyncGate?
    func post(_ event: MacEvent) async throws {
        if let postGate { await postGate.pass() }
        if failEvents { throw FakeError(message: "offline") }
        events.append(event)
    }
    func removeEvents(before date: Date) async {}
    var removedEvents: [UUID] = []
    func removeEvent(id: UUID) async { removedEvents.append(id) }
}

@MainActor
struct HubRig {
    let events = EventLog()
    let clock = FakeClock()
    let store = FakePairingStore()
    let target = FakeTarget()
    let cloud = FakeCloud()
    let ledger: InMemoryStore<CommandLedger>
    let hub: RemoteHub
    let phone = TestPhone()

    init() {
        ledger = InMemoryStore(name: "ledger", log: events)
        hub = RemoteHub(store: store, target: target, cloud: cloud, ledgerStore: ledger, clock: clock, log: SilentLog(),
                        random: { Data(repeating: 7, count: 32) })
    }

    func paired() -> HubRig {
        store.stored = [phone.device]
        return self
    }

    var macID: UUID { store.mac.macID }
}

@MainActor
@Suite struct CommandTests {
    @Test func validCommandRunsOnceAndIsRecorded() async throws {
        let rig = HubRig().paired()
        let cmd = try rig.phone.sign(.extendSession(minutes: 60), mac: rig.macID, at: rig.clock.now())

        let first = await rig.hub.handle(cmd, via: .direct, peer: rig.phone.id)
        let second = await rig.hub.handle(cmd, via: .cloud)

        #expect(first.status == .executed)
        #expect(second == first, "the iCloud copy gets the real result, not a bare duplicate")
        #expect(rig.target.calls == ["extend 3600"])
        #expect(rig.ledger.value?.results.map(\.status) == [.executed])
    }

    @Test func unpairedDeviceIsRefused() async throws {
        let rig = HubRig()
        let cmd = try rig.phone.sign(.stopSession, mac: rig.macID, at: rig.clock.now())
        #expect(await rig.hub.handle(cmd, via: .cloud).status == .unauthorized)
        #expect(rig.target.calls.isEmpty)
    }

    @Test func forgedSignatureIsRefused() async throws {
        let rig = HubRig().paired()
        var cmd = try rig.phone.sign(.stopSession, mac: rig.macID, at: rig.clock.now())
        let other = try LinkCoding.encoder().encode(CommandEnvelope(kind: .startSession(minutes: 600), deviceID: rig.phone.id, macID: rig.macID, issuedAt: rig.clock.now()))
        cmd.payload = other
        #expect(await rig.hub.handle(cmd, via: .cloud).status == .unauthorized)
        #expect(rig.target.calls.isEmpty)
    }

    @Test func commandForAnotherMacIsRefused() async throws {
        let rig = HubRig().paired()
        let cmd = try rig.phone.sign(.stopSession, mac: UUID(), at: rig.clock.now())
        #expect(await rig.hub.handle(cmd, via: .cloud).status == .unauthorized)
    }

    @Test func sensitiveCommandNeedsFaceIDSignature() async throws {
        let rig = HubRig().paired()
        let without = try rig.phone.sign(.sleepNow, mac: rig.macID, at: rig.clock.now())
        #expect(await rig.hub.handle(without, via: .cloud).status == .unauthorized)
        let with = try rig.phone.sign(.sleepNow, mac: rig.macID, at: rig.clock.now(), faceID: true)
        #expect(await rig.hub.handle(with, via: .cloud).status == .executed)
        #expect(rig.target.calls == ["sleep"])
    }

    @Test func expiredCommandIsRefused() async throws {
        let rig = HubRig().paired()
        let cmd = try rig.phone.sign(.stopSession, mac: rig.macID, at: rig.clock.now())
        rig.clock.advance(66)
        #expect(await rig.hub.handle(cmd, via: .cloud).status == .expired)
    }

    @Test func overlongLifetimeIsRefused() async throws {
        let rig = HubRig().paired()
        let cmd = try rig.phone.sign(.stopSession, mac: rig.macID, at: rig.clock.now(), lifetime: 3600)
        #expect(await rig.hub.handle(cmd, via: .cloud).status == .expired)
    }

    @Test func commandFromTheFutureIsRefused() async throws {
        let rig = HubRig().paired()
        let cmd = try rig.phone.sign(.stopSession, mac: rig.macID, at: rig.clock.now().addingTimeInterval(30))
        #expect(await rig.hub.handle(cmd, via: .cloud).status == .expired)
    }

    @Test(arguments: [
        CommandKind.extendSession(minutes: 45),
        .startSession(minutes: 0),
        .startSession(minutes: 25 * 60),
        .stopContainer(id: "../../etc"),
        .updateLidSettings(LidSettings(pausedApps: ["us.zoom.xos"])),
        .updateBatteryFloors(lowPower: 10, end: 15),
    ])
    func outOfPolicyArgumentsAreRefused(kind: CommandKind) async throws {
        let rig = HubRig().paired()
        let cmd = try rig.phone.sign(kind, mac: rig.macID, at: rig.clock.now(), faceID: true)
        #expect(await rig.hub.handle(cmd, via: .cloud).status == .rejected)
        #expect(rig.target.calls.isEmpty)
    }

    @Test func watchOnlyAPublishedAgent() async throws {
        let rig = HubRig().paired()
        let known = try rig.phone.sign(.watchAgent(pid: 4242), mac: rig.macID, at: rig.clock.now())
        let unknown = try rig.phone.sign(.watchAgent(pid: 1), mac: rig.macID, at: rig.clock.now())
        let gone = try rig.phone.sign(.watchAgent(pid: 777), mac: rig.macID, at: rig.clock.now())
        #expect(await rig.hub.handle(known, via: .cloud).status == .executed)
        #expect(await rig.hub.handle(unknown, via: .cloud).status == .rejected)
        #expect(await rig.hub.handle(gone, via: .cloud).status == .failed)
        #expect(rig.target.calls == ["watch 4242"])
    }

    @Test func controlsReachTheMac() async throws {
        let rig = HubRig().paired()
        let kinds: [CommandKind] = [.startPresence(minutes: nil), .startPresence(minutes: 90), .stopPresence, .displayOff,
                                    .lockScreen, .setMuted(true), .pauseApps, .resumeApps]
        for kind in kinds {
            let cmd = try rig.phone.sign(kind, mac: rig.macID, at: rig.clock.now())
            #expect(await rig.hub.handle(cmd, via: .direct).status == .executed, "\(kind)")
        }
        #expect(rig.target.calls == ["presence -1", "presence 5400", "stopPresence", "displayOff", "lock", "muted true", "pauseApps", "resumeApps"])
    }

    @Test func stopAgentNeedsFaceIDAndAPublishedAgent() async throws {
        let rig = HubRig().paired()
        let withoutFaceID = try rig.phone.sign(.stopAgent(pid: 4242), mac: rig.macID, at: rig.clock.now())
        #expect(await rig.hub.handle(withoutFaceID, via: .direct).status == .unauthorized)
        let unknown = try rig.phone.sign(.stopAgent(pid: 777), mac: rig.macID, at: rig.clock.now(), faceID: true)
        #expect(await rig.hub.handle(unknown, via: .direct).status == .failed)
        let known = try rig.phone.sign(.stopAgent(pid: 4242), mac: rig.macID, at: rig.clock.now(), faceID: true)
        #expect(await rig.hub.handle(known, via: .direct).status == .executed)
        #expect(rig.target.calls == ["stopAgent 4242"])
    }

    @Test func unknownContainerFails() async throws {
        let rig = HubRig().paired()
        let cmd = try rig.phone.sign(.stopContainer(id: "ffffffffffff"), mac: rig.macID, at: rig.clock.now(), faceID: true)
        #expect(await rig.hub.handle(cmd, via: .cloud).status == .failed)
        #expect(rig.target.calls.isEmpty)
    }

    @Test func directLinkPeerMustBeTheSigner() async throws {
        let rig = HubRig().paired()
        let cmd = try rig.phone.sign(.stopSession, mac: rig.macID, at: rig.clock.now())
        #expect(await rig.hub.handle(cmd, via: .direct, peer: UUID()).status == .unauthorized)
    }

    @Test func floorsMergeIntoCurrentSettings() async throws {
        let rig = HubRig().paired()
        let cmd = try rig.phone.sign(.updateBatteryFloors(lowPower: 50, end: 20), mac: rig.macID, at: rig.clock.now())
        #expect(await rig.hub.handle(cmd, via: .cloud).status == .executed)
        #expect(rig.target.currentSettings?.lid == LidSettings())
        #expect(rig.target.calls == ["settings 50/20"])
    }

    @Test func failureIsRecordedAndNotRetried() async throws {
        let rig = HubRig().paired()
        rig.target.fail = true
        let cmd = try rig.phone.sign(.stopSession, mac: rig.macID, at: rig.clock.now())
        #expect(await rig.hub.handle(cmd, via: .cloud).status == .failed)
        rig.target.fail = false
        #expect(await rig.hub.handle(cmd, via: .cloud).status == .failed, "not run again, its failure is reported")
        #expect(rig.target.calls.isEmpty)
    }

    @Test func aLateRefusedCopyNeverReplacesTheResult() async throws {
        let rig = HubRig().paired()
        let cmd = try rig.phone.sign(.stopSession, mac: rig.macID, at: rig.clock.now())
        #expect(await rig.hub.handle(cmd, via: .direct).status == .executed)
        // An hour later the seen id is pruned: the copy is refused as expired.
        rig.clock.advance(2 * 3600)
        #expect(await rig.hub.handle(cmd, via: .cloud).status == .executed)
        #expect(rig.ledger.value?.results.map(\.status) == [.executed])
        #expect(rig.target.calls == ["stop"])
    }

    @Test func theCloudCopyOfARunningCommandGetsTheRealResultWhenItEnds() async throws {
        let rig = HubRig().paired()
        rig.target.gate = AsyncGate()
        let cmd = try rig.phone.sign(.stopSession, mac: rig.macID, at: rig.clock.now())
        let direct = Task { await rig.hub.handle(cmd, via: .direct) }
        await rig.target.gate?.waitUntilEntered()
        // The phone gave up waiting on the direct link and sent the copy.
        rig.cloud.inbox = CloudInbox(commands: [("c1", cmd)])
        await rig.hub.pollCloud(macName: "MacBook")
        #expect(rig.cloud.results.isEmpty, "no bare duplicate while it runs")
        #expect(rig.cloud.discarded == ["c1"])
        rig.target.gate?.open()
        #expect(await direct.value.status == .executed)
        #expect(rig.cloud.results.map(\.status) == [.executed])
    }

    @Test func aResultNotWrittenToICloudIsWrittenAtTheNextPoll() async throws {
        let rig = HubRig().paired()
        rig.cloud.failDeliver = true
        let cmd = try rig.phone.sign(.stopSession, mac: rig.macID, at: rig.clock.now())
        rig.cloud.inbox = CloudInbox(commands: [("c1", cmd)])
        await rig.hub.pollCloud(macName: "MacBook")
        #expect(rig.cloud.results.isEmpty)
        rig.cloud.failDeliver = false
        await rig.hub.pollCloud(macName: "MacBook")
        #expect(rig.cloud.results.map(\.status) == [.executed])
        #expect(rig.target.calls == ["stop"])
    }

    @Test func overlongDurationsAreRefusedWithoutOverflow() async throws {
        let rig = HubRig().paired()
        let cmd = try rig.phone.sign(.startSession(minutes: Int.max), mac: rig.macID, at: rig.clock.now())
        #expect(await rig.hub.handle(cmd, via: .direct).status == .rejected)
        #expect(rig.target.calls.isEmpty)
    }

    @Test func unpairCutsAccessImmediately() async throws {
        let rig = HubRig().paired()
        var dropped: UUID?
        rig.hub.onDeviceRemoved = { dropped = $0 }
        try rig.hub.unpair(deviceID: rig.phone.id)
        #expect(dropped == rig.phone.id)
        #expect(rig.hub.linkKey(deviceID: rig.phone.id) == nil)
        let cmd = try rig.phone.sign(.stopSession, mac: rig.macID, at: rig.clock.now())
        #expect(await rig.hub.handle(cmd, via: .cloud).status == .unauthorized)
    }
}

@MainActor
@Suite struct PairingTests {
    @Test func inviteRoundTripsThroughURL() throws {
        let rig = HubRig()
        let invite = try rig.hub.makeInvite(macName: "MacBook", endpoints: Endpoints(port: 52525, local: ["192.168.1.20"], tailscale: nil))
        let parsed = try PairingInvite(url: invite.url())
        #expect(parsed == invite)
    }

    @Test func pairingStoresDeviceAndBothSidesDeriveTheSameLinkKey() throws {
        let rig = HubRig()
        let invite = try rig.hub.makeInvite(macName: "MacBook", endpoints: nil)
        let response = rig.hub.handlePairing(rig.phone.pairingRequest(for: invite, at: rig.clock.now()), macName: "MacBook")

        #expect(response.accepted)
        #expect(rig.store.stored.map(\.id) == [rig.phone.id])
        #expect(rig.hub.invite == nil, "an invite works once")

        let macKey = try #require(rig.hub.linkKey(deviceID: rig.phone.id))
        let macPublic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: invite.macAgreementKey)
        let phoneKey = LinkKeys.linkKey(shared: try rig.phone.agreement.sharedSecretFromKeyAgreement(with: macPublic), macID: invite.macID, deviceID: rig.phone.id)
        #expect(macKey == phoneKey)
    }

    @Test func wrongSecretIsRefused() throws {
        let rig = HubRig()
        let invite = try rig.hub.makeInvite(macName: "MacBook", endpoints: nil)
        let request = rig.phone.pairingRequest(for: invite, at: rig.clock.now(), secret: Data(repeating: 1, count: 32))
        #expect(!rig.hub.handlePairing(request, macName: "MacBook").accepted)
        #expect(rig.store.stored.isEmpty)
    }

    @Test func tamperedRequestIsRefused() throws {
        let rig = HubRig()
        let invite = try rig.hub.makeInvite(macName: "MacBook", endpoints: nil)
        var request = rig.phone.pairingRequest(for: invite, at: rig.clock.now())
        request.signingKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        #expect(!rig.hub.handlePairing(request, macName: "MacBook").accepted)
    }

    @Test func expiredInviteIsRefused() throws {
        let rig = HubRig()
        let invite = try rig.hub.makeInvite(macName: "MacBook", endpoints: nil)
        rig.clock.advance(PairingInvite.lifetime + 1)
        #expect(!rig.hub.handlePairing(rig.phone.pairingRequest(for: invite, at: rig.clock.now()), macName: "MacBook").accepted)
        #expect(rig.hub.pairingKey(identity: LinkKeys.pairingIdentity(secret: invite.secret)) == nil)
    }

    @Test func noInviteNoPairing() {
        let rig = HubRig()
        let fake = PairingInvite(macID: rig.macID, macName: "x", macAgreementKey: Data(count: 32), secret: Data(repeating: 7, count: 32), expiresAt: rig.clock.now().addingTimeInterval(60), endpoints: nil)
        #expect(!rig.hub.handlePairing(rig.phone.pairingRequest(for: fake, at: rig.clock.now()), macName: "x").accepted)
    }

    @Test func pairingKeyOnlyForTheInviteOnScreen() throws {
        let rig = HubRig()
        let invite = try rig.hub.makeInvite(macName: "MacBook", endpoints: nil)
        #expect(rig.hub.pairingKey(identity: LinkKeys.pairingIdentity(secret: invite.secret)) != nil)
        #expect(rig.hub.pairingKey(identity: "pair-0000000000000000") == nil)
    }

    @Test func malformedInviteURLsAreRefused() {
        for s in ["darraowl://pair", "https://pair?d=abc", "darraowl://pair?d=!!!", "darraowl://other?d=e30"] {
            #expect(throws: PairingError.malformedInvite) { _ = try PairingInvite(url: URL(string: s)!) }
        }
    }
}

@MainActor
@Suite struct CloudTests {
    func state(_ rig: HubRig, battery: Int = 80) -> MacState {
        MacState(macID: rig.macID, macName: "MacBook", updatedAt: rig.clock.now(), power: .awake, session: nil,
                 powerSnapshot: PowerSnapshot(battery: .percent(battery), onExternalPower: false, thermal: .nominal),
                 lowPowerActive: false, pausedApps: [], network: nil, dockerPaused: false, settings: .default)
    }

    @Test func publishesOnChangeAndHeartbeatOnly() async {
        let rig = HubRig()
        #expect(await rig.hub.publishIfDue(state(rig), endpoints: nil))
        rig.clock.advance(5)
        #expect(await !rig.hub.publishIfDue(state(rig), endpoints: nil), "same content, only the timestamp moved")
        #expect(await rig.hub.publishIfDue(state(rig, battery: 79), endpoints: nil))
        rig.clock.advance(1)
        #expect(await !rig.hub.publishIfDue(state(rig, battery: 78), endpoints: nil), "at most every 2 s")
        rig.clock.advance(60)
        #expect(await rig.hub.publishIfDue(state(rig, battery: 79), endpoints: nil), "heartbeat")
        #expect(rig.cloud.published.count == 3)
    }

    @Test func failuresBackOff() async {
        let rig = HubRig()
        rig.cloud.failPublish = true
        #expect(await !rig.hub.publishIfDue(state(rig), endpoints: nil))
        #expect(rig.hub.cloudError != nil)
        rig.cloud.failPublish = false
        rig.clock.advance(10)
        #expect(await !rig.hub.publishIfDue(state(rig, battery: 70), endpoints: nil), "still backing off")
        rig.clock.advance(25)
        #expect(await rig.hub.publishIfDue(state(rig, battery: 70), endpoints: nil))
        #expect(rig.hub.cloudError == nil)
    }

    /// The crash of 2026-10-12 00:53: a second post while the first one waited
    /// for iCloud removed more events than were left.
    @Test func overlappingPostsSendEachEventOnceAndNeverCrash() async {
        let rig = HubRig()
        let gate = AsyncGate()
        rig.cloud.postGate = gate
        let first = Task { await rig.hub.post([MacEvent(kind: .agentDone, title: "a", body: "b", at: rig.clock.now())]) }
        await gate.waitUntilEntered()
        await rig.hub.post([MacEvent(kind: .agentWaiting, title: "c", body: "d", at: rig.clock.now())])
        await rig.hub.post([])
        gate.open()
        await first.value
        #expect(rig.cloud.events.map(\.kind) == [.agentDone, .agentWaiting])
        #expect(rig.hub.pendingEvents.isEmpty)
    }

    @Test func aFailingPublishDoesNotStopTheInbox() async throws {
        let rig = HubRig().paired()
        rig.cloud.failPublish = true
        #expect(await !rig.hub.publishIfDue(state(rig), endpoints: nil, force: true))
        let cmd = try rig.phone.sign(.stopSession, mac: rig.macID, at: rig.clock.now())
        rig.cloud.inbox = CloudInbox(commands: [("c1", cmd)])
        await rig.hub.pollCloud(macName: "MacBook")
        #expect(rig.target.calls == ["stop"])
    }

    @Test func eventsWaitForTheNetwork() async {
        let rig = HubRig()
        rig.cloud.failEvents = true
        await rig.hub.post([MacEvent(kind: .hot, title: "t", body: "b", at: rig.clock.now())])
        #expect(rig.hub.pendingEvents.count == 1)
        rig.cloud.failEvents = false
        rig.clock.advance(31)
        await rig.hub.post([])
        #expect(rig.cloud.events.map(\.kind) == [.hot])
        #expect(rig.hub.pendingEvents.isEmpty)
    }

    /// A Claude request that ended leaves no event in iCloud: queued, it
    /// is never sent; being sent, it is deleted once saved.
    @Test func anEndedRequestLeavesNoEventBehind() async {
        let rig = HubRig()
        let queued = MacEvent(kind: .agentRequest, title: "t", body: "b", at: rig.clock.now())
        rig.hub.enqueue([queued])
        rig.hub.withdrawEvent(queued.id)
        await rig.hub.post([])
        #expect(rig.cloud.events.isEmpty)

        let gate = AsyncGate()
        rig.cloud.postGate = gate
        let sending = MacEvent(kind: .agentRequest, title: "t", body: "b", at: rig.clock.now())
        let post = Task { await rig.hub.post([sending]) }
        await gate.waitUntilEntered()
        rig.hub.withdrawEvent(sending.id)
        #expect(!rig.cloud.removedEvents.contains(sending.id), "not before its save")
        gate.open()
        await post.value
        #expect(rig.cloud.events.map(\.id) == [sending.id])
        #expect(rig.cloud.removedEvents.contains(sending.id))
        #expect(rig.hub.pendingEvents.isEmpty)
    }

    @Test func anEndedRequestWhoseSaveFailedIsNotSentAgain() async {
        let rig = HubRig()
        let gate = AsyncGate()
        rig.cloud.postGate = gate
        rig.cloud.failEvents = true
        let failing = MacEvent(kind: .agentRequest, title: "t", body: "b", at: rig.clock.now())
        let post = Task { await rig.hub.post([failing]) }
        await gate.waitUntilEntered()
        rig.hub.withdrawEvent(failing.id)
        gate.open()
        await post.value
        #expect(rig.hub.pendingEvents.isEmpty)
        #expect(rig.cloud.removedEvents == [failing.id], "deleted, in case the save went through")
    }

    @Test func inboxCommandsRunAndAnswersGoBackToCloud() async throws {
        let rig = HubRig().paired()
        let cmd = try rig.phone.sign(.stopSession, mac: rig.macID, at: rig.clock.now())
        rig.cloud.inbox = CloudInbox(commands: [("c1", cmd)])
        await rig.hub.pollCloud(macName: "MacBook")
        #expect(rig.target.calls == ["stop"])
        #expect(rig.cloud.results.map(\.status) == [.executed])
        #expect(rig.cloud.discarded == ["c1"])
    }

    /// The phone's first answer was lost (direct link dropped): it asks again
    /// through iCloud with the same invite, and is answered again.
    @Test func theSamePhoneAskingAgainIsAcceptedAgain() async throws {
        let rig = HubRig()
        let invite = try rig.hub.makeInvite(macName: "MacBook", endpoints: nil)
        let request = rig.phone.pairingRequest(for: invite, at: rig.clock.now())
        #expect(rig.hub.handlePairing(request, macName: "MacBook").accepted)
        #expect(rig.hub.handlePairing(request, macName: "MacBook", via: .cloud).accepted)
        #expect(rig.store.stored.count == 1)
        let other = TestPhone().pairingRequest(for: invite, at: rig.clock.now())
        #expect(!rig.hub.handlePairing(other, macName: "MacBook").accepted, "the invite is spent for anyone else")
    }

    @Test func pairingAnswerCarriesTheMainEndpoints() async throws {
        let rig = HubRig()
        rig.hub.mainEndpoints = { Endpoints(port: 52525, local: ["192.168.1.20"], tailscale: nil) }
        let invite = try rig.hub.makeInvite(macName: "MacBook", endpoints: Endpoints(port: 60001, local: ["192.168.1.20"], tailscale: nil))
        let response = rig.hub.handlePairing(rig.phone.pairingRequest(for: invite, at: rig.clock.now()), macName: "MacBook")
        #expect(response.endpoints?.port == 52525)
    }

    @Test func pairingThroughCloud() async throws {
        let rig = HubRig()
        var notified: RemoteHub.Channel?
        rig.hub.onPaired = { _, channel in notified = channel }
        let invite = try rig.hub.makeInvite(macName: "MacBook", endpoints: nil)
        rig.cloud.inbox = CloudInbox(pairings: [("p1", rig.phone.pairingRequest(for: invite, at: rig.clock.now()))])
        await rig.hub.pollCloud(macName: "MacBook")
        #expect(rig.cloud.pairings.map(\.accepted) == [true])
        #expect(rig.store.stored.count == 1)
        #expect(notified == .cloud, "the window and the direct server must hear about an iCloud pairing too")
    }
}

@Suite struct LinkPieces {
    @Test func framerSplitsAndJoins() throws {
        let a = try Framer.frame(ClientMessage.getState)
        let device = UUID()
        let b = try Framer.frame(ClientMessage.hello(protocolVersion: 1, deviceID: device))
        var f = Framer()
        var all = a + b
        let first = try f.push(all.prefix(3))
        #expect(first.isEmpty)
        all = all.dropFirst(3)
        let rest = try f.push(Data(all))
        #expect(rest.count == 2)
        #expect(try LinkCoding.decoder().decode(ClientMessage.self, from: rest[1]) == .hello(protocolVersion: 1, deviceID: device))
    }

    @Test func framerRejectsHugeFrames() {
        var f = Framer()
        #expect(throws: Framer.FrameError.self) { _ = try f.push(Data([0x7f, 0xff, 0xff, 0xff])) }
    }

    @Test func endpointsKeepLANHotspotAndTailscale() {
        let e = EndpointPicker.endpoints(from: [
            .init(name: "lo0", ipv4: "127.0.0.1"),
            .init(name: "en0", ipv4: "172.20.10.3"),
            .init(name: "en7", ipv4: "192.168.1.20"),
            .init(name: "utun4", ipv4: "100.101.102.103"),
            .init(name: "bridge100", ipv4: "192.168.64.1"),
            .init(name: "en0", ipv4: "8.8.8.8"),
        ], port: 52525)
        #expect(e.local == ["172.20.10.3", "192.168.1.20"])
        #expect(e.tailscale == "100.101.102.103")
        #expect(EndpointPicker.isHotspot("172.20.10.3"))
        #expect(!EndpointPicker.isHotspot("172.20.11.3"))
    }

    @Test func containerIDs() {
        #expect(CommandKind.isWellFormedContainerID("0123456789ab"))
        #expect(!CommandKind.isWellFormedContainerID("0123456789AB"))
        #expect(!CommandKind.isWellFormedContainerID("abc"))
        #expect(!CommandKind.isWellFormedContainerID("0123456789ab; rm"))
    }
}
