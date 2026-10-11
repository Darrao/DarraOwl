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

    public init(
        macID: UUID, macName: String, updatedAt: Date, power: Power, session: Session?,
        powerSnapshot: PowerSnapshot?, lowPowerActive: Bool, pausedApps: [String], network: Network?,
        agents: [Agent] = [], containers: [Container] = [], dockerPaused: Bool, settings: PowerSettings,
        protocolVersion: Int = LinkProtocol.version
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
}
