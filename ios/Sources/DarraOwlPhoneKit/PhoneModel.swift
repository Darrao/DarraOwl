import DarraOwlShared
import Foundation
import Observation

/// What the phone can say about the Mac.
public enum MacPresence: Equatable, Sendable {
    /// Direct link up, or a fresh state from iCloud.
    case online(ConnectionPath)
    case asleep(since: Date)
    /// No news for more than 150 s.
    case lastSeen(Date)
    case unknown

    public static let staleAfter: TimeInterval = 150

    public static func from(state: MacState?, directPath: ConnectionPath?, now: Date) -> MacPresence {
        // The Mac said it goes to sleep: that wins over a link that still
        // looks open.
        if let state, state.power != .awake { return .asleep(since: state.updatedAt) }
        if let directPath { return .online(directPath) }
        guard let state else { return .unknown }
        if now.timeIntervalSince(state.updatedAt) <= staleAfter { return .online(.icloud) }
        return .lastSeen(state.updatedAt)
    }
}

/// The phone app's state and actions. Every dependency is injected.
@MainActor
@Observable
public final class PhoneModel {
    public struct Dependencies {
        public var store: any PhoneStore
        public var direct: any DirectLink
        public var cloud: any CloudLink
        public var pairing: any PairingDirect
        public var now: () -> Date
        public var sleeper: any Sleeper

        public init(store: any PhoneStore, direct: any DirectLink, cloud: any CloudLink, pairing: any PairingDirect,
                    now: @escaping () -> Date = { Date() }, sleeper: any Sleeper = TaskSleeper()) {
            self.store = store
            self.direct = direct
            self.cloud = cloud
            self.pairing = pairing
            self.now = now
            self.sleeper = sleeper
        }
    }

    public enum Outcome: Equatable, Sendable {
        case sending(String)
        case done(String)
        case failed(String)
    }

    public static let directResultTimeout: Double = 10
    public static let cloudPollInterval: Double = 2
    /// A shell command's result is looked for in iCloud this often: its
    /// wait can last minutes.
    public static let shellPollInterval: Double = 3
    /// A shell command not answered over the direct link by then also goes
    /// through iCloud: the link may drop while it runs.
    public static let shellBackupDelay: Double = 8
    public static let reconnectInterval: TimeInterval = 15
    public static let cloudFetchInterval: TimeInterval = 10
    /// The Mac sends its state at least every 30 s on the direct link: a
    /// link silent for longer is dead, even without a TCP error.
    public static let directSilence: TimeInterval = 75
    public static let accountCheckInterval: TimeInterval = 30
    /// A success message goes after this long, a failure after `failureShown`.
    public static let successShown: TimeInterval = 6
    public static let failureShown: TimeInterval = 20

    public private(set) var mac: PairedMac?
    public private(set) var state: MacState?
    public private(set) var directPath: ConnectionPath?
    public private(set) var cloudProblem: String?
    public private(set) var outcome: Outcome?
    public private(set) var pairingError: String?
    /// Why the phone is no longer paired, when it did not ask (the Mac
    /// unpaired it).
    public private(set) var unpairNotice: String?
    public private(set) var isPairing = false
    /// A command is on its way: the screen disables its controls.
    public private(set) var isBusy = false
    /// The last shell command sent to the Mac, until cleared or replaced.
    public private(set) var shell: ShellRun?
    public private(set) var now = Date()

    /// A shell command sent to the Mac, and what came back.
    public struct ShellRun: Equatable, Sendable {
        public enum Phase: Equatable, Sendable {
            case running
            case done(ShellOutput)
            case failed(String)
        }

        public var id: UUID
        public var text: String
        /// The agent whose project folder it runs in; nil for the home folder.
        public var agent: MacState.Agent?
        public var since: Date
        public var phase: Phase
    }

