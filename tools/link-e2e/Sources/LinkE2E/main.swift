// End-to-end check of the direct link, on loopback, in one process:
// the Mac's real RemoteHub + LinkServer, the phone's real PhoneModel +
// NWDirectLink + NWPairingDirect. Fakes only where the real thing would
// touch the Keychain, iCloud or the helper.

import CryptoKit
import DarraOwlCore
import DarraOwlPhoneKit
import DarraOwlShared
import DarraOwlSystem
import Foundation

@MainActor final class MemoryPairingStore: PairingStore {
    let mac = MacIdentity(macID: UUID(), agreementKey: .init())
    var stored: [PairedDevice] = []
    func identity() throws -> MacIdentity { mac }
    func devices() throws -> [PairedDevice] { stored }
    func add(_ device: PairedDevice) throws { stored.removeAll { $0.id == device.id }; stored.append(device) }
    func remove(deviceID: UUID) throws { stored.removeAll { $0.id == deviceID } }
}

@MainActor final class RecordingTarget: CommandTarget {
    var calls: [String] = []
    var currentSettings: PowerSettings? = .default
    var containerIDs: [String] = []
    func startSession(seconds: TimeInterval) async throws { calls.append("start \(Int(seconds))") }
    func extendSession(seconds: TimeInterval) async throws { calls.append("extend \(Int(seconds))") }
    func stopSession() async throws { calls.append("stop") }
    func sleepNow() async throws { calls.append("sleep") }
    func pauseDocker() async throws {}
    func resumeDocker() async throws {}
    func stopContainer(id: String) async throws {}
    func updateSettings(_ settings: PowerSettings) async throws { calls.append("settings") }
}

final class MemoryLedger: ValueStoring, @unchecked Sendable {
    var value: CommandLedger?
    func load() throws(StoreError) -> CommandLedger? { value }
    func save(_ v: CommandLedger) throws(StoreError) { value = v }
    func quarantine() throws(StoreError) -> String? { nil }
    func remove() throws(StoreError) { value = nil }
}

struct Quiet: EngineLogging {
    func info(_ m: String) { print("   mac: \(m)") }
    func error(_ m: String) { print("   mac error: \(m)") }
}

@MainActor final class MemoryPhoneStore: PhoneStore {
    let id = PhoneIdentity(deviceID: UUID(), deviceName: "iPhone E2E", agreementKey: .init(), signingKey: .init(), biometric: SoftwareBiometricSigner())
    var mac: PairedMac?
    func identity() throws -> PhoneIdentity { id }
    func pairedMac() -> PairedMac? { mac }
    func save(_ mac: PairedMac) throws { self.mac = mac }
    func forgetMac() throws { mac = nil }
}

@MainActor final class NoCloud: CloudLink {
    func accountProblem() async -> String? { "pas d'iCloud dans ce test" }
    func fetchState(macID: UUID) async throws -> (state: MacState, endpoints: Endpoints?)? { nil }
    func send(_ command: SignedCommand, macID: UUID) async throws { throw URLError(.notConnectedToInternet) }
    func result(for commandID: UUID) async throws -> CommandResult? { nil }
    func sendPairing(_ request: PairingRequest) async throws -> String { throw URLError(.notConnectedToInternet) }
    func pairingResponse(requestID: String) async throws -> PairingResponse? { nil }
    func subscribeToEvents() async throws {}
}

var failures = 0
@MainActor func check(_ ok: Bool, _ what: String) {
    print("\(ok ? "ok  " : "FAIL") \(what)")
    if !ok { failures += 1 }
}

@MainActor func run() async {
    // Mac side
    let store = MemoryPairingStore()
    let target = RecordingTarget()
    let hub = RemoteHub(store: store, target: target, cloud: nil, ledgerStore: MemoryLedger(), clock: SystemClock(), log: Quiet())
    let state = MacState(macID: store.mac.macID, macName: "Mac E2E", updatedAt: Date(), power: .awake, session: nil,
                         powerSnapshot: PowerSnapshot(battery: .percent(77), onExternalPower: true, thermal: .nominal, lidClosed: false),
                         lowPowerActive: false, pausedApps: [], network: .init(kind: .wifi), dockerPaused: false, settings: .default)
    let server = LinkServer(macID: store.mac.macID, macName: "Mac E2E", handlers: .init(
        message: { id, message in
            switch message {
            case .getState: return .state(state)
            case let .command(c): return .result(await hub.handle(c, via: .direct, peer: id))
            default: return nil
            }
        },
        pairing: { hub.handlePairing($0, macName: "Mac E2E") },
        isPaired: { id in store.stored.contains { $0.id == id } }
    ))

    // Invite on loopback, pairing listener up.
    var invite = try! hub.makeInvite(macName: "Mac E2E", endpoints: nil)
    server.startPairing(identity: LinkKeys.pairingIdentity(secret: invite.secret), key: LinkKeys.pairingKey(secret: invite.secret, macID: invite.macID))
    for _ in 0..<50 where server.pairingPort == nil { try? await Task.sleep(for: .milliseconds(50)) }
    invite.endpoints = Endpoints(port: server.pairingPort!, local: ["127.0.0.1"], tailscale: nil)

    // Phone side
    let phoneStore = MemoryPhoneStore()
    let phone = PhoneModel(.init(store: phoneStore, direct: NWDirectLink(), cloud: NoCloud(), pairing: NWPairingDirect()))

    await phone.pair(url: try! invite.url())
    check(phone.pairingError == nil && phone.mac != nil, "appairage direct (\(phone.pairingError ?? "accepté"))")
    check(store.stored.map(\.id) == [phoneStore.id.deviceID], "le Mac a enregistré l'iPhone")
    server.stopPairing()

    // Main listener with the new device's key, on loopback.
    let keys = store.stored.compactMap { d in hub.linkKey(deviceID: d.id).map { (deviceID: d.id, key: $0) } }
    server.start(keys: keys, anyPort: true)
    for _ in 0..<50 where server.port == nil { try? await Task.sleep(for: .milliseconds(50)) }
    var mac = phoneStore.mac!
    mac.endpoints = Endpoints(port: server.port!, local: ["127.0.0.1"], tailscale: nil)
    try! phoneStore.save(mac)
    await phone.start()
    for _ in 0..<60 where phone.directPath == nil || phone.state == nil { try? await Task.sleep(for: .milliseconds(100)) }
    check(phone.directPath == .local, "connexion directe chiffrée")
    check(phone.state?.macName == "Mac E2E", "état reçu du Mac")

    await phone.send(.extendSession(minutes: 30))
    check(target.calls == ["extend 1800"], "commande signée exécutée une fois (\(target.calls))")
    check(phone.outcome == .done("Prolonger de 30 min : fait."), "résultat reçu par l'iPhone")

    await phone.send(.sleepNow)
    check(target.calls.last == "sleep", "commande sensible avec signature Face ID (clé logicielle)")

    // Unpair on the Mac: the open connection must drop and stay out.
    try? hub.unpair(deviceID: phoneStore.id.deviceID)
    server.disconnect(deviceID: phoneStore.id.deviceID)
    server.start(keys: [], anyPort: true)
    for _ in 0..<30 where phone.directPath != nil { try? await Task.sleep(for: .milliseconds(100)) }
    check(phone.directPath == nil, "désappairage : connexion coupée")

    print(failures == 0 ? "\nTout est bon." : "\n\(failures) échec(s).")
    exit(failures == 0 ? 0 : 1)
}

Task { @MainActor in await run() }
dispatchMain()
