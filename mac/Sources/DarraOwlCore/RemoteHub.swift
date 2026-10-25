import CryptoKit
import DarraOwlShared
import Foundation

// MARK: Dependencies (live ones in DarraOwlSystem)

/// This Mac's long-term identity. The private key never leaves the Keychain.
public struct MacIdentity: Sendable {
    public var macID: UUID
    public var agreementKey: Curve25519.KeyAgreement.PrivateKey

    public init(macID: UUID, agreementKey: Curve25519.KeyAgreement.PrivateKey) {
        self.macID = macID
        self.agreementKey = agreementKey
    }
}

/// Keychain: the Mac identity and the paired devices.
@MainActor
public protocol PairingStore: AnyObject {
    func identity() throws -> MacIdentity
    func devices() throws -> [PairedDevice]
    func add(_ device: PairedDevice) throws
    func remove(deviceID: UUID) throws
}

/// What a phone command does on this Mac.
@MainActor
public protocol CommandTarget: AnyObject {
    func startSession(seconds: TimeInterval) async throws
    func extendSession(seconds: TimeInterval) async throws
    func stopSession() async throws
    func sleepNow() async throws
    func pauseDocker() async throws
    func resumeDocker() async throws
    func stopContainer(id: String) async throws
    func updateSettings(_ settings: PowerSettings) async throws
    /// Agent mode: stay awake while this agent runs.
    func watchAgent(pid: Int32) async throws
    /// Agents now running, to check a watch or stop request against.
    var agentPIDs: [Int32] { get }
    func stopAgent(pid: Int32) async throws
    /// nil: no end time.
    func startPresence(seconds: TimeInterval?) async throws
    func stopPresence() async throws
    func displayOff() async throws
    func lockScreen() async throws
    func setMuted(_ muted: Bool) async throws
    func pauseApps() async throws
    func resumeApps() async throws
    func setPresenceWhileClosed(_ on: Bool) async throws
    /// Claude Code's request `id`, held for the phone: accepted or refused.
    func answerAgentRequest(id: UUID, allow: Bool) async throws
    /// A shell command from the phone, in the project folder of agent
    /// `agentPID` (nil: the home folder). Refused unless the Mac's option
    /// is on. Returns what it printed.
    func runCommand(_ text: String, agentPID: Int32?) async throws -> ShellOutput
    /// Settings now, to merge a partial change into.
    var currentSettings: PowerSettings? { get }
    /// Containers now running, to check a stop request against.
    var containerIDs: [String] { get }
}

/// The iCloud mailbox: the user's private CloudKit database.
@MainActor
public protocol CloudMailbox: AnyObject {
    func publish(state: MacState, endpoints: Endpoints?) async throws
    /// Commands and pairing requests written by the phone since the last call.
    func fetchInbox() async throws -> CloudInbox
    func deliver(result: CommandResult) async throws
    func deliver(pairing: PairingResponse, requestID: String) async throws
    func discard(itemIDs: [String]) async throws
    /// An `Event` record: the phone's subscription turns it into a notification.
    func post(_ event: MacEvent) async throws
    /// Deletes this Mac's events older than `date`.
    func removeEvents(before date: Date) async
    /// Deletes one event (a Claude request ended: its detail goes), now or,
    /// when iCloud fails, at a later read of the inbox.
    func removeEvent(id: UUID) async
}

public struct CloudInbox: Sendable {
    public var commands: [(itemID: String, command: SignedCommand)]
    public var pairings: [(itemID: String, request: PairingRequest)]

    public init(commands: [(itemID: String, command: SignedCommand)] = [], pairings: [(itemID: String, request: PairingRequest)] = []) {
        self.commands = commands
        self.pairings = pairings
    }
}

// MARK: Hub

/// Everything between the phone and the Mac, whatever the path: pairing,
/// command checks and execution, state publishing. One instance in the app.
@MainActor
public final class RemoteHub {
    public enum Channel: String, Sendable { case direct, cloud }

    /// Publish at most this often, and at least this often.
    public static let minPublishInterval: TimeInterval = 2
    public static let heartbeat: TimeInterval = 60