    /// Every new Mac state, for the Live Activity and the widgets.
    @ObservationIgnored public var onStateChange: ((MacState) -> Void)?
    /// The phone forgot its Mac: the Live Activity, widgets and watch follow.
    @ObservationIgnored public var onUnpair: (() -> Void)?
    @ObservationIgnored private let deps: Dependencies
    @ObservationIgnored private var identity: PhoneIdentity?
    @ObservationIgnored private var waiters: [UUID: CheckedContinuation<CommandResult?, Never>] = [:]
    @ObservationIgnored private var lastConnectAttempt: Date?
    @ObservationIgnored private var lastCloudFetch: Date?
    @ObservationIgnored private var lastDirectState: Date?
    @ObservationIgnored private var lastAccountCheck: Date?
    /// The Mac's events are subscribed to once per launch, so a subscription
    /// added by an update (Claude's requests) reaches a phone paired before
    /// it. Set only once saved: a failure is tried again.
    @ObservationIgnored private var subscribedThisLaunch = false
    @ObservationIgnored private var outcomeAt: Date?
    @ObservationIgnored private var pairingCancelled = false
    /// Bumped whenever the link to the Mac is reset (unpairing, another
    /// Mac): a command on its way for the old one stops there.
    @ObservationIgnored private var linkGeneration = 0

    public init(_ deps: Dependencies) {
        self.deps = deps
        // Known from launch, before start(): the watch and a button tapped
        // in the background must not take the phone for unpaired.
        mac = deps.store.pairedMac()
        deps.direct.onState = { [weak self] state in self?.receive(state, direct: true) }
        deps.direct.onResult = { [weak self] result in self?.receive(result) }
        deps.direct.onPathChange = { [weak self] path in
            guard let self else { return }
            self.directPath = path
            if path != nil {
                self.lastDirectState = self.deps.now()
            } else {
                // The link died: no answer will come that way, iCloud next.
                for (_, waiter) in self.waiters { waiter.resume(returning: nil) }
                self.waiters = [:]
            }
        }
    }

    public var presence: MacPresence {
        MacPresence.from(state: state, directPath: directPath, now: now)
    }

    // MARK: Lifecycle

    public func start() async {
        mac = deps.store.pairedMac()
        await checkAccount()
        await tick()
    }

    /// A button on a notification: "Prolonger d'1 h" (or start an hour when
    /// the session already ended) or "Arrêter la session". `eventMacID` and
    /// `eventKind`: what the notification was about, when known; another
    /// Mac's notification does nothing here. Sent both ways without waiting
    /// for the answer: an action gets a few seconds in the background, and
    /// the app may have been launched for it.
    /// Returns the command it sent, if any.
    @discardableResult
    public func handleNotificationAction(_ id: String, eventMacID: UUID? = nil, eventKind: MacEvent.Kind? = nil, requestID: UUID? = nil) async -> CommandKind? {
        if mac == nil { mac = deps.store.pairedMac() }
        guard let mac, eventMacID.map({ $0 == mac.macID }) ?? true else { return nil }
        // A Claude request's notification has no session to touch.
        if eventKind == .agentRequest, id == MacEvent.extendAction || id == MacEvent.stopAction { return nil }
        switch id {
        case MacEvent.extendAction:
            // Read first, unless fresh: a session still running is extended,
            // an ended one gives a new hour.
            if state.map({ deps.now().timeIntervalSince($0.updatedAt) > MacPresence.staleAfter }) ?? true {
                await fetchCloudState()
            }
            let noSession: Bool
            if eventKind == .ended {
                noSession = true
            } else if let state, deps.now().timeIntervalSince(state.updatedAt) <= MacPresence.staleAfter {
                noSession = state.session == nil
            } else {
                noSession = false
            }
            let kind: CommandKind = noSession ? .startSession(minutes: 60) : .extendSession(minutes: 60)
            return await fire(kind) ? kind : nil
        case MacEvent.stopAction:
            // "Session terminée": nothing left to stop.
            guard eventKind != .ended else { return nil }
            return await fire(.stopSession) ? .stopSession : nil
        case MacEvent.allowAction, MacEvent.denyAction:
            guard let requestID else { return nil }
            let allow = id == MacEvent.allowAction
            let kind = CommandKind.answerAgentRequest(id: requestID, allow: allow)
            // Accepting asks Face ID, with the app open (the button brings
            // it forward), and shows the Mac's answer; refusing goes as is.
            if allow {
                await send(kind)
                return kind
            }
            return await fire(kind) ? kind : nil
        default:
            return nil
        }
    }

