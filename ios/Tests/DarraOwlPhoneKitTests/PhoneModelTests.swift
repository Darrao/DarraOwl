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
    var id: PhoneIdentity
    var mac: PairedMac?
    init() {
        id = Self.newIdentity()
    }
    static func newIdentity() -> PhoneIdentity {
        PhoneIdentity(deviceID: UUID(), deviceName: "iPhone de test",
                      agreementKey: .init(), signingKey: .init(), biometric: SoftwareBiometricSigner())
    }
    func identity() throws -> PhoneIdentity { id }
    func pairedMac() -> PairedMac? { mac }
    func save(_ mac: PairedMac) throws { self.mac = mac }
    /// Like the Keychain store: the keys go too, the next ones are new.
    func forgetMac() throws {
        mac = nil
        id = Self.newIdentity()
    }
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
    /// Answers inside send(), as the demonstration does.
    var answerAtOnce = false
    var stateRequests = 0
    /// What a shell command's result carries.
    var shellOutput = ShellOutput(status: 0, text: "hello\n", truncated: false, seconds: 0.3)

    func connect(to mac: PairedMac, identity: PhoneIdentity) {
        connects += 1
        path = connectTo
        onPathChange?(path)
    }
    func disconnect() { path = nil; onPathChange?(nil) }
    func send(_ command: SignedCommand) throws {
        sent.append(command)
        guard let reply, let env = try? LinkCoding.decoder().decode(CommandEnvelope.self, from: command.payload) else { return }
        let result = CommandResult(commandID: env.id, status: reply, message: nil, at: Date(), output: env.kind.isShell ? shellOutput : nil)
        if answerAtOnce { onResult?(result) } else { Task { @MainActor in self.onResult?(result) } }
    }
    func requestState() { stateRequests += 1 }
}

@MainActor
final class FakeCloudLink: CloudLink {
    var problem: String?
    var state: (MacState, Endpoints?)?
    var sent: [SignedCommand] = []
    var answer: CommandResult.Status? = .executed
    var answerAfterPolls = 1
    var polls = 0
    var onPoll: (() -> Void)?
    /// Carried by an executed result, as a shell command's would.
    var output: ShellOutput?
    var pairingResponse: PairingResponse?
    var pairingRequests: [PairingRequest] = []

    /// While set, accountProblem() waits for openAccount(): what runs
    /// meanwhile overlaps a start().
    var holdAccount = false
    private(set) var heldAccountChecks: [CheckedContinuation<Void, Never>] = []
    func accountProblem() async -> String? {
        if holdAccount { await withCheckedContinuation { heldAccountChecks.append($0) } }
        return problem
    }
    func openAccount() {
        holdAccount = false
        heldAccountChecks.forEach { $0.resume() }
        heldAccountChecks = []
    }
    func fetchState(macID: UUID) async throws -> (state: MacState, endpoints: Endpoints?)? { state }
    var onSend: (() -> Void)?
    func send(_ command: SignedCommand, macID: UUID) async throws {
        sent.append(command)
        onSend?()
    }
    func result(for commandID: UUID) async throws -> CommandResult? {
        onPoll?()
        polls += 1
        guard let answer, polls >= answerAfterPolls else { return nil }
        return CommandResult(commandID: commandID, status: answer, message: answer == .executed ? nil : "Refusé", at: Date(),
                             output: answer == .executed ? output : nil)
    }
    func sendPairing(_ request: PairingRequest) async throws -> String {
        pairingRequests.append(request)
        return "req-1"
    }
    func pairingResponse(requestID: String) async throws -> PairingResponse? { pairingResponse }
    /// Every try, failed or not.
    var subscribed = 0
    var subscribeFails = false
    func subscribeToEvents() async throws {
        subscribed += 1
        if subscribeFails { throw URLError(.notConnectedToInternet) }
    }
    var unsubscribed = 0
    func unsubscribeFromEvents() async throws { unsubscribed += 1 }
}

@MainActor
final class FakePairingDirect: PairingDirect {
    var response: PairingResponse?
    var calls = 0
    var lastRequest: PairingRequest?
    func pair(_ request: PairingRequest, invite: PairingInvite) async throws -> PairingResponse {
        calls += 1
        lastRequest = request
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
        #expect(rig.model.outcome == .done("Prolonger d'1 h : fait."))
    }

