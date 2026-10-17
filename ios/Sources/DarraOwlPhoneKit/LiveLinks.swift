import CloudKit
import CryptoKit
import DarraOwlShared
import Foundation
import Network

/// One framed TLS-PSK connection to the Mac.
@MainActor
final class FramedConnection {
    let connection: NWConnection
    let path: ConnectionPath
    private var framer = Framer()
    var onReady: (() -> Void)?
    var onMessage: ((ServerMessage) -> Void)?
    var onEnd: (() -> Void)?
    private var ended = false

    init(endpoint: NWEndpoint, path: ConnectionPath, parameters: NWParameters) {
        self.connection = NWConnection(to: endpoint, using: parameters)
        self.path = path
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.onReady?()
                    self.receive()
                case .failed, .cancelled:
                    self.end()
                case .waiting:
                    // No route right now: give up on this candidate.
                    self.connection.cancel()
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    func send(_ message: ClientMessage) throws {
        connection.send(content: try Framer.frame(message), completion: .contentProcessed { _ in })
    }

    func cancel() {
        connection.cancel()
    }

    /// Called once. The handlers go with it: they capture this connection,
    /// and keeping them would keep every finished attempt in memory.
    private func end() {
        guard !ended else { return }
        ended = true
        let handler = onEnd
        onReady = nil
        onMessage = nil
        onEnd = nil
        handler?()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty {
                    guard let frames = try? self.framer.push(data) else { self.cancel(); return }
                    for body in frames {
                        if let message = try? LinkCoding.decoder().decode(ServerMessage.self, from: body) {
                            self.onMessage?(message)
                        }
                    }
                }
                if complete || error != nil { self.cancel() } else { self.receive() }
            }
        }
    }
}

/// Encrypted direct link: Bonjour, known local addresses and Tailscale are
/// tried at once; the first that completes the TLS-PSK handshake and the
/// hello wins.
@MainActor
public final class NWDirectLink: DirectLink {
    public private(set) var path: ConnectionPath? {
        didSet { if path != oldValue { onPathChange?(path) } }
    }
    public var onState: ((MacState) -> Void)?
    public var onResult: ((CommandResult) -> Void)?
    public var onPathChange: ((ConnectionPath?) -> Void)?

    private var active: FramedConnection?
    private var attempts: [FramedConnection] = []
    private var browser: NWBrowser?
    /// Bonjour endpoints already tried during this connection attempt.
    private var bonjourTried: Set<String> = []
    private var target: (mac: PairedMac, deviceID: UUID, key: SymmetricKey)?

    public init() {}

    private func parameters() -> NWParameters? {
        guard let target else { return nil }
        return LinkTLS.parameters(keys: [(target.deviceID.uuidString, target.key)])
    }

    public func connect(to mac: PairedMac, identity: PhoneIdentity) {
        guard active == nil, let key = try? identity.linkKey(for: mac) else { return }
        cancelAttempts()
        target = (mac, identity.deviceID, key)

        for candidate in PathPlanner.candidates(endpoints: mac.endpoints) {
            attempt(.hostPort(host: .init(candidate.host), port: .init(rawValue: candidate.port)!), candidate.path)
        }

        guard let params = parameters() else { return }
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: LinkProtocol.bonjourType, domain: nil), using: params)
        // Every batch is looked at (the first one can be empty or hold another
        // Mac), each endpoint tried once; the browser stops after 4 s or when
        // a connection said hello.
        bonjourTried = []
        b.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self, self.active == nil else { return }
                for result in results {
                    guard case let .bonjour(txt) = result.metadata, txt["mac"] == mac.macID.uuidString,
                          self.bonjourTried.insert("\(result.endpoint)").inserted else { continue }
                    self.attempt(result.endpoint, .local)
                }
            }
        }
        b.start(queue: .main)
        browser = b
        Task { [weak b] in
            try? await Task.sleep(for: .seconds(4))
            b?.cancel()
        }
    }

    private func attempt(_ endpoint: NWEndpoint, _ path: ConnectionPath) {
            guard let target, let params = parameters() else { return }
            let mac = target.mac
            let hello = ClientMessage.hello(protocolVersion: LinkProtocol.version, deviceID: target.deviceID)
            let c = FramedConnection(endpoint: endpoint, path: path, parameters: params)
            c.onReady = { [weak c] in try? c?.send(hello) }
            c.onMessage = { [weak self, weak c] message in
                guard let self, let c else { return }
                self.handle(message, from: c, macID: mac.macID)
            }
            c.onEnd = { [weak self, weak c] in
                guard let self, let c else { return }
                self.attempts.removeAll { $0 === c }
                if self.active === c {
                    self.active = nil
                    self.path = nil
                }
            }
            attempts.append(c)
            c.start()
            // A candidate that has not said hello in 6 s is dropped.
            Task { [weak c] in
                try? await Task.sleep(for: .seconds(6))
                if let c, self.active !== c { c.cancel() }
            }
    }

    public func disconnect() {
        cancelAttempts()
        active?.cancel()
        active = nil
        path = nil
    }

    public func send(_ command: SignedCommand) throws {
        guard let active else { throw URLError(.notConnectedToInternet) }
        try active.send(.command(command))
    }

    public func requestState() {
        try? active?.send(.getState)
    }

    private func handle(_ message: ServerMessage, from c: FramedConnection, macID: UUID) {
        switch message {
        case let .hello(_, id):
            guard id == macID, active == nil else {
                c.cancel()
                return
            }
            active = c
            attempts.removeAll { $0 === c }
            cancelAttempts()
            path = c.path
        case let .state(state):
            if active === c { onState?(state) }
        case let .result(result):
            if active === c { onResult?(result) }
        case .paired:
            break
        case .error:
            c.cancel()
        }
    }

    private func cancelAttempts() {
        browser?.cancel()
        browser = nil
        attempts.forEach { $0.cancel() }
        attempts.removeAll()
    }
}