    /// Call every few seconds while the app is in the foreground.
    public func tick() async {
        now = deps.now()
        clearOldOutcome()
        // An iCloud problem, or the events not subscribed to (it failed):
        // checked again every 30 s. The first check is start()'s, so a tick
        // at launch does not subscribe a second time.
        let unsubscribed = mac != nil && !subscribedThisLaunch && lastAccountCheck != nil
        if cloudProblem != nil || unsubscribed, lastAccountCheck.map({ now.timeIntervalSince($0) >= Self.accountCheckInterval }) ?? true {
            await checkAccount()
        }
        guard let mac else { return }
        if directPath != nil {
            if let last = lastDirectState, now.timeIntervalSince(last) > Self.directSilence {
                // Quiet for too long: the Mac slept or left the network.
                deps.direct.disconnect()
                directPath = nil
            } else if let last = lastDirectState, now.timeIntervalSince(last) > 20 {
                deps.direct.requestState()
            }
        }
        if directPath == nil, lastConnectAttempt.map({ now.timeIntervalSince($0) >= Self.reconnectInterval }) ?? true,
           let identity = try? loadIdentity() {
            lastConnectAttempt = now
            deps.direct.connect(to: mac, identity: identity)
        }
        if directPath == nil, lastCloudFetch.map({ now.timeIntervalSince($0) >= Self.cloudFetchInterval }) ?? true {
            await fetchCloudState()
        }
    }

    /// A push said something changed: read iCloud now, whatever the link.
    /// The app may have been launched for it, in the background.
    public func refreshFromCloud() async {
        if mac == nil { mac = deps.store.pairedMac() }
        now = deps.now()
        await fetchCloudState()
    }

    private func checkAccount() async {
        lastAccountCheck = deps.now()
        let wasProblem = cloudProblem != nil
        cloudProblem = await deps.cloud.accountProblem()
        // Once per launch, whatever read iCloud before (a push, a tick);
        // again after an iCloud problem.
        if mac != nil, cloudProblem == nil, wasProblem || !subscribedThisLaunch {
            await subscribe()
        }
    }

    private func subscribe() async {
        subscribedThisLaunch = (try? await deps.cloud.subscribeToEvents()) != nil
    }

    // MARK: Pairing

    /// Pairs from the QR code link: directly when the Mac is reachable,
    /// through iCloud otherwise.
    public func pair(url: URL) async {
        guard !isPairing else { return }
        pairingError = nil
        // A link can come from anywhere: only a normal invite pointing at
        // private addresses is followed.
        if let why = linkProblem(url) {
            pairingError = why
            return
        }
        guard let invite = try? PairingInvite(url: url) else { return }
        isPairing = true
        pairingCancelled = false
        unpairNotice = nil
        defer { isPairing = false }
        let identity: PhoneIdentity
        do {
            identity = try loadIdentity()
        } catch let error as BiometricError {
            pairingError = error.localizedDescription
            return
        } catch {
            pairingError = "Trousseau : \(error.localizedDescription)"
            return
        }
        let request = identity.pairingRequest(for: invite, at: deps.now())

        var response: PairingResponse?
        if invite.endpoints != nil {
            response = try? await deps.pairing.pair(request, invite: invite)
        }
        if response == nil, !pairingCancelled {
            response = await pairThroughCloud(request, until: invite.expiresAt)
        }
        guard !pairingCancelled else { return }
        guard let response else {
            pairingError = cloudProblem == nil
                ? "Le Mac ne répond pas. Vérifie qu'il est allumé, sur le même réseau que cet iPhone ou connecté au même compte iCloud."
                : "Le Mac ne répond pas sur ce réseau, et iCloud n'est pas disponible sur cet iPhone. Mets-les sur le même Wi-Fi, ou connecte cet iPhone à iCloud."
            return
        }
        guard response.accepted else {
            pairingError = response.message ?? "Le Mac a refusé l'appairage."
            return
        }
        // Where the Mac's main listener is: its answer, else the invite's
        // addresses on the usual port (the invite's port was the pairing one).
        var endpoints = response.endpoints
        if endpoints == nil, var fromInvite = invite.endpoints {
            fromInvite.port = LinkProtocol.defaultPort
            endpoints = fromInvite
        }
        if let e = endpoints, !e.isPlausible { endpoints = nil }
        let paired = PairedMac(macID: invite.macID, macName: response.macName.isEmpty ? invite.macName : response.macName,
                               agreementKey: invite.macAgreementKey, endpoints: endpoints, pairedAt: deps.now(),
                               macPairedAt: response.pairedAt)
        // Another Mac than before: the old one is asked to forget this
        // phone (best effort), and nothing of it stays on screen.
        let replacing = mac.map { $0.macID != paired.macID } ?? false
        if replacing { _ = await fire(.forgetThisDevice) }
        do {
            try deps.store.save(paired)
        } catch {
            pairingError = "Trousseau : \(error.localizedDescription)"
            return
        }
        if replacing {
            resetLink()
            onUnpair?()
        } else if mac == nil {
            resetLink()
        }
        mac = paired
        lastConnectAttempt = nil
        await subscribe()
        await tick()
    }