    @Test func cloudWhenNoDirectPath() async throws {
        let rig = await PhoneRig().paired()
        rig.cloud.answerAfterPolls = 3
        await rig.model.send(.stopSession)
        #expect(rig.cloud.sent.count == 1)
        #expect(rig.cloud.polls == 3)
        #expect(rig.model.outcome == .done("Arrêter la session : fait."))
    }

    /// Through iCloud the Mac can take some 10 s: the screen says which way
    /// the command went while it waits.
    @Test func theWaitThroughICloudIsShown() async throws {
        let rig = await PhoneRig().paired()
        var shown: PhoneModel.Outcome?
        rig.cloud.onPoll = { shown = rig.model.outcome }
        await rig.model.send(.stopSession)
        #expect(shown == .sending("Arrêter la session · par iCloud"))
        #expect(rig.model.outcome == .done("Arrêter la session : fait."))
    }

    /// The Mac unpaired this phone while the command was written to iCloud:
    /// nothing is left spinning for a Mac that is gone.
    @Test func noSpinnerIsLeftWhenTheMacGoesDuringASend() async throws {
        let rig = PhoneRig()
        var mac = rig.pairedMac
        mac.macPairedAt = rig.clock.now.addingTimeInterval(-60)
        rig.store.mac = mac
        await rig.model.start()
        var dropped = rig.state()
        dropped.pairedDevices = []
        rig.cloud.onSend = { rig.direct.onState?(dropped) }
        await rig.model.send(.stopSession)
        #expect(rig.model.mac == nil)
        #expect(rig.model.outcome == nil)
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

    /// The Mac passed the answer on, nothing more: Claude ignores an accept
    /// for an MCP tool that wants its own dialog, and asks in the terminal.
    @Test func anAnswerToClaudeIsSentNotDone() async throws {
        let rig = await PhoneRig().paired()
        await rig.model.send(.answerAgentRequest(id: UUID(), allow: true))
        #expect(rig.model.outcome == .done("Accord envoyé à Claude."))
        await rig.model.send(.answerAgentRequest(id: UUID(), allow: false))
        #expect(rig.model.outcome == .done("Refus envoyé à Claude."))
    }
}

/// A shell command typed on the phone: sent like any sensitive command,
/// but its wait runs apart, as long as the Mac's time limit, and what the
/// command printed ends up on screen.
@MainActor
@Suite struct PhoneShellTests {
    /// Turns of the loop until the command is no longer running.
    private func settle(_ rig: PhoneRig) async {
        for _ in 0..<400 where rig.model.shell?.phase == .running { await Task.yield() }
    }

    @Test func aCommandRunsOverTheDirectLinkAndShowsWhatItPrinted() async throws {
        let rig = PhoneRig()
        rig.direct.connectTo = .local
        _ = await rig.paired()
        let agent = MacState.Agent(tool: "claude", project: "api", since: rig.clock.now, waitingForApproval: false, pid: 4242)
        await rig.model.runShell("echo hello", agent: agent)
        #expect(rig.model.shell?.phase == .running)
        #expect(!rig.model.isBusy, "the other buttons are not held while it runs")
        await settle(rig)
        #expect(rig.model.shell?.text == "echo hello")
        #expect(rig.model.shell?.agent == agent)
        #expect(rig.model.shell?.phase == .done(rig.direct.shellOutput))
        let signed = try #require(rig.direct.sent.first)
        #expect(signed.biometricSignature != nil, "Face ID")
        let env = try LinkCoding.decoder().decode(CommandEnvelope.self, from: signed.payload)
        #expect(env.kind == .runCommand(text: "echo hello", inAgent: 4242))
        #expect(rig.cloud.sent.isEmpty)
        #expect(rig.direct.stateRequests == 1, "the command may have changed what the Mac shows")
    }

    /// The direct link dropped while the command ran (the app suspended):
    /// a few seconds on, the command also went through iCloud, and its
    /// answer comes from there instead of after the whole wait.
    @Test func aDroppedDirectLinkGetsItsAnswerThroughICloud() async throws {
        let rig = PhoneRig()
        rig.direct.connectTo = .local
        rig.direct.reply = nil
        _ = await rig.paired()
        rig.cloud.output = ShellOutput(status: 0, text: "done\n", truncated: false, seconds: 40)
        await rig.model.runShell("npm run build")
        await settle(rig)
        #expect(rig.model.shell?.phase == .done(rig.cloud.output!))
        #expect(rig.direct.sent.count == 1)
        #expect(rig.cloud.sent.count == 1)
        let backup = try #require(rig.cloud.sent.first)
        #expect(backup.payload == rig.direct.sent.first?.payload, "the same command: the Mac runs it once")
    }

