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
        if let directPath { return .online(directPath) }
        guard let state else { return .unknown }
        if state.power != .awake { return .asleep(since: state.updatedAt) }
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
    public static let reconnectInterval: TimeInterval = 15
    public static let cloudFetchInterval: TimeInterval = 10

    public private(set) var mac: PairedMac?
    public private(set) var state: MacState?
    public private(set) var directPath: ConnectionPath?
    public private(set) var cloudProblem: String?
    public private(set) var outcome: Outcome?
    public private(set) var pairingError: String?
    public private(set) var isPairing = false
    public private(set) var now = Date()

    /// Every new Mac state, for the Live Activity and the widgets.
    @ObservationIgnored public var onStateChange: ((MacState) -> Void)?
    @ObservationIgnored private let deps: Dependencies
    @ObservationIgnored private var identity: PhoneIdentity?
    @ObservationIgnored private var waiters: [UUID: CheckedContinuation<CommandResult?, Never>] = [:]
    @ObservationIgnored private var lastConnectAttempt: Date?
    @ObservationIgnored private var lastCloudFetch: Date?
    @ObservationIgnored private var busy = false

    public init(_ deps: Dependencies) {
        self.deps = deps
        deps.direct.onState = { [weak self] state in self?.receive(state) }
        deps.direct.onResult = { [weak self] result in self?.receive(result) }
        deps.direct.onPathChange = { [weak self] path in self?.directPath = path }
    }

    public var presence: MacPresence {
        MacPresence.from(state: state, directPath: directPath, now: now)
    }

    public var isBusy: Bool { busy }

    // MARK: Lifecycle

    public func start() async {
        mac = deps.store.pairedMac()
        cloudProblem = await deps.cloud.accountProblem()
        if mac != nil, cloudProblem == nil { try? await deps.cloud.subscribeToEvents() }
        await tick()
    }

    /// A button on a notification: +1 h or Arrêter.
    public func handleNotificationAction(_ id: String) async {
        if mac == nil { mac = deps.store.pairedMac() }
        switch id {
        case MacEvent.extendAction: await send(.extendSession(minutes: 60))
        case MacEvent.stopAction: await send(.stopSession)
        default: break
        }
    }

    /// Call every few seconds while the app is in the foreground.
    public func tick() async {
        now = deps.now()
        guard let mac else { return }
        if directPath == nil, lastConnectAttempt.map({ now.timeIntervalSince($0) >= Self.reconnectInterval }) ?? true,
           let identity = try? loadIdentity() {
            lastConnectAttempt = now
            deps.direct.connect(to: mac, identity: identity)
        }
        if directPath == nil, lastCloudFetch.map({ now.timeIntervalSince($0) >= Self.cloudFetchInterval }) ?? true {
            await fetchCloudState()
        }
    }

    // MARK: Pairing

    /// Pairs from the QR code link: directly when the Mac is reachable,
    /// through iCloud otherwise.
    public func pair(url: URL) async {
        pairingError = nil
        let invite: PairingInvite
        do {
            invite = try PairingInvite(url: url)
        } catch {
            pairingError = "Ce code n'est pas un code DarraOwl."
            return
        }
        guard deps.now() <= invite.expiresAt else {
            pairingError = "Ce code a expiré. Affiche-en un nouveau sur le Mac."
            return
        }
        isPairing = true
        defer { isPairing = false }
        let identity: PhoneIdentity
        do {
            identity = try loadIdentity()
        } catch {
            pairingError = "Trousseau : \(error.localizedDescription)"
            return
        }
        let request = identity.pairingRequest(for: invite, at: deps.now())

        var response: PairingResponse?
        if invite.endpoints != nil {
            response = try? await deps.pairing.pair(request, invite: invite)
        }
        if response == nil {
            response = await pairThroughCloud(request, until: invite.expiresAt)
        }
        guard let response else {
            pairingError = "Le Mac ne répond pas. Vérifie qu'il est allumé et connecté à iCloud."
            return
        }
        guard response.accepted else {
            pairingError = response.message ?? "Le Mac a refusé l'appairage."
            return
        }
        let paired = PairedMac(macID: invite.macID, macName: response.macName.isEmpty ? invite.macName : response.macName,
                               agreementKey: invite.macAgreementKey, endpoints: invite.endpoints, pairedAt: deps.now())
        do {
            try deps.store.save(paired)
        } catch {
            pairingError = "Trousseau : \(error.localizedDescription)"
            return
        }
        mac = paired
        lastConnectAttempt = nil
        try? await deps.cloud.subscribeToEvents()
        await tick()
    }

    private func pairThroughCloud(_ request: PairingRequest, until deadline: Date) async -> PairingResponse? {
        guard let id = try? await deps.cloud.sendPairing(request) else { return nil }
        while deps.now() <= deadline.addingTimeInterval(5) {
            await deps.sleeper.sleep(seconds: Self.cloudPollInterval)
            if let response = try? await deps.cloud.pairingResponse(requestID: id) { return response }
        }
        return nil
    }

    /// Forgets the Mac on this phone. Unpairing on the Mac cuts it off there.
    public func unpair() {
        deps.direct.disconnect()
        try? deps.store.forgetMac()
        mac = nil
        state = nil
        directPath = nil
    }

    // MARK: Commands

    /// Signs (Face ID for sensitive commands), sends by the best path,
    /// waits for the Mac's answer.
    public func send(_ kind: CommandKind) async {
        guard let mac, !busy else { return }
        busy = true
        defer { busy = false }
        outcome = .sending(kind.label)
        let signed: SignedCommand
        let envelope: CommandEnvelope
        do {
            (envelope, signed) = try await loadIdentity().sign(kind, for: mac, at: deps.now())
        } catch {
            outcome = .failed(kind.isSensitive ? "Face ID refusé : commande non envoyée." : "Signature impossible : \(error.localizedDescription)")
            return
        }

        var result: CommandResult?
        if directPath != nil {
            do {
                try deps.direct.send(signed)
                result = await waitDirect(envelope.id)
            } catch {
                result = nil
            }
        }
        // No direct answer: the same signed command through iCloud. The Mac
        // runs a command once, so a second copy only gets "duplicate".
        if result == nil {
            do {
                try await deps.cloud.send(signed, macID: mac.macID)
                result = await waitCloud(envelope.id, until: envelope.expiresAt)
            } catch {
                outcome = .failed("Envoi impossible : \(error.localizedDescription)")
                return
            }
        }
        guard let result else {
            outcome = .failed("Pas de réponse du Mac avant l'expiration de la commande.")
            return
        }
        outcome = Self.outcome(for: result, kind: kind)
        if result.status == .executed {
            if directPath != nil { deps.direct.requestState() } else { await fetchCloudState() }
        }
    }

    /// Signs and sends without waiting for the Mac's answer: for Siri and
    /// the Live Activity buttons, which have a few seconds only. Returns
    /// false when it could not be sent at all.
    @discardableResult
    public func fire(_ kind: CommandKind) async -> Bool {
        if mac == nil { mac = deps.store.pairedMac() }
        guard let mac, let (_, signed) = try? await loadIdentity().sign(kind, for: mac, at: deps.now()) else { return false }
        if directPath != nil, (try? deps.direct.send(signed)) != nil { return true }
        do {
            try await deps.cloud.send(signed, macID: mac.macID)
            return true
        } catch {
            return false
        }
    }

    static func outcome(for result: CommandResult, kind: CommandKind) -> Outcome {
        switch result.status {
        case .executed, .duplicate: .done("\(kind.label) : fait.")
        case .failed: .failed(result.message ?? "Échec sur le Mac.")
        case .rejected, .unauthorized, .expired: .failed(result.message ?? "Refusé par le Mac.")
        }
    }

    // MARK: Private

    private func loadIdentity() throws -> PhoneIdentity {
        if let identity { return identity }
        let loaded = try deps.store.identity()
        identity = loaded
        return loaded
    }

    private func receive(_ state: MacState) {
        guard state.macID == mac?.macID else { return }
        self.state = state
        now = deps.now()
        onStateChange?(state)
    }

    private func receive(_ result: CommandResult) {
        waiters.removeValue(forKey: result.commandID)?.resume(returning: result)
    }

    private func waitDirect(_ id: UUID) async -> CommandResult? {
        let sleeper = deps.sleeper
        return await withCheckedContinuation { continuation in
            waiters[id] = continuation
            Task {
                await sleeper.sleep(seconds: Self.directResultTimeout)
                self.waiters.removeValue(forKey: id)?.resume(returning: nil)
            }
        }
    }

    private func waitCloud(_ id: UUID, until expiry: Date) async -> CommandResult? {
        while deps.now() <= expiry.addingTimeInterval(10) {
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
                receive(state)
                if let endpoints, endpoints != mac.endpoints {
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