    /// Why this link cannot pair, or nil: checked before asking the user
    /// to confirm a link opened from another app.
    public func linkProblem(_ url: URL) -> String? {
        guard let invite = try? PairingInvite(url: url) else { return "Ce code n'est pas un code DarraOwl." }
        guard deps.now() <= invite.expiresAt else { return "Ce code a expiré. Affiche-en un nouveau sur le Mac." }
        return invite.implausibility(now: deps.now())
    }

    /// "Annuler" while pairing waits for the Mac.
    public func cancelPairing() {
        pairingCancelled = true
    }

    private func pairThroughCloud(_ request: PairingRequest, until deadline: Date) async -> PairingResponse? {
        guard let id = try? await deps.cloud.sendPairing(request) else { return nil }
        while !pairingCancelled, deps.now() <= deadline.addingTimeInterval(5) {
            await deps.sleeper.sleep(seconds: Self.cloudPollInterval)
            if let response = try? await deps.cloud.pairingResponse(requestID: id) { return response }
        }
        return nil
    }

    /// Forgets the Mac and this phone's keys, after asking the Mac to forget
    /// this phone too (both ways, without waiting: it works offline).
    public func unpair() async {
        // Read before anything is sent or reset.
        let listed = state?.pairedDevices
        _ = await fire(.forgetThisDevice)
        if forget(notice: nil, listed: listed) { try? await deps.cloud.unsubscribeFromEvents() }
    }

    /// Drops the Mac and the keys. Returns whether the notifications go too:
    /// their subscription is shared by every phone of the iCloud account,
    /// so it goes only when no other phone is paired with this Mac.
    /// `listed`: the phones the Mac last listed (nil: not known).
    private func forget(notice: String?, listed: [UUID]?) -> Bool {
        let me = identity?.deviceID ?? (try? deps.store.identity())?.deviceID
        let others = listed.map { ids in ids.filter { $0 != me } }
        resetLink()
        try? deps.store.forgetMac()
        // The keys were deleted with it: the next pairing makes new ones.
        identity = nil
        mac = nil
        pairingError = nil
        unpairNotice = notice
        onUnpair?()
        return others?.isEmpty ?? true
    }

    /// Drops everything about the current Mac's connection and state.
    private func resetLink() {
        linkGeneration += 1
        deps.direct.disconnect()
        state = nil
        directPath = nil
        outcome = nil
        outcomeAt = nil
        shell = nil
        lastConnectAttempt = nil
        lastCloudFetch = nil
        lastDirectState = nil
        for (_, waiter) in waiters { waiter.resume(returning: nil) }
        waiters = [:]
    }

    // MARK: Commands