    /// iCloud is read this often when no push came (pushes are best effort,
    /// and Apple can hold one 10 s). Right after a phone command another
    /// one often follows: every 3 s for two minutes. Otherwise 20 s in a
    /// session, 30 s outside: well within the 60 s a command lives, even
    /// after the phone spent 10 s on the direct link first.
    public static let fastPoll = 3
    public static let fastPollWindow: TimeInterval = 120
    public static let sessionPoll = 20
    public static let idlePoll = 30

    private let store: any PairingStore
    private let target: any CommandTarget
    private let cloud: (any CloudMailbox)?
    private let ledgerStore: any ValueStoring<CommandLedger>
    private let clock: any NowProviding
    private let log: any EngineLogging
    private let random: () -> Data

    public private(set) var invite: PairingInvite?
    private var ledger: CommandLedger
    private var lastPublished: (state: MacState, at: Date)?
    /// After an iCloud failure, wait this long, doubling up to 10 min. Each
    /// kind of operation backs off on its own: a publish that keeps failing
    /// must not stop the inbox from being read.
    public static let firstBackoff: TimeInterval = 30
    /// The inbox waits less: a phone command lives 60 s.
    static let maxInboxBackoff: TimeInterval = 60
    enum CloudOperation: Hashable { case publish, inbox, events }
    private var backoffs: [CloudOperation: (until: Date, delay: TimeInterval, error: String)] = [:]
    private var publishing = false
    /// A publish is on its way to iCloud (a forced one may follow it).
    public var isPublishing: Bool { publishing }
    /// A forced publish asked for while another one was on its way.
    private var forcedNext: (state: MacState, endpoints: Endpoints?)?
    private var polling = false
    /// A poll asked for while another one ran: done right after it.
    private var pollAgain = false
    /// When the last command or pairing request came through iCloud.
    private var lastCloudRequest: Date?
    private var posting = false
    /// Commands being run now.
    private var running: Set<UUID> = []
    /// Commands whose iCloud copy arrived while they ran: their result goes
    /// to iCloud once known, so the phone reads the real outcome.
    private var cloudAwaiting: Set<UUID> = []
    /// Answers that could not be written to iCloud: written at the next poll
    /// (the inbox does not return an item twice).
    private var undeliveredResults: [CommandResult] = []
    private var undeliveredPairings: [(response: PairingResponse, requestID: String)] = []
    /// The last accepted pairing, so the same phone asking again (its first
    /// answer was lost) is answered again instead of refused.
    private var lastPairing: (invite: PairingInvite, deviceID: UUID)?
    /// Called after a device is removed, so the direct link can drop it.
    public var onDeviceRemoved: ((UUID) -> Void)?
    /// Called after a pairing succeeded, whichever path it came by (direct
    /// or iCloud), so the window and the direct server catch up.
    public var onPaired: ((PairedDevice, RemoteHub.Channel) -> Void)?
    /// Called with every result, so the direct link can send it.
    public var onResult: ((CommandResult) -> Void)?
    /// Called once a command ran, before its result reaches iCloud: the
    /// Mac's new state leaves first, so a phone reading it after the result
    /// sees the change.
    public var afterCommand: (() async -> Void)?

    public init(
        store: any PairingStore, target: any CommandTarget, cloud: (any CloudMailbox)?,
        ledgerStore: any ValueStoring<CommandLedger>, clock: any NowProviding, log: any EngineLogging,
        random: @escaping () -> Data = { Data((0..<32).map { _ in UInt8.random(in: 0...255) }) }
    ) {
        self.store = store
        self.target = target
        self.cloud = cloud
        self.ledgerStore = ledgerStore
        self.clock = clock
        self.log = log
        self.random = random
        self.ledger = (try? ledgerStore.load()) ?? CommandLedger()
    }

    public var results: [CommandResult] { ledger.results }

    // MARK: Pairing

    public func makeInvite(macName: String, endpoints: Endpoints?) throws -> PairingInvite {
        let identity = try store.identity()
        let invite = PairingInvite(
            macID: identity.macID, macName: macName,
            macAgreementKey: identity.agreementKey.publicKey.rawRepresentation,
            secret: random(), expiresAt: clock.now().addingTimeInterval(PairingInvite.lifetime),
            endpoints: endpoints
        )
        self.invite = invite
        return invite
    }

    public func cancelInvite() {
        invite = nil
    }