    /// No answer either way: the command went through iCloud once, and the
    /// wait still ends.
    @Test func noAnswerOnEitherPathSendsThroughICloudOnce() async throws {
        let rig = PhoneRig()
        rig.direct.connectTo = .local
        rig.direct.reply = nil
        _ = await rig.paired()
        rig.cloud.answer = nil
        await rig.model.runShell("sleep 1000")
        await settle(rig)
        #expect(rig.model.shell?.phase == .failed("Pas de réponse du Mac."))
        #expect(rig.cloud.sent.count == 1)
    }

    /// Through iCloud the wait outlasts a plain command's minute: as long as
    /// the Mac may run the command.
    @Test func aCommandWithoutADirectLinkGoesThroughICloudAndIsPolledLonger() async throws {
        let rig = await PhoneRig().paired()
        rig.cloud.answerAfterPolls = 40
        rig.cloud.output = ShellOutput(status: 1, text: "FAIL\n", truncated: false, seconds: 95)
        await rig.model.runShell("npm test")
        await settle(rig)
        #expect(rig.cloud.sent.count == 1)
        #expect(rig.cloud.polls == 40)
        #expect(rig.model.shell?.phase == .done(rig.cloud.output!))
        #expect(rig.model.shell?.agent == nil)
    }

    @Test func theMacsRefusalIsShownOnTheCommand() async throws {
        let rig = await PhoneRig().paired()
        rig.cloud.answer = .failed
        await rig.model.runShell("ls")
        await settle(rig)
        #expect(rig.model.shell?.phase == .failed("Refusé"))
        #expect(rig.model.outcome == nil, "on the command itself, not in the status line")
    }

    @Test func noAnswerEndsTheWaitOnceTheMacWouldHaveStoppedTheCommand() async throws {
        let rig = await PhoneRig().paired()
        rig.cloud.answer = nil
        await rig.model.runShell("sleep 1000")
        await settle(rig)
        #expect(rig.model.shell?.phase == .failed("Pas de réponse du Mac."))
        #expect(Double(rig.cloud.polls) * PhoneModel.shellPollInterval >= Policy.remoteCommandTimeout)
    }

    @Test func aSecondCommandWaitsForTheFirst() async throws {
        let rig = await PhoneRig().paired()
        rig.cloud.answer = nil
        await rig.model.runShell("sleep 1000")
        await rig.model.runShell("ls")
        #expect(rig.model.shell?.text == "sleep 1000")
        await settle(rig)
        #expect(rig.cloud.sent.count == 1)
    }

    @Test func unpairingDropsTheCommandOnItsWay() async throws {
        let rig = await PhoneRig().paired()
        rig.cloud.answer = nil
        await rig.model.runShell("ls")
        await rig.model.unpair()
        await settle(rig)
        #expect(rig.model.shell == nil)
    }