    /// Signs (Face ID for sensitive commands), sends by the best path,
    /// waits for the Mac's answer. Ignored while another command is on its
    /// way (the screen disables its buttons meanwhile).
    public func send(_ kind: CommandKind) async {
        guard let mac else {
            show(.failed("Aucun Mac appairé sur cet iPhone."))
            return
        }
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let generation = linkGeneration
        show(.sending(kind.label))
        guard case let (envelope, signed)? = await sign(kind, for: mac) else { return }

        var result: CommandResult?
        if directPath != nil {
            result = await waitDirect(envelope.id) { try deps.direct.send(signed) }
        }
        // Unpaired, or another Mac, meanwhile: the command stops here.
        guard linkGeneration == generation else { return }
        // No direct answer: the same signed command through iCloud. The Mac
        // runs a command once and answers a copy with the real result.
        if result == nil {
            do {
                try await deps.cloud.send(signed, macID: mac.macID)
                guard linkGeneration == generation else { return }
                // Apple can hold the push to the Mac some 10 s: shown, so the
                // wait is not taken for a hang.
                show(.sending("\(kind.label) · par iCloud"))
                result = await waitCloud(envelope.id, until: envelope.expiresAt, generation: generation)
            } catch {
                show(.failed("Envoi impossible : \(error.localizedDescription)"))
                return
            }
        }
        guard linkGeneration == generation, self.mac?.macID == mac.macID else { return }
        guard let result else {
            show(.failed("Pas de réponse du Mac avant l'expiration de la commande."))
            return
        }
        show(Self.outcome(for: result, kind: kind))
        if result.status == .executed {
            if directPath != nil { deps.direct.requestState() } else { await fetchCloudState() }
        }
    }

    /// Signs and sends without waiting for the Mac's answer: for Siri and
    /// the Live Activity buttons, which have a few seconds only. Sent both
    /// ways, since a direct link can be dead without knowing it yet; the Mac
    /// runs it once. Returns false when it could not be sent at all.
    @discardableResult
    public func fire(_ kind: CommandKind) async -> Bool {
        if mac == nil { mac = deps.store.pairedMac() }
        guard let mac, let (_, signed) = try? await loadIdentity().sign(kind, for: mac, at: deps.now()) else { return false }
        var sent = false
        if directPath != nil, (try? deps.direct.send(signed)) != nil { sent = true }
        if (try? await deps.cloud.send(signed, macID: mac.macID)) != nil { sent = true }
        return sent
    }

    /// Signs `kind` (Face ID for a sensitive one); nil, with why on
    /// screen, when it cannot be.
    private func sign(_ kind: CommandKind, for mac: PairedMac) async -> (CommandEnvelope, SignedCommand)? {
        do {
            return try await loadIdentity().sign(kind, for: mac, at: deps.now())
        } catch BiometricError.refused {
            show(.failed("Face ID refusé : commande non envoyée."))
        } catch BiometricError.keyInvalidated {
            show(.failed("Face ID a changé sur cet iPhone : sa clé n'est plus valable. Désappaire cet iPhone, puis appaire-le à nouveau."))
        } catch {
            show(.failed("Signature impossible : \(error.localizedDescription)"))
        }
        return nil
    }

    // MARK: Shell commands

    /// Signs (Face ID) and sends a shell command, then waits for what it
    /// printed in the background: a command may run minutes, and the other
    /// controls are not held meanwhile. Followed in `shell`.
    public func runShell(_ text: String, agent: MacState.Agent? = nil) async {
        guard let mac else {
            show(.failed("Aucun Mac appairé sur cet iPhone."))
            return
        }
        guard !isBusy, shell?.phase != .running else { return }
        isBusy = true
        let signed = await sign(.runCommand(text: text, inAgent: agent?.pid), for: mac)
        isBusy = false
        guard case let (envelope, command)? = signed else { return }
        let generation = linkGeneration
        shell = ShellRun(id: envelope.id, text: text, agent: agent, since: deps.now(), phase: .running)
        Task { await self.awaitShell(envelope, command, mac: mac, generation: generation) }
    }

    /// Takes the last command off the screen.
    public func clearShell() {
        shell = nil
    }