/// The pairing listener of the invite on screen, keyed by its one-time secret.
@MainActor
public final class NWPairingDirect: PairingDirect {
    public init() {}

    public func pair(_ request: PairingRequest, invite: PairingInvite) async throws -> PairingResponse {
        let key = LinkKeys.pairingKey(secret: invite.secret, macID: invite.macID)
        let identity = LinkKeys.pairingIdentity(secret: invite.secret)
        for candidate in PathPlanner.candidates(endpoints: invite.endpoints) {
            if let response = await tryPair(request, host: candidate.host, port: candidate.port, identity: identity, key: key) {
                return response
            }
        }
        throw URLError(.cannotConnectToHost)
    }

    private func tryPair(_ request: PairingRequest, host: String, port: UInt16, identity: String, key: SymmetricKey) async -> PairingResponse? {
        await withCheckedContinuation { (continuation: CheckedContinuation<PairingResponse?, Never>) in
            nonisolated(unsafe) var done = false
            let c = FramedConnection(endpoint: .hostPort(host: .init(host), port: .init(rawValue: port)!), path: .local,
                                     parameters: LinkTLS.parameters(keys: [(identity, key)]))
            @MainActor func finish(_ r: PairingResponse?) {
                guard !done else { return }
                done = true
                c.cancel()
                continuation.resume(returning: r)
            }
            c.onReady = { try? c.send(.pair(request)) }
            c.onMessage = { message in
                if case let .paired(response) = message { finish(response) }
            }
            c.onEnd = { finish(nil) }
            c.start()
            Task {
                try? await Task.sleep(for: .seconds(6))
                finish(nil)
            }
        }
    }
}

/// The user's private CloudKit database, phone side. Same zone and record
/// types as the Mac (see the Mac's CloudKitMailbox).
@MainActor
public final class CloudKitPhoneLink: CloudLink {
    static let containerID = "iCloud.com.darrao.darraowl"
    private let container = CKContainer(identifier: CloudKitPhoneLink.containerID)
    private var database: CKDatabase { container.privateCloudDatabase }
    private let zoneID = CKRecordZone.ID(zoneName: "DarraOwl")
    /// Claude's permission requests, apart so their notification has its own buttons.
    private let requestsZoneID = CKRecordZone.ID(zoneName: "DarraOwlRequests")

    public init() {}

    public func accountProblem() async -> String? {
        switch try? await container.accountStatus() {
        case .available?: return nil
        case .noAccount?: return "Aucun compte iCloud sur cet iPhone."
        case .restricted?: return "iCloud est restreint sur cet iPhone."
        default: return "iCloud est indisponible pour le moment."
        }
    }