    /// Accepts the request only for the invite on screen, once, before it expires.
    public func handlePairing(_ request: PairingRequest, macName: String, via channel: Channel = .direct) -> PairingResponse {
        let macID = (try? store.identity().macID) ?? request.macID
        func refuse(_ m: String) -> PairingResponse {
            log.error("pairing refused: \(m)")
            return PairingResponse(accepted: false, macID: macID, macName: macName, message: m)
        }
        if let again = repeatedPairing(request) {
            log.info("pairing of \(request.deviceID) confirmed again via \(channel.rawValue)")
            return PairingResponse(accepted: true, macID: macID, macName: macName, message: nil, endpoints: again.endpoints, pairedAt: again.pairedAt)
        }
        guard let invite, invite.macID == request.macID else { return refuse("Aucun appairage en cours sur le Mac.") }
        guard clock.now() <= invite.expiresAt else {
            self.invite = nil
            return refuse("Le code a expiré. Affiche-en un nouveau sur le Mac.")
        }
        guard request.hasValidProof(secret: invite.secret) else { return refuse("Code invalide.") }
        guard (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: request.agreementKey)) != nil,
              (try? Curve25519.Signing.PublicKey(rawRepresentation: request.signingKey)) != nil,
              (try? P256.Signing.PublicKey(x963Representation: request.biometricKey)) != nil
        else { return refuse("Clés de l'iPhone invalides.") }
        // A paired device's id with other keys: never a takeover of its entry.
        if let known = pairedDevices().first(where: { $0.id == request.deviceID }),
           known.agreementKey != request.agreementKey || known.signingKey != request.signingKey || known.biometricKey != request.biometricKey {
            return refuse("Cet iPhone est déjà appairé : désappaire-le d'abord sur le Mac.")
        }