    private func awaitShell(_ envelope: CommandEnvelope, _ signed: SignedCommand, mac: PairedMac, generation: Int) async {
        // Until the Mac would have stopped the command, and a little more.
        let patience = Policy.remoteCommandTimeout + 20
        let deadline = envelope.issuedAt.addingTimeInterval(patience)
        var result: CommandResult?
        var sentThroughCloud = false
        if directPath != nil {
            // The direct link can drop while the command runs (the app
            // suspended, another network) and its answer with it: a few
            // seconds on, the command also goes through iCloud, where the Mac
            // leaves a shell command's result whatever path it came by. The
            // Mac runs it once; the first answer wins.
            let backup = Task { [weak self] () -> Bool in
                guard let self else { return false }
                await self.deps.sleeper.sleep(seconds: Self.shellBackupDelay)
                guard !Task.isCancelled, self.waiters[envelope.id] != nil, self.linkGeneration == generation,
                      (try? await self.deps.cloud.send(signed, macID: mac.macID)) != nil
                else { return false }
                if let answer = await self.waitShellCloud(envelope.id, until: deadline, generation: generation) {
                    self.waiters.removeValue(forKey: envelope.id)?.resume(returning: answer)
                }
                return true
            }
            result = await waitDirect(envelope.id, timeout: patience) { try deps.direct.send(signed) }
            backup.cancel()
            sentThroughCloud = await backup.value
        }
        guard linkGeneration == generation else { return }
        if result == nil {
            // No answer: the same command through iCloud, where the Mac
            // leaves a shell command's result whatever path it came by.
            if !sentThroughCloud {
                do {
                    try await deps.cloud.send(signed, macID: mac.macID)
                } catch {
                    finishShell(envelope.id, .failed("Envoi impossible : \(error.localizedDescription)"))
                    return
                }
            }
            guard linkGeneration == generation else { return }
            result = await waitShellCloud(envelope.id, until: deadline, generation: generation)
        }
        guard linkGeneration == generation, self.mac?.macID == mac.macID else { return }
        guard let result else {
            finishShell(envelope.id, .failed("Pas de réponse du Mac."))
            return
        }
        switch result.status {
        case .executed:
            guard let output = result.output else {
                finishShell(envelope.id, .failed("Le Mac n'a pas renvoyé ce que la commande a affiché."))
                return
            }
            finishShell(envelope.id, .done(output))
            // The command may have changed what the Mac shows.
            if directPath != nil {
                deps.direct.requestState()
                // The Mac also left this result in iCloud, a moment after
                // answering: read, so it goes now rather than in a day.
                let cloud = deps.cloud
                let sleeper = deps.sleeper
                let id = envelope.id
                Task {
                    await sleeper.sleep(seconds: 5)
                    _ = try? await cloud.result(for: id)
                }
            } else {
                await fetchCloudState()
            }
        default:
            if case let .failed(why) = Self.outcome(for: result, kind: envelope.kind) {
                finishShell(envelope.id, .failed(why))
            } else {
                finishShell(envelope.id, .failed(result.message ?? "Réponse inattendue du Mac : \(result.status.label)."))
            }
        }
    }

    /// The command still on screen gets its outcome; a cleared or replaced
    /// one is left alone.
    private func finishShell(_ id: UUID, _ phase: ShellRun.Phase) {
        guard shell?.id == id else { return }
        shell?.phase = phase
    }

    /// Polls iCloud for the result until `deadline`, with one read after
    /// it: back from a long suspension, the result may well be there.
    private func waitShellCloud(_ id: UUID, until deadline: Date, generation: Int) async -> CommandResult? {
        while linkGeneration == generation, !Task.isCancelled {
            if let result = try? await deps.cloud.result(for: id) { return result }
            guard deps.now() <= deadline else { return nil }
            await deps.sleeper.sleep(seconds: Self.shellPollInterval)
        }
        return nil
    }

    static func outcome(for result: CommandResult, kind: CommandKind) -> Outcome {
        switch result.status {
        case .executed: .done(doneText(kind))
        case .duplicate: .done("\(kind.label) : déjà reçue par le Mac.")
        case .failed: .failed(result.message ?? "Échec sur le Mac.")
        case .expired: .failed("Commande expirée. Vérifie que l'iPhone et le Mac sont à l'heure (réglage automatique).")
        case .rejected, .unauthorized: .failed(result.message ?? "Refusé par le Mac.")
        }
    }

