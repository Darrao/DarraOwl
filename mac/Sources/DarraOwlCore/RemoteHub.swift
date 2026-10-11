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
    /// After an iCloud failure, wait this long, doubling up to 10 min.
    public static let firstBackoff: TimeInterval = 30
    private var backoff: (until: Date, delay: TimeInterval)?
    private var publishing = false
    private var polling = false
    /// Called after a device is removed, so the direct link can drop it.
    public var onDeviceRemoved: ((UUID) -> Void)?
    /// Called after a pairing succeeded, whichever path it came by (direct
    /// or iCloud), so the window and the direct server catch up.
    public var onPaired: ((PairedDevice, RemoteHub.Channel) -> Void)?
    /// Called with every result, so the direct link can send it.
    public var onResult: ((CommandResult) -> Void)?

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
        log.info("paired device \(device.id) (\(name)) via \(channel.rawValue)")
        onPaired?(device, channel)
        return PairingResponse(accepted: true, macID: macID, macName: macName, message: nil)
    }

    public func unpair(deviceID: UUID) throws {
        try store.remove(deviceID: deviceID)
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
            log.error("command \(result.commandID) \(result.status.rawValue) via \(channel.rawValue): \(result.message ?? "")")
            return finish(result)
        case let .accept(envelope):
            // Marked seen before it runs: a crash mid-run never runs it twice.
            ledger.markSeen(envelope.id, expiresAt: envelope.expiresAt)
            persistLedger()
            log.info("command \(envelope.id) \(envelope.kind.label) via \(channel.rawValue)")
            do {
                try await run(envelope.kind)
                return finish(CommandResult(commandID: envelope.id, status: .executed, message: nil, at: clock.now()))
            } catch {
                return finish(CommandResult(commandID: envelope.id, status: .failed, message: error.localizedDescription, at: clock.now()))
            }
        }
    }

    private func run(_ kind: CommandKind) async throws {
        switch kind {
        case let .startSession(m): try await target.startSession(seconds: TimeInterval(m * 60))
        case let .extendSession(m): try await target.extendSession(seconds: TimeInterval(m * 60))
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
        case let .updateBatteryFloors(lowPower, end):
            guard var s = target.currentSettings else { throw RemoteError.helperUnavailable }
            s.lowPowerFloor = lowPower
            s.endFloor = end
            try await target.updateSettings(s)
        }
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
    @discardableResult
    public func publishIfDue(_ state: MacState, endpoints: Endpoints?, force: Bool = false) async -> Bool {
        guard let cloud, !publishing else { return false }
        let now = clock.now()
        if let backoff, now < backoff.until { return false }
        if !force, let last = lastPublished {
            let age = now.timeIntervalSince(last.at)
            let changed = !Self.sameContent(last.state, state)
            guard (changed && age >= Self.minPublishInterval) || age >= Self.heartbeat else { return false }
        }
        publishing = true
        defer { publishing = false }
        do {
            try await cloud.publish(state: state, endpoints: endpoints)
            if lastPublished == nil || cloudError != nil { log.info("iCloud: state published") }
            lastPublished = (state, now)
            backoff = nil
            cloudError = nil
            return true
        } catch {
            failed(error, "iCloud publish failed")
            return false
        }
    }

    /// Sends events now; on failure they wait in memory for the next try
    /// (at most 20, the oldest dropped).
    public func post(_ events: [MacEvent]) async {
        pendingEvents += events
        if pendingEvents.count > 20 { pendingEvents.removeFirst(pendingEvents.count - 20) }
        guard let cloud, !pendingEvents.isEmpty else { return }
        if let backoff, clock.now() < backoff.until { return }
        var sent = 0
        for event in pendingEvents {
            do {
                try await cloud.post(event)
                sent += 1
                log.info("event \(event.kind.rawValue) sent")
            } catch {
                failed(error, "iCloud event")
                break
            }
        }
        pendingEvents.removeFirst(sent)
    }

    public private(set) var pendingEvents: [MacEvent] = []

    /// Reads commands and pairing requests left in iCloud, answers them there.
    public func pollCloud(macName: String) async {
        guard let cloud, !polling else { return }
        if let backoff, clock.now() < backoff.until { return }
        polling = true
        defer { polling = false }
        let inbox: CloudInbox
        do {
            inbox = try await cloud.fetchInbox()
            backoff = nil
        } catch {
            failed(error, "iCloud inbox")
            return
        }
        var done: [String] = []
        for item in inbox.pairings {
            let response = handlePairing(item.request, macName: macName, via: .cloud)
            try? await cloud.deliver(pairing: response, requestID: item.itemID)
            done.append(item.itemID)
        }
        for item in inbox.commands {
            let result = await handle(item.command, via: .cloud)
            try? await cloud.deliver(result: result)
            done.append(item.itemID)
        }
        if !done.isEmpty { try? await cloud.discard(itemIDs: done) }
    }

    /// Last iCloud error, for the window (French text from CloudKit).
    public private(set) var cloudError: String?

    private func failed(_ error: Error, _ what: String) {
        let delay = min((backoff?.delay ?? Self.firstBackoff / 2) * 2, 600)
        backoff = (clock.now().addingTimeInterval(delay), delay)
        cloudError = error.localizedDescription
        log.error("\(what): \(error.localizedDescription) (next try in \(Int(delay)) s)")
    }

    /// `updatedAt` changes every time; it alone is no reason to publish.
    public static func sameContent(_ a: MacState, _ b: MacState) -> Bool {
        var a = a, b = b
        a.updatedAt = .distantPast
        b.updatedAt = .distantPast
        return a == b
    }
}

public enum RemoteError: Error, LocalizedError, Sendable {
    case unknownContainer
    case helperUnavailable
    case notDuringSession

    public var errorDescription: String? {
        switch self {
        case .unknownContainer: "Ce conteneur ne tourne pas sur le Mac."
        case .helperUnavailable: "Composant système injoignable."
        case .notDuringSession: "Possible seulement pendant une session."
        }
    }
}