        let name = String(request.deviceName.prefix(60))
        let device = PairedDevice(
            id: request.deviceID, name: name, agreementKey: request.agreementKey,
            signingKey: request.signingKey, biometricKey: request.biometricKey, pairedAt: clock.now()
        )
        do {
            try store.add(device)
        } catch {
            return refuse("Trousseau : \(error.localizedDescription)")
        }
        self.invite = nil
        lastPairing = (invite, device.id)
        log.info("paired device \(device.id) (\(name)) via \(channel.rawValue)")
        // Where the main listener is now: read before onPaired restarts it.
        let endpoints = mainEndpoints?()
        onPaired?(device, channel)
        return PairingResponse(accepted: true, macID: macID, macName: macName, message: nil, endpoints: endpoints, pairedAt: device.pairedAt)
    }

    /// Where the phone reaches the paired-devices listener (not the pairing
    /// one). Set by the app.
    public var mainEndpoints: (() -> Endpoints?)?

    /// The phone of the last pairing asks again with the same invite and the
    /// same keys, before that invite would have expired: its first answer
    /// was lost. Returns what to answer with.
    private func repeatedPairing(_ request: PairingRequest) -> (endpoints: Endpoints?, pairedAt: Date)? {
        guard let last = lastPairing, last.deviceID == request.deviceID, last.invite.macID == request.macID,
              clock.now() <= last.invite.expiresAt, request.hasValidProof(secret: last.invite.secret),
              let stored = pairedDevices().first(where: { $0.id == request.deviceID }),
              stored.agreementKey == request.agreementKey, stored.signingKey == request.signingKey,
              stored.biometricKey == request.biometricKey
        else { return nil }
        return (mainEndpoints?(), stored.pairedAt)
    }

    public func unpair(deviceID: UUID) throws {
        try store.remove(deviceID: deviceID)
        if lastPairing?.deviceID == deviceID { lastPairing = nil }
        onDeviceRemoved?(deviceID)
        log.info("unpaired device \(deviceID)")
    }

    public func pairedDevices() -> [PairedDevice] {
        (try? store.devices()) ?? []
    }

    /// TLS pre-shared key for a paired device, nil for anyone else.
    public func linkKey(deviceID: UUID) -> SymmetricKey? {
        guard let identity = try? store.identity(),
              let device = pairedDevices().first(where: { $0.id == deviceID }),
              let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: device.agreementKey),
              let shared = try? identity.agreementKey.sharedSecretFromKeyAgreement(with: peer)
        else { return nil }
        return LinkKeys.linkKey(shared: shared, macID: identity.macID, deviceID: deviceID)
    }

    /// TLS pre-shared key of the pairing connection, while an invite is on screen.
    public func pairingKey(identity: String) -> SymmetricKey? {
        guard let invite, clock.now() <= invite.expiresAt,
              identity == LinkKeys.pairingIdentity(secret: invite.secret)
        else { return nil }
        return LinkKeys.pairingKey(secret: invite.secret, macID: invite.macID)
    }

    // MARK: Commands

    /// Verifies, runs once, records the result. `peer` is the device the
    /// direct link authenticated, which must be the signer.
    public func handle(_ signed: SignedCommand, via channel: Channel, peer: UUID? = nil) async -> CommandResult {
        let now = clock.now()
        ledger.prune(now: now)
        guard let identity = try? store.identity() else {
            return finish(CommandResult(commandID: UUID(), status: .failed, message: "Identité du Mac illisible.", at: now))
        }
        if let peer, peer != signed.deviceID {
            return finish(CommandResult(commandID: UUID(), status: .unauthorized, message: "Appareil différent de la connexion.", at: now))
        }
        let devices = Dictionary(uniqueKeysWithValues: pairedDevices().map { ($0.id, $0) })
        switch CommandAuthority.verify(signed, macID: identity.macID, devices: devices, ledger: ledger, now: now) {
        case let .reject(result):
            // A command that already ran (its iCloud copy, late, or read
            // after its device was unpaired): answered with what really
            // happened, never with a refusal that would replace it.
            if let recorded = ledger.results.last(where: { $0.commandID == result.commandID && $0.status.isOutcome }) {
                log.info("command \(result.commandID) again via \(channel.rawValue): answered with its result")
                return recorded
            }
            if result.status == .duplicate {
                if running.contains(result.commandID) {
                    if channel == .cloud { cloudAwaiting.insert(result.commandID) }
                    log.info("command \(result.commandID) again via \(channel.rawValue) while it runs")
                    return result
                }
            }
            log.error("command \(result.commandID) \(result.status.rawValue) via \(channel.rawValue): \(result.message ?? "")")
            return finish(result)
        case let .accept(envelope):
            // Marked seen before it runs: a crash mid-run never runs it twice.
            ledger.markSeen(envelope.id, expiresAt: envelope.expiresAt)
            persistLedger()
            log.info("command \(envelope.id) \(envelope.kind.label) via \(channel.rawValue)")
            running.insert(envelope.id)
            let result: CommandResult
            do {
                let output = try await run(envelope.kind, from: envelope.deviceID)
                result = finish(CommandResult(commandID: envelope.id, status: .executed, message: nil, at: clock.now(), output: output))
            } catch {
                result = finish(CommandResult(commandID: envelope.id, status: .failed, message: error.localizedDescription, at: clock.now()))
            }
            await afterCommand?()
            running.remove(envelope.id)
            let cloudCopyWaits = cloudAwaiting.remove(envelope.id) != nil
            // A shell command can run minutes: its result goes to iCloud
            // whatever the path, for a phone that lost the direct link
            // meanwhile (its app suspended). The record goes once read, or
            // after a day.
            if channel != .cloud, cloudCopyWaits || envelope.kind.isShell {
                await deliverToCloud(result)
            }
            return result
        }
    }

    /// Runs the command; a shell command returns what it printed.
    private func run(_ kind: CommandKind, from deviceID: UUID) async throws -> ShellOutput? {
        switch kind {
        case let .startSession(m): try await target.startSession(seconds: CommandKind.seconds(m))
        case let .extendSession(m): try await target.extendSession(seconds: CommandKind.seconds(m))
        case .stopSession: try await target.stopSession()
        case .sleepNow: try await target.sleepNow()
        case .pauseDocker: try await target.pauseDocker()
        case .resumeDocker: try await target.resumeDocker()
        case let .stopContainer(id):
            guard target.containerIDs.contains(id) else { throw RemoteError.unknownContainer }
            try await target.stopContainer(id: id)
        case let .updateLidSettings(lid):
            guard var s = target.currentSettings else { throw RemoteError.helperUnavailable }
            s.lid = lid
            try await target.updateSettings(s)
        case let .updateAlerts(alerts):
            guard var s = target.currentSettings else { throw RemoteError.helperUnavailable }
            s.alerts = alerts
            try await target.updateSettings(s)
        case let .watchAgent(pid):
            guard target.agentPIDs.contains(pid) else { throw RemoteError.unknownAgent }
            try await target.watchAgent(pid: pid)
        case let .stopAgent(pid):
            guard target.agentPIDs.contains(pid) else { throw RemoteError.unknownAgent }
            try await target.stopAgent(pid: pid)
        case let .startPresence(m): try await target.startPresence(seconds: m.map { TimeInterval($0 * 60) })
        case .stopPresence: try await target.stopPresence()
        case .displayOff: try await target.displayOff()
        case .lockScreen: try await target.lockScreen()
        case let .setMuted(muted): try await target.setMuted(muted)
        case .pauseApps: try await target.pauseApps()
        case .resumeApps: try await target.resumeApps()
        case .forgetThisDevice:
            // Only ever the signer itself.
            try unpair(deviceID: deviceID)
        case let .setPresenceWhileClosed(on): try await target.setPresenceWhileClosed(on)
        case let .answerAgentRequest(id, allow): try await target.answerAgentRequest(id: id, allow: allow)
        case let .updateBatteryFloors(lowPower, end):
            guard var s = target.currentSettings else { throw RemoteError.helperUnavailable }
            s.lowPowerFloor = lowPower
            s.endFloor = end
            try await target.updateSettings(s)
        case let .runCommand(text, pid):
            if let pid { guard target.agentPIDs.contains(pid) else { throw RemoteError.unknownAgent } }
            return try await target.runCommand(text, agentPID: pid)
        }
        return nil
    }

    private func finish(_ result: CommandResult) -> CommandResult {
        ledger.record(result)
        persistLedger()
        onResult?(result)
        return result
    }

    private func persistLedger() {
        do { try ledgerStore.save(ledger) } catch { log.error("command ledger not written: \(error.localizedDescription)") }
    }

    // MARK: iCloud

    /// Publishes when the state changed (at most every 2 s) or the last
    /// publish is a minute old. Returns true when it published.
    /// `force` (going to sleep, waking up): now, whatever the back-off, and
    /// right after the publish on its way if there is one.
    @discardableResult
    public func publishIfDue(_ state: MacState, endpoints: Endpoints?, force: Bool = false) async -> Bool {
        guard let cloud else { return false }
        if publishing {
            if force { forcedNext = (state, endpoints) }
            return false
        }
        let now = clock.now()
        if !force {
            if isBackingOff(.publish) { return false }
            if let last = lastPublished {
                let age = now.timeIntervalSince(last.at)
                let changed = !Self.sameContent(last.state, state, ignoringCounters: true)
                guard (changed && age >= Self.minPublishInterval) || age >= Self.heartbeat else { return false }
            }
        }
        publishing = true
        var published = false
        var next: (state: MacState, endpoints: Endpoints?)? = (state, endpoints)
        while let item = next {
            next = nil
            do {
                try await cloud.publish(state: item.state, endpoints: item.endpoints)
                if lastPublished == nil || cloudError != nil { log.info("iCloud: state published") }
                lastPublished = (item.state, clock.now())
                succeeded(.publish)
                published = true
            } catch {
                failed(error, .publish, "iCloud publish failed")
            }
            if let forced = forcedNext {
                forcedNext = nil
                next = forced
            }
        }
        publishing = false
        return published
    }

    /// Sends events now; on failure they wait in memory for the next try
    /// (at most 20, the oldest dropped). One sender at a time: a call made
    /// while another one sends only adds its events to the queue.
    public func post(_ events: [MacEvent]) async {
        enqueue(events)
        guard let cloud, !posting, !pendingEvents.isEmpty, !isBackingOff(.events) else { return }
        posting = true
        defer { posting = false }
        while let event = pendingEvents.first {
            sending = event.id
            do {
                try await cloud.post(event)
                sending = nil
                pendingEvents.removeAll { $0.id == event.id }
                succeeded(.events)
                log.info("event \(event.kind.rawValue) sent")
                if withdrawnWhileSending.remove(event.id) != nil { await cloud.removeEvent(id: event.id) }
            } catch {
                sending = nil
                failed(error, .events, "iCloud event")
                if withdrawnWhileSending.remove(event.id) != nil {
                    // Not sent again; deleted in case the save went through.
                    pendingEvents.removeAll { $0.id == event.id }
                    await cloud.removeEvent(id: event.id)
                }
                return
            }
        }
    }

    /// Queues events for the next `post`, at once: an event queued then
    /// withdrawn in the same breath is never sent.
    public func enqueue(_ events: [MacEvent]) {
        pendingEvents += events
        if pendingEvents.count > Self.maxPendingEvents { pendingEvents.removeFirst(pendingEvents.count - Self.maxPendingEvents) }
    }

    /// Takes back event `id` (a Claude request that ended): a queued one is
    /// never sent, one being sent is deleted once saved, a sent one now (in
    /// the background).
    public func withdrawEvent(_ id: UUID) {
        if sending == id {
            withdrawnWhileSending.insert(id)
            return
        }
        pendingEvents.removeAll { $0.id == id }
        guard let cloud else { return }
        // Even when it was only queued: an earlier failed save may have gone through.
        Task { await cloud.removeEvent(id: id) }
    }

    static let maxPendingEvents = 20
    public private(set) var pendingEvents: [MacEvent] = []
    /// The event whose save is under way.
    private var sending: UUID?
    private var withdrawnWhileSending: Set<UUID> = []

    /// Seconds between two reads of iCloud, see `fastPoll`.
    public func cloudPollInterval(sessionRunning: Bool) -> Int {
        // A clock set back does not stretch the window.
        if let last = lastCloudRequest, (0..<Self.fastPollWindow).contains(clock.now().timeIntervalSince(last)) { return Self.fastPoll }
        return sessionRunning ? Self.sessionPoll : Self.idlePoll
    }

    /// Reads commands and pairing requests left in iCloud, answers them there.
    public func pollCloud(macName: String) async {
        guard cloud != nil, !isBackingOff(.inbox) else { return }
        // A push that comes while a poll runs (a docker stop can take 30 s)
        // is not lost: one more poll follows.
        guard !polling else {
            pollAgain = true
            return
        }
        polling = true
        defer { polling = false }
        repeat {
            pollAgain = false
            await pollOnce(macName: macName)
        } while pollAgain && !isBackingOff(.inbox)
    }

    private func pollOnce(macName: String) async {
        guard let cloud else { return }
        await retryUndelivered()
        let inbox: CloudInbox
        do {
            inbox = try await cloud.fetchInbox()
            succeeded(.inbox)
        } catch {
            failed(error, .inbox, "iCloud inbox")
            return
        }
        var done: [String] = []
        for item in inbox.pairings {
            let response = handlePairing(item.request, macName: macName, via: .cloud)
            await deliverToCloud(response, requestID: item.itemID)
            done.append(item.itemID)
        }
        for item in inbox.commands {
            let result = await handle(item.command, via: .cloud)
            // Still running from its direct copy: answered when it ends.
            if result.status == .duplicate, cloudAwaiting.contains(result.commandID) {
                done.append(item.itemID)
                continue
            }
            await deliverToCloud(result)
            done.append(item.itemID)
        }
        if !done.isEmpty {
            lastCloudRequest = clock.now()
            try? await cloud.discard(itemIDs: done)
        }
    }

    private func deliverToCloud(_ result: CommandResult) async {
        guard let cloud else { return }
        do {
            try await cloud.deliver(result: result)
        } catch {
            undeliveredResults.removeAll { $0.commandID == result.commandID }
            undeliveredResults.append(result)
            log.error("iCloud result \(result.commandID) not written, retried later: \(error.localizedDescription)")
        }
    }

    private func deliverToCloud(_ response: PairingResponse, requestID: String) async {
        guard let cloud else { return }
        do {
            try await cloud.deliver(pairing: response, requestID: requestID)
        } catch {
            undeliveredPairings.append((response, requestID))
            log.error("iCloud pairing answer not written, retried later: \(error.localizedDescription)")
        }
    }

    private func retryUndelivered() async {
        let results = undeliveredResults
        let pairings = undeliveredPairings
        undeliveredResults = []
        undeliveredPairings = []
        for result in results { await deliverToCloud(result) }
        for item in pairings { await deliverToCloud(item.response, requestID: item.requestID) }
    }

    /// The error of an iCloud operation that still fails, for the window
    /// (French text from CloudKit). nil once each has worked again.
    public var cloudError: String? {
        backoffs.values.max { $0.until < $1.until }?.error
    }

    /// The network came back, the Mac woke, or a push came: iCloud is tried
    /// again at once instead of after the back-off.
    public func retryNow() {
        // From the first delay again: one more failure waits 30 s, not the
        // ten minutes the outage grew it to.
        for (operation, backoff) in backoffs {
            backoffs[operation] = (clock.now(), Self.firstBackoff / 2, backoff.error)
        }
    }

    private func isBackingOff(_ operation: CloudOperation) -> Bool {
        guard let backoff = backoffs[operation] else { return false }
        return clock.now() < backoff.until
    }

    private func succeeded(_ operation: CloudOperation) {
        backoffs[operation] = nil
    }

    private func failed(_ error: Error, _ operation: CloudOperation, _ what: String) {
        let cap = operation == .inbox ? Self.maxInboxBackoff : 600
        let delay = min((backoffs[operation]?.delay ?? Self.firstBackoff / 2) * 2, cap)
        backoffs[operation] = (clock.now().addingTimeInterval(delay), delay, error.localizedDescription)
        log.error("\(what): \(error.localizedDescription) (next try in \(Int(delay)) s)")
    }

    /// `updatedAt` changes every time; it alone is no reason to publish.
    /// The same state but for when it was made. For iCloud
    /// (`ignoringCounters`), figures that move all the time are no change
    /// either: the bytes of the session, the battery's time estimate, the
    /// containers' processor and memory. They go with the next real change
    /// or the heartbeat, instead of a write every few seconds. One that
    /// appears or goes away is a change.
    public static func sameContent(_ a: MacState, _ b: MacState, ignoringCounters: Bool = false) -> Bool {
        var a = a, b = b
        a.updatedAt = .distantPast
        b.updatedAt = .distantPast
        if ignoringCounters {
            func strip(_ s: inout MacState) {
                if s.network?.sessionBytes != nil { s.network?.sessionBytes = 0 }
                if s.powerSnapshot?.minutesToEmpty != nil { s.powerSnapshot?.minutesToEmpty = 0 }
                for i in s.containers.indices {
                    if s.containers[i].cpuPercent != nil { s.containers[i].cpuPercent = 0 }
                    if s.containers[i].memoryBytes != nil { s.containers[i].memoryBytes = 0 }
                }
            }
            strip(&a)
            strip(&b)
        }
        return a == b
    }
}