    /// An answer to Claude is sent, not done: an MCP tool that wants its own
    /// dialog ignores a hook's accept and asks in the terminal, and the hook
    /// does not say which tools do.
    private static func doneText(_ kind: CommandKind) -> String {
        guard case let .answerAgentRequest(_, allow) = kind else { return "\(kind.label) : fait." }
        return allow ? "Accord envoyé à Claude." : "Refus envoyé à Claude."
    }

    // MARK: Private

    private func show(_ outcome: Outcome) {
        self.outcome = outcome
        outcomeAt = deps.now()
    }

    /// A message does not stay on screen forever.
    private func clearOldOutcome() {
        guard let outcome, let at = outcomeAt else { return }
        let age = now.timeIntervalSince(at)
        switch outcome {
        case .done where age > Self.successShown, .failed where age > Self.failureShown:
            self.outcome = nil
            outcomeAt = nil
        default:
            break
        }
    }

    private func loadIdentity() throws -> PhoneIdentity {
        if let identity { return identity }
        let loaded = try deps.store.identity()
        identity = loaded
        return loaded
    }

    private func receive(_ state: MacState, direct: Bool) {
        guard let mac, state.macID == mac.macID else { return }
        if direct { lastDirectState = deps.now() }
        // An older iCloud copy must not replace a newer state. A direct state
        // is live: always taken, even when the Mac's clock went back.
        if !direct, let current = self.state, state.updatedAt < current.updatedAt { return }
        // Unpaired on the Mac: a state it published after pairing this phone
        // no longer lists it. Nothing of that Mac stays here.
        if let ids = state.pairedDevices, let since = mac.macPairedAt, state.updatedAt > since,
           let me = (try? loadIdentity())?.deviceID, !ids.contains(me) {
            if forget(notice: "« \(mac.macName) » a désappairé cet iPhone.", listed: ids) {
                let cloud = deps.cloud
                Task { try? await cloud.unsubscribeFromEvents() }
            }
            return
        }
        self.state = state
        now = deps.now()
        onStateChange?(state)
    }

    private func receive(_ result: CommandResult) {
        waiters.removeValue(forKey: result.commandID)?.resume(returning: result)
    }

    /// Waits for a direct result. The waiter is in place before the command
    /// leaves: an answer that comes back at once is not missed.
    private func waitDirect(_ id: UUID, timeout: Double = PhoneModel.directResultTimeout, sending: () throws -> Void) async -> CommandResult? {
        let sleeper = deps.sleeper
        return await withCheckedContinuation { continuation in
            waiters[id] = continuation
            do {
                try sending()
            } catch {
                waiters.removeValue(forKey: id)?.resume(returning: nil)
                return
            }
            Task {
                await sleeper.sleep(seconds: timeout)
                self.waiters.removeValue(forKey: id)?.resume(returning: nil)
            }
        }
    }

    private func waitCloud(_ id: UUID, until expiry: Date, generation: Int) async -> CommandResult? {
        while deps.now() <= expiry.addingTimeInterval(10), linkGeneration == generation {
            await deps.sleeper.sleep(seconds: Self.cloudPollInterval)
            if let result = try? await deps.cloud.result(for: id) { return result }
        }
        return nil
    }

    private func fetchCloudState() async {
        guard let mac else { return }
        lastCloudFetch = deps.now()
        do {
            if let (state, endpoints) = try await deps.cloud.fetchState(macID: mac.macID) {
                receive(state, direct: false)
                if let endpoints, endpoints != self.mac?.endpoints, endpoints.isPlausible, self.mac?.macID == mac.macID {
                    var updated = mac
                    updated.endpoints = endpoints
                    try? deps.store.save(updated)
                    self.mac = updated
                }
            }
            cloudProblem = nil
        } catch {
            cloudProblem = "iCloud : \(error.localizedDescription)"
        }
    }
}
