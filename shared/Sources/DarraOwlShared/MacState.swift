import Foundation

/// What the Mac publishes for the phone: on every change and every 60 s,
/// over the direct link and to iCloud. Metadata only: never file contents,
/// prompts or agent output (safety rule 8).
public struct MacState: Codable, Equatable, Sendable {
    public enum Power: String, Codable, Sendable {
        case awake
        case goingToSleep
        case asleep
    }

    public enum NetworkKind: String, Codable, Sendable {
        case wifi
        /// Wi-Fi to an iPhone hotspot (172.20.10.0/28) or a network macOS marks expensive.
        case hotspot
        case ethernet
        case other
        case none
    }

    public struct Network: Codable, Equatable, Sendable {
        public var kind: NetworkKind
        /// Network name, when the Mac may read it (Location Services).
        public var name: String?
        /// Bytes sent and received since the session started.
        public var sessionBytes: Int64?

        public init(kind: NetworkKind, name: String? = nil, sessionBytes: Int64? = nil) {
            self.kind = kind
            self.name = name
            self.sessionBytes = sessionBytes
        }
    }

    public struct Container: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var cpuPercent: Double?
        public var memoryBytes: Int64?

        public init(id: String, name: String, cpuPercent: Double? = nil, memoryBytes: Int64? = nil) {
            self.id = id
            self.name = name
            self.cpuPercent = cpuPercent
            self.memoryBytes = memoryBytes
        }
    }

    public struct Agent: Codable, Equatable, Sendable {
        /// claude, codex or gemini.
        public var tool: String
        /// Project folder name, or nil when masked in settings.
        public var project: String?
        public var since: Date
        public var waitingForApproval: Bool
        /// For "stay awake while it runs" from the phone; checked against the
        /// Mac's own list before use.
        public var pid: Int32?

        public init(tool: String, project: String?, since: Date, waitingForApproval: Bool, pid: Int32? = nil) {
            self.tool = tool
            self.project = project
            self.since = since
            self.waitingForApproval = waitingForApproval
            self.pid = pid
        }
    }

    /// "Toujours actif" (presence), held by the app.
    public struct Presence: Codable, Equatable, Sendable {
        public var active: Bool
        /// nil: no end time.
        public var until: Date?

        public init(active: Bool, until: Date?) {
            self.active = active
            self.until = until
        }
    }

    public var macID: UUID
    public var macName: String
    public var updatedAt: Date
    public var power: Power
    public var session: Session?
    public var powerSnapshot: PowerSnapshot?
    public var lowPowerActive: Bool
    /// Names of the apps paused at lid close.
    public var pausedApps: [String]
    public var network: Network?
    public var agents: [Agent]
    public var containers: [Container]
    /// Docker Desktop is paused by DarraOwl.
    public var dockerPaused: Bool
    public var settings: PowerSettings
    public var protocolVersion: Int
    /// Optional: a Mac on an older version does not send them.
    public var presence: Presence?
    /// The default output is muted.
    public var muted: Bool?
    /// Docker Desktop is open (nil: older Mac).
    public var dockerRunning: Bool?
    /// The devices paired with this Mac: a phone missing from a state
    /// published after its pairing was unpaired on the Mac (nil: older Mac).
    public var pairedDevices: [UUID]?

    public init(
        macID: UUID, macName: String, updatedAt: Date, power: Power, session: Session?,
        powerSnapshot: PowerSnapshot?, lowPowerActive: Bool, pausedApps: [String], network: Network?,
        agents: [Agent] = [], containers: [Container] = [], dockerPaused: Bool, settings: PowerSettings,
        protocolVersion: Int = LinkProtocol.version, presence: Presence? = nil, muted: Bool? = nil, dockerRunning: Bool? = nil,
        pairedDevices: [UUID]? = nil
    ) {
        self.macID = macID
        self.macName = macName
        self.updatedAt = updatedAt
        self.power = power
        self.session = session
        self.powerSnapshot = powerSnapshot
        self.lowPowerActive = lowPowerActive
        self.pausedApps = pausedApps
        self.network = network
        self.agents = agents
        self.containers = containers
        self.dockerPaused = dockerPaused
        self.settings = settings
        self.protocolVersion = protocolVersion
        self.presence = presence
        self.muted = muted
        self.dockerRunning = dockerRunning
        self.pairedDevices = pairedDevices
    }
}

/// Where the phone may reach the Mac directly. Published to iCloud, so the
/// phone knows what to try when Bonjour finds nothing.
public struct Endpoints: Codable, Equatable, Sendable {
    public var port: UInt16
    /// LAN and hotspot IPv4 addresses.
    public var local: [String]
    /// Tailscale address (100.64.0.0/10), when Tailscale runs on the Mac.
    public var tailscale: String?

    public init(port: UInt16, local: [String], tailscale: String?) {
        self.port = port
        self.local = local
        self.tailscale = tailscale
    }

    public static let maxLocal = 8

    /// A port, a few private or link-local IPv4 addresses, a Tailscale
    /// address: what a Mac publishes. Anything else is refused.
    public var isPlausible: Bool {
        guard port != 0, local.count <= Self.maxLocal else { return false }
        guard local.allSatisfy({ Self.ipv4($0).map(Self.isPrivate) ?? false }) else { return false }
        if let tailscale, !(Self.ipv4(tailscale).map(Self.isTailscale) ?? false) { return false }
        return true
    }

    static func ipv4(_ s: String) -> [UInt8]? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let bytes = parts.compactMap { p -> UInt8? in
            // No leading zero: "010" is octal to some parsers, decimal to others.
            guard !p.isEmpty, p.count <= 3, p.allSatisfy(\.isASCII), p.allSatisfy(\.isNumber), p.count == 1 || p.first != "0" else { return nil }
            return UInt8(p)
        }
        return bytes.count == 4 ? bytes : nil
    }

    /// 10/8, 172.16/12, 192.168/16, 169.254/16, and 127/8 (the phone
    /// itself: harmless, and what the end-to-end check uses).
    static func isPrivate(_ b: [UInt8]) -> Bool {
        b[0] == 10 || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168)
            || (b[0] == 169 && b[1] == 254) || b[0] == 127
    }

    /// 100.64/10.
    static func isTailscale(_ b: [UInt8]) -> Bool {
        b[0] == 100 && (64...127).contains(b[1])
    }
}