    @Test func clearingTakesTheCommandOffTheScreen() async throws {
        let rig = PhoneRig()
        rig.direct.connectTo = .local
        _ = await rig.paired()
        await rig.model.runShell("ls")
        await settle(rig)
        rig.model.clearShell()
        #expect(rig.model.shell == nil)
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

    /// Launched in the background by a push, then opened: the push read
    /// iCloud first, and the events are still subscribed to, once (a phone
    /// paired before Claude's requests gets their subscription).
    @Test func aPushBeforeTheStartStillSubscribes() async {
        let rig = PhoneRig()
        rig.store.mac = rig.pairedMac
        await rig.model.refreshFromCloud()
        await rig.model.start()
        #expect(rig.cloud.subscribed == 1)
        rig.clock.advance(PhoneModel.accountCheckInterval)
        await rig.model.tick()
        #expect(rig.cloud.subscribed == 1, "once per launch")
    }

    /// The app starts the model and its ticks together: a tick that reads
    /// iCloud while start() waits for the account skips nothing.
    @Test func aTickDuringTheStartStillSubscribes() async {
        let rig = PhoneRig()
        rig.store.mac = rig.pairedMac
        rig.cloud.holdAccount = true
        let starting = Task { await rig.model.start() }
        while rig.cloud.heldAccountChecks.isEmpty { await Task.yield() }
        await rig.model.tick()
        rig.cloud.openAccount()
        await starting.value
        rig.clock.advance(PhoneModel.accountCheckInterval)
        await rig.model.tick()
        #expect(rig.cloud.subscribed == 1)
    }

    /// Not saved: tried again at the next account check, then not again.
    @Test func aFailedSubscriptionIsTriedAgain() async {
        let rig = PhoneRig()
        rig.store.mac = rig.pairedMac
        rig.cloud.subscribeFails = true
        await rig.model.start()
        #expect(rig.cloud.subscribed == 1)
        rig.cloud.subscribeFails = false
        await rig.model.tick()
        #expect(rig.cloud.subscribed == 1, "not before the next check")
        rig.clock.advance(PhoneModel.accountCheckInterval)
        await rig.model.tick()
        #expect(rig.cloud.subscribed == 2)
        rig.clock.advance(PhoneModel.accountCheckInterval)
        await rig.model.tick()
        #expect(rig.cloud.subscribed == 2, "saved this time")
    }

    func sentKinds(_ rig: PhoneRig) throws -> [CommandKind] {
        try rig.cloud.sent.map { try LinkCoding.decoder().decode(CommandEnvelope.self, from: $0.payload).kind }
    }

    /// Launched for the button, nothing known yet: "Session bientôt finie"
    /// is extended, never answered with a session that already runs.
    @Test func notificationButtonsOnAColdLaunch() async throws {
        let rig = PhoneRig()
        rig.store.mac = rig.pairedMac
        await rig.model.handleNotificationAction(MacEvent.extendAction, eventMacID: rig.macID, eventKind: .endingSoon)
        await rig.model.handleNotificationAction(MacEvent.stopAction, eventMacID: rig.macID, eventKind: .endingSoon)
        #expect(try sentKinds(rig) == [.extendSession(minutes: 60), .stopSession])
    }

    /// "Session terminée": "+1 h" gives a new hour, "Arrêter" has nothing to stop.
    @Test func notificationButtonsAfterTheEnd() async throws {
        let rig = PhoneRig()
        rig.store.mac = rig.pairedMac
        await rig.model.handleNotificationAction(MacEvent.extendAction, eventMacID: rig.macID, eventKind: .ended)
        await rig.model.handleNotificationAction(MacEvent.stopAction, eventMacID: rig.macID, eventKind: .ended)
        #expect(try sentKinds(rig) == [.startSession(minutes: 60)])
    }

    /// A fresh state without a session: "+1 h" starts one.
    @Test func notificationButtonWithAFreshStateWithoutSession() async throws {
        let rig = PhoneRig()
        rig.cloud.state = (rig.state(), nil)
        _ = await rig.paired()
        await rig.model.handleNotificationAction(MacEvent.extendAction, eventMacID: rig.macID, eventKind: .agentDone)
        #expect(try sentKinds(rig) == [.startSession(minutes: 60)])
    }

    /// A Claude request's notification touches no session, whatever button
    /// an older setup gave it; "Refuser" answers the request.
    @Test func aClaudeRequestsNotificationOnlyAnswersIt() async throws {
        let rig = PhoneRig()
        rig.store.mac = rig.pairedMac
        let request = UUID()
        #expect(await rig.model.handleNotificationAction(MacEvent.extendAction, eventMacID: rig.macID, eventKind: .agentRequest, requestID: request) == nil)
        #expect(await rig.model.handleNotificationAction(MacEvent.stopAction, eventMacID: rig.macID, eventKind: .agentRequest, requestID: request) == nil)
        await rig.model.handleNotificationAction(MacEvent.denyAction, eventMacID: rig.macID, eventKind: .agentRequest, requestID: request)
        #expect(try sentKinds(rig) == [.answerAgentRequest(id: request, allow: false)])
    }

    @Test func anotherMacsNotificationDoesNothing() async throws {
        let rig = await PhoneRig().paired()
        await rig.model.handleNotificationAction(MacEvent.stopAction, eventMacID: UUID(), eventKind: .endingSoon)
        #expect(rig.cloud.sent.isEmpty)
    }

    /// A push woke the app in the background: the state is read even though
    /// the model was never started.
    @Test func aPushOnAColdLaunchReadsTheState() async {
        let rig = PhoneRig()
        rig.store.mac = rig.pairedMac
        rig.cloud.state = (rig.state(), nil)
        var mirrored: MacState?
        rig.model.onStateChange = { mirrored = $0 }
        await rig.model.refreshFromCloud()
        #expect(mirrored?.macName == "MacBook")
    }

    /// The demonstration answers inside send(): the answer must not be lost
    /// (every button spun for 70 s, then showed an error).
    @Test func anAnswerThatComesAtOnceIsNotMissed() async throws {
        let fresh = PhoneRig()
        fresh.direct.connectTo = .local
        fresh.direct.answerAtOnce = true
        let rig = await fresh.paired()
        await rig.model.send(.extendSession(minutes: 30))
        #expect(rig.model.outcome == .done("Prolonger de 30 min : fait."))
        #expect(rig.cloud.sent.isEmpty, "no iCloud fallback")
    }

    /// Unpair, pair again in the same run: the new keys are the ones sent,
    /// so the phone still works after the next launch.
    @Test func pairingAgainAfterUnpairingUsesTheNewKeys() async throws {
        let rig = await PhoneRig().paired()
        let before = try rig.store.identity().deviceID
        await rig.model.unpair()
        #expect(rig.cloud.unsubscribed == 0 || rig.cloud.unsubscribed == 1)
        rig.pairing.response = PairingResponse(accepted: true, macID: rig.macID, macName: "MacBook", message: nil)
        await rig.model.pair(url: try rig.invite().url())
        let sentID = rig.pairing.lastRequest?.deviceID
        #expect(sentID == (try rig.store.identity().deviceID))
        #expect(sentID != before)
    }

    @Test func aMacGoingToSleepShowsAsleepEvenWithTheLinkOpen() async throws {
        let fresh = PhoneRig()
        fresh.direct.connectTo = .local
        let rig = await fresh.paired()
        rig.direct.onState?(rig.state(power: .goingToSleep))
        #expect(rig.model.presence == .asleep(since: rig.clock.now))
    }

    @Test func aSilentDirectLinkIsDroppedAndICloudTakesOver() async throws {
        let fresh = PhoneRig()
        fresh.direct.connectTo = .local
        let rig = await fresh.paired()
        #expect(rig.model.directPath == .local)
        rig.direct.connectTo = nil
        rig.clock.advance(PhoneModel.directSilence + 1)
        rig.cloud.state = (rig.state(), nil)
        await rig.model.tick()
        #expect(rig.model.directPath == nil)
        #expect(rig.model.presence == .online(.icloud))
    }

    @Test func anOlderICloudStateDoesNotReplaceANewerOne() async throws {
        let fresh = PhoneRig()
        fresh.direct.connectTo = .local
        let rig = await fresh.paired()
        rig.direct.onState?(rig.state(at: rig.clock.now))
        rig.cloud.state = (rig.state(power: .asleep, at: rig.clock.now.addingTimeInterval(-300)), nil)
        await rig.model.refreshFromCloud()
        #expect(rig.model.state?.power == .awake)
    }

    @Test(arguments: [
        Endpoints(port: 60000, local: ["8.8.8.8"], tailscale: nil),
        Endpoints(port: 60000, local: ["evil.example.com"], tailscale: nil),
        Endpoints(port: 60000, local: ["192.168.1.20"], tailscale: "1.2.3.4"),
        Endpoints(port: 0, local: ["192.168.1.20"], tailscale: nil),
    ])
    func linksPointingOutsideAreRefused(endpoints: Endpoints) async throws {
        let rig = PhoneRig()
        rig.pairing.response = PairingResponse(accepted: true, macID: rig.macID, macName: "MacBook", message: nil)
        await rig.model.pair(url: try rig.invite(endpoints: endpoints).url())
        #expect(rig.model.mac == nil)
        #expect(rig.pairing.calls == 0)
        #expect(rig.model.pairingError != nil)
    }

    @Test func aLinkValidForYearsIsRefused() async throws {
        let rig = PhoneRig()
        var invite = rig.invite()
        invite.expiresAt = rig.clock.now.addingTimeInterval(86_400 * 365)
        await rig.model.pair(url: try invite.url())
        #expect(rig.model.pairingError == "Ce code n'a pas une durée de validité normale.")
    }

    @Test func thePairingPortIsNotKeptAsTheMainOne() async throws {
        let rig = PhoneRig()
        rig.pairing.response = PairingResponse(accepted: true, macID: rig.macID, macName: "MacBook", message: nil)
        await rig.model.pair(url: try rig.invite().url())
        #expect(rig.model.mac?.endpoints?.port == LinkProtocol.defaultPort)
        let withAnswer = PhoneRig()
        withAnswer.pairing.response = PairingResponse(accepted: true, macID: withAnswer.macID, macName: "MacBook", message: nil,
                                                      endpoints: Endpoints(port: 52600, local: ["192.168.1.20"], tailscale: nil))
        await withAnswer.model.pair(url: try withAnswer.invite().url())
        #expect(withAnswer.model.mac?.endpoints?.port == 52600)
    }

    @Test func aSuccessMessageGoesAfterAFewSeconds() async throws {
        let rig = await PhoneRig().paired()
        await rig.model.send(.stopSession)
        #expect(rig.model.outcome != nil)
        rig.clock.advance(PhoneModel.successShown + 1)
        await rig.model.tick()
        #expect(rig.model.outcome == nil)
    }

    @Test func fireSendsBothWays() async throws {
        let fresh = PhoneRig()
        fresh.direct.connectTo = .local
        let rig = await fresh.paired()
        #expect(await rig.model.fire(.extendSession(minutes: 60)))
        #expect(rig.direct.sent.count == 1)
        #expect(rig.cloud.sent.count == 1)
    }

    @Test func refusalIsShown() async throws {
        let rig = PhoneRig()
        rig.pairing.response = PairingResponse(accepted: false, macID: rig.macID, macName: "MacBook", message: "Code invalide.")
        await rig.model.pair(url: try rig.invite().url())
        #expect(rig.model.mac == nil)
        #expect(rig.model.pairingError == "Code invalide.")
    }

    @Test func noAnswerWithoutICloudOnThePhoneSaysSo() async throws {
        let rig = PhoneRig()
        rig.cloud.problem = "Aucun compte iCloud sur cet iPhone."
        await rig.model.start()
        await rig.model.pair(url: try rig.invite().url())
        #expect(rig.model.mac == nil)
        #expect(rig.model.pairingError?.contains("iCloud n'est pas disponible sur cet iPhone") == true)

        let withCloud = PhoneRig()
        await withCloud.model.start()
        await withCloud.model.pair(url: try withCloud.invite().url())
        #expect(withCloud.model.pairingError?.contains("même réseau") == true)
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
        await rig.model.unpair()
        #expect(rig.store.mac == nil && rig.model.mac == nil)
    }

    /// Unpairing here tells the Mac, which forgets this phone's keys.
    @Test func unpairingTellsTheMac() async throws {
        let rig = await PhoneRig().paired()
        await rig.model.unpair()
        let kinds = try rig.cloud.sent.map { try LinkCoding.decoder().decode(CommandEnvelope.self, from: $0.payload).kind }
        #expect(kinds == [.forgetThisDevice])
        #expect(rig.cloud.unsubscribed == 1)
    }

    /// The notifications' subscription is shared by the account's phones:
    /// another phone still paired keeps it.
    @Test func anotherPairedPhoneKeepsTheNotifications() async throws {
        let rig = PhoneRig()
        rig.direct.connectTo = .local
        _ = await rig.paired()
        let me = try rig.store.identity().deviceID
        var state = rig.state()
        state.pairedDevices = [me, UUID()]
        rig.direct.onState?(state)
        await rig.model.unpair()
        #expect(rig.cloud.unsubscribed == 0)
    }

    /// Unpaired on the Mac: its next state does not list this phone, which
    /// then forgets that Mac and says why.
    @Test func unpairedOnTheMacTheStateSaysSo() async throws {
        let rig = PhoneRig()
        rig.direct.connectTo = .local
        var mac = rig.pairedMac
        mac.macPairedAt = rig.clock.now.addingTimeInterval(-60)
        rig.store.mac = mac
        await rig.model.start()
        let me = try rig.store.identity().deviceID
        var listed = rig.state()
        listed.pairedDevices = [me]
        rig.direct.onState?(listed)
        #expect(rig.model.mac != nil)

        var dropped = rig.state(at: rig.clock.now.addingTimeInterval(1))
        dropped.pairedDevices = []
        rig.direct.onState?(dropped)
        #expect(rig.model.mac == nil)
        #expect(rig.store.mac == nil)
        #expect(rig.model.unpairNotice?.contains("a désappairé cet iPhone") == true)
    }

    /// Woken in the background with nothing loaded: unpaired on the Mac
    /// while another phone stays paired, it keeps that phone's notifications.
    @Test func anUnpairedPhoneLeavesTheOtherPhonesNotifications() async throws {
        let rig = PhoneRig()
        var mac = rig.pairedMac
        mac.macPairedAt = rig.clock.now.addingTimeInterval(-60)
        rig.store.mac = mac
        var state = rig.state()
        state.pairedDevices = [UUID()]
        rig.cloud.state = (state, nil)
        await rig.model.refreshFromCloud()
        #expect(rig.model.mac == nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.cloud.unsubscribed == 0)
    }

    /// A state published before this pairing (an old iCloud copy) proves nothing.
    @Test func aStateFromBeforeThePairingNeverUnpairs() async throws {
        let rig = PhoneRig()
        var mac = rig.pairedMac
        mac.macPairedAt = rig.clock.now
        rig.store.mac = mac
        var old = rig.state(at: rig.clock.now.addingTimeInterval(-30))
        old.pairedDevices = []
        rig.cloud.state = (old, nil)
        await rig.model.start()
        #expect(rig.model.mac != nil)
    }

    /// Unpaired while a command waited for the Mac: it is not sent through
    /// iCloud to the Mac just left.
    @Test func aCommandOnItsWayStopsWhenUnpaired() async throws {
        let fresh = PhoneRig()
        fresh.direct.connectTo = .local
        fresh.direct.reply = nil
        let rig = await fresh.paired()
        let sending = Task { await rig.model.send(.stopSession) }
        await Task.yield()
        await rig.model.unpair()
        await sending.value
        let kinds = try rig.cloud.sent.map { try LinkCoding.decoder().decode(CommandEnvelope.self, from: $0.payload).kind }
        #expect(!kinds.contains(.stopSession))
        #expect(!rig.model.isBusy)
    }

    /// The Mac's clock went back: its live states still show.
    @Test func directStatesShowEvenWhenTheMacsClockWentBack() async throws {
        let fresh = PhoneRig()
        fresh.direct.connectTo = .local
        let rig = await fresh.paired()
        rig.direct.onState?(rig.state(at: rig.clock.now.addingTimeInterval(3600)))
        rig.direct.onState?(rig.state(power: .goingToSleep, at: rig.clock.now))
        #expect(rig.model.state?.power == .goingToSleep)
    }

    @Test func aBrokenLinkIsCheckedBeforeAskingToConfirmIt() throws {
        let rig = PhoneRig()
        #expect(rig.model.linkProblem(try rig.invite().url()) == nil)
        #expect(rig.model.linkProblem(URL(string: "darraowl://pair?d=garbage")!) == "Ce code n'est pas un code DarraOwl.")
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

/// The terminal's history and its ready-made commands.
@Suite struct ShellHelpTests {
    @Test func aCommandRunAgainMovesToTheTop() {
        var history = CommandHistory()
        history.record("ls")
        history.record("  git status  ")
        history.record("ls")
        history.record("   ")
        #expect(history.commands == ["ls", "git status"])
        for i in 0..<40 { history.record("echo \(i)") }
        #expect(history.commands.count == CommandHistory.limit)
        #expect(history.commands.first == "echo 39")
        #expect(CommandHistory(data: history.data) == history)
        #expect(CommandHistory(data: Data("nope".utf8)).commands.isEmpty)
        history.clear()
        #expect(history.commands.isEmpty)
    }

    /// Every ready-made command can be sent as it is, and none appears twice.
    @Test func everyReadyMadeCommandIsSendable() {
        let items = ShellHelp.sections.flatMap(\.items)
        #expect(!items.isEmpty)
        #expect(Set(items.map(\.command)).count == items.count)
        for item in items { #expect(CommandKind.isWellFormedCommand(item.command), "\(item.command)") }
        #expect(items.contains { $0.command.hasPrefix("darraowl claude") }, "starting Claude from the phone")
    }
}