public enum RemoteError: Error, LocalizedError, Sendable {
    case unknownContainer
    case helperUnavailable
    case notDuringSession
    case unknownAgent
    case agentStillRunning
    case lockUnavailable
    case requestGone
    case commandsOff
    case agentFolderUnreadable
    /// The terminal's folder, as shown: gone or closed; `backHome` when the
    /// terminal went back to the home folder (it had not moved meanwhile).
    case terminalFolderGone(String, backHome: Bool)

    public var errorDescription: String? {
        switch self {
        case .unknownContainer: "Ce conteneur ne tourne pas sur le Mac."
        case .helperUnavailable: "Composant système injoignable."
        case .notDuringSession: "Possible seulement pendant une session."
        case .unknownAgent: "Cet agent ne tourne plus sur le Mac."
        case .agentStillRunning: "L'agent ne s'est pas arrêté."
        case .lockUnavailable: "Verrouillage indisponible sur cette version de macOS."
        case .requestGone: "Cette demande de Claude n'attend plus de réponse : elle est passée dans le terminal ou a été retirée."
        case .commandsOff: "Commandes depuis l'iPhone désactivées sur le Mac : DarraOwl > Réglages > Terminal."
        case .agentFolderUnreadable: "Le dossier de cet agent n'a pas pu être lu : lance la commande dans le dossier personnel."
        case let .terminalFolderGone(folder, backHome):
            backHome
                ? "Le dossier \(folder) n'existe plus ou n'est pas accessible : retour au dossier personnel. La commande n'a pas été lancée."
                : "Le dossier \(folder) n'existe plus ou n'est pas accessible. La commande n'a pas été lancée."
        }
    }
}