    public func fetchState(macID: UUID) async throws -> (state: MacState, endpoints: Endpoints?)? {
        do {
            let record = try await database.record(for: CKRecord.ID(recordName: macID.uuidString, zoneID: zoneID))
            guard let data = record.encryptedValues["state"] as? Data else { return nil }
            let state = try LinkCoding.decoder().decode(MacState.self, from: data)
            let endpoints = (record.encryptedValues["endpoints"] as? Data).flatMap { try? LinkCoding.decoder().decode(Endpoints.self, from: $0) }
            return (state, endpoints)
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            return nil
        }
    }

    public func send(_ command: SignedCommand, macID: UUID) async throws {
        let envelope = try LinkCoding.decoder().decode(CommandEnvelope.self, from: command.payload)
        let record = CKRecord(recordType: "Command", recordID: CKRecord.ID(recordName: "cmd-\(envelope.id.uuidString)", zoneID: zoneID))
        record["macID"] = macID.uuidString
        record["expiresAt"] = envelope.expiresAt
        record.encryptedValues["payload"] = try LinkCoding.encoder().encode(command)
        _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
    }

    public func result(for commandID: UUID) async throws -> CommandResult? {
        let id = CKRecord.ID(recordName: "result-\(commandID.uuidString)", zoneID: zoneID)
        do {
            let record = try await database.record(for: id)
            guard let raw = record["status"] as? String, let status = CommandResult.Status(rawValue: raw) else { return nil }
            let output = (record.encryptedValues["output"] as? Data).flatMap { try? LinkCoding.decoder().decode(ShellOutput.self, from: $0) }
            let result = CommandResult(commandID: commandID, status: status,
                                       message: record.encryptedValues["message"] as? String,
                                       at: record["at"] as? Date ?? Date(), output: output)
            // Read once: tidy up.
            _ = try? await database.modifyRecords(saving: [], deleting: [id])
            return result
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    public func sendPairing(_ request: PairingRequest) async throws -> String {
        let name = "pair-\(UUID().uuidString)"
        let record = CKRecord(recordType: "PairingRequest", recordID: CKRecord.ID(recordName: name, zoneID: zoneID))
        record["macID"] = request.macID.uuidString
        record.encryptedValues["payload"] = try LinkCoding.encoder().encode(request)
        _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
        return name
    }

    public func unsubscribeFromEvents() async throws {
        _ = try await database.modifySubscriptions(saving: [], deleting: ["events", "requests"])
    }

    /// Query subscriptions on `Event` records: the DarraOwl zone's, with
    /// the session buttons, and the DarraOwlRequests zone's, with Accepter /
    /// Refuser. The alert text comes from the record's plain `title` and
    /// `body` fields.
    public func subscribeToEvents() async throws {
        _ = try await database.modifySubscriptions(saving: [Self.subscription("events", zone: zoneID, category: MacEvent.sessionCategory)], deleting: [])
        // The Mac makes the zone with its first request; the subscription needs it now.
        _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: requestsZoneID)], deleting: [])
        _ = try await database.modifySubscriptions(saving: [Self.subscription("requests", zone: requestsZoneID, category: MacEvent.agentRequestCategory)], deleting: [])
    }

    private static func subscription(_ id: String, zone: CKRecordZone.ID, category: String) -> CKQuerySubscription {
        let subscription = CKQuerySubscription(recordType: "Event", predicate: NSPredicate(value: true),
                                               subscriptionID: id, options: [.firesOnRecordCreation])
        subscription.zoneID = zone
        let info = CKSubscription.NotificationInfo()
        info.titleLocalizationKey = "%1$@"
        info.titleLocalizationArgs = ["title"]
        info.alertLocalizationKey = "%1$@"
        info.alertLocalizationArgs = ["body"]
        info.soundName = "default"
        info.category = category
        // Read when a button is tapped: another Mac's notification, or one
        // with nothing to stop, does nothing.
        info.desiredKeys = ["macID", "kind"]
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        return subscription
    }

    public func pairingResponse(requestID: String) async throws -> PairingResponse? {
        let id = CKRecord.ID(recordName: "pairing-\(requestID)", zoneID: zoneID)
        do {
            let record = try await database.record(for: id)
            guard let data = record.encryptedValues["payload"] as? Data else { return nil }
            _ = try? await database.modifyRecords(saving: [], deleting: [id])
            return try LinkCoding.decoder().decode(PairingResponse.self, from: data)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }
}
