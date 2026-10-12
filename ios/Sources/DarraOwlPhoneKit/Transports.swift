import DarraOwlShared
import Foundation

/// How the phone reaches the Mac right now.
public enum ConnectionPath: String, Sendable {
    case local
    case tailscale
    case icloud

    public var label: String {
        switch self {
        case .local: "réseau local"
        case .tailscale: "Tailscale"
        case .icloud: "iCloud"
        }
    }
}

/// Encrypted direct connection to the Mac (local network or Tailscale).
@MainActor
public protocol DirectLink: AnyObject {
    /// Non-nil while a connection is up and said hello.
    var path: ConnectionPath? { get }
    var onState: ((MacState) -> Void)? { get set }
    var onResult: ((CommandResult) -> Void)? { get set }
    var onPathChange: ((ConnectionPath?) -> Void)? { get set }
    /// Tries Bonjour, the known local addresses, then Tailscale.
    func connect(to mac: PairedMac, identity: PhoneIdentity)
    func disconnect()
    func send(_ command: SignedCommand) throws
    func requestState()
}

/// The iCloud mailbox, phone side.
@MainActor
public protocol CloudLink: AnyObject {
    func accountProblem() async -> String?
    func fetchState(macID: UUID) async throws -> (state: MacState, endpoints: Endpoints?)?
    func send(_ command: SignedCommand, macID: UUID) async throws
    func result(for commandID: UUID) async throws -> CommandResult?
    /// Returns the request's record name.
    func sendPairing(_ request: PairingRequest) async throws -> String
    func pairingResponse(requestID: String) async throws -> PairingResponse?
    /// Subscribes to the Mac's events: each one becomes a notification.
    func subscribeToEvents() async throws
    /// After unpairing: no more notifications.
    func unsubscribeFromEvents() async throws
}

/// The pairing listener of the invite on screen.
@MainActor
public protocol PairingDirect: AnyObject {
    func pair(_ request: PairingRequest, invite: PairingInvite) async throws -> PairingResponse
}

/// Keychain on the phone: identity and the paired Mac.
@MainActor
public protocol PhoneStore: AnyObject {
    func identity() throws -> PhoneIdentity
    func pairedMac() -> PairedMac?
    func save(_ mac: PairedMac) throws
    func forgetMac() throws
}

public protocol Sleeper: Sendable {
    func sleep(seconds: Double) async
}

public struct TaskSleeper: Sleeper {
    public init() {}
    public func sleep(seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}

/// Candidate addresses in the order they are tried.
public enum PathPlanner {
    public struct Candidate: Equatable, Sendable {
        public var path: ConnectionPath
        public var host: String
        public var port: UInt16
    }

    public static func candidates(endpoints: Endpoints?) -> [Candidate] {
        guard let e = endpoints else { return [] }
        var out = e.local.map { Candidate(path: .local, host: $0, port: e.port) }
        if let t = e.tailscale { out.append(Candidate(path: .tailscale, host: t, port: e.port)) }
        return out
    }
}
