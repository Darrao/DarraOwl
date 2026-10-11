import Foundation

/// The only things the phone can ask (safety rule 5). A closed list: no
/// shell command, no file path, every argument validated on the Mac.
public enum CommandKind: Codable, Equatable, Sendable {
    case startSession(minutes: Int)
    /// 30 or 60 minutes.
    case extendSession(minutes: Int)
    case stopSession
    /// Ends the session, then puts the Mac to sleep. Sensitive.
    case sleepNow
    case pauseDocker
    case resumeDocker
    /// A container id from the list the Mac published. Sensitive.
    case stopContainer(id: String)
    case updateLidSettings(LidSettings)
    case updateBatteryFloors(lowPower: Int, end: Int)
    case updateAlerts(AlertSettings)
    /// Agent mode: stay awake while this agent runs (a pid from the list the
    /// Mac published), at most the configured cap.
    case watchAgent(pid: Int32)
    /// Interrupts an agent from the published list (SIGINT, then SIGTERM).
    /// Sensitive.
    case stopAgent(pid: Int32)
    /// "Toujours actif" (presence): nil minutes for no end time.
    case startPresence(minutes: Int?)
    case stopPresence
    /// Turns the display off now.
    case displayOff
    /// Locks the Mac now.
    case lockScreen
    /// Mutes or unmutes the default output.
    case setMuted(Bool)
    /// Pauses or resumes the apps listed in the lid settings (session only).
    case pauseApps
    case resumeApps

    /// Needs a Face ID signature from the phone's Secure Enclave key.
    public var isSensitive: Bool {
        switch self {
        case .sleepNow, .stopContainer, .stopAgent: true
        default: false
        }
    }

    public var label: String {
        switch self {
        case let .startSession(m): "Démarrer une session de \(DurationText.short(TimeInterval(m * 60)))"
        case let .extendSession(m): "Prolonger de \(DurationText.short(TimeInterval(m * 60)))"
        case .stopSession: "Arrêter la session"
        case .sleepNow: "Mettre le Mac en veille"
        case .pauseDocker: "Mettre Docker en pause"
        case .resumeDocker: "Relancer Docker"
        case .stopContainer: "Arrêter un conteneur"
        case .updateLidSettings: "Changer les réglages capot fermé"
        case .updateBatteryFloors: "Changer les seuils de batterie"
        case .updateAlerts: "Changer les alertes"
        case .watchAgent: "Rester éveillé tant que l'agent tourne"
        case .stopAgent: "Arrêter l'agent"
        case let .startPresence(m): m.map { "Toujours actif pendant \(DurationText.short(TimeInterval($0 * 60)))" } ?? "Toujours actif, sans limite"
        case .stopPresence: "Arrêter « Toujours actif »"
        case .displayOff: "Éteindre l'écran"
        case .lockScreen: "Verrouiller le Mac"
        case let .setMuted(muted): muted ? "Couper le son" : "Remettre le son"
        case .pauseApps: "Mettre les apps en pause"
        case .resumeApps: "Relancer les apps"
        }
    }

    public static let extensionMinutes: Set<Int> = [30, 60]
    /// "Toujours actif" with an end time: at most a day.
    public static let maxPresenceMinutes = 24 * 60

    /// A Docker container id: 12 to 64 lower-case hex characters.
    public static func isWellFormedContainerID(_ id: String) -> Bool {
        (12...64).contains(id.count) && id.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    public enum ArgumentError: Error, Equatable, Sendable {
        case duration
        case extensionStep
        case containerID
        case settings
        case process
    }

    /// Checks the arguments against the policy. The Mac checks again against
    /// its own settings (cap, container list).
    public func validateArguments() throws(ArgumentError) {
        switch self {
        case let .startSession(m):
            guard m >= 1, TimeInterval(m * 60) <= Policy.absoluteMaxSessionDuration else { throw .duration }
        case let .extendSession(m):
            guard Self.extensionMinutes.contains(m) else { throw .extensionStep }
        case let .stopContainer(id):
            guard Self.isWellFormedContainerID(id) else { throw .containerID }
        case let .updateLidSettings(s):
            do { try s.validate() } catch { throw .settings }
        case let .updateBatteryFloors(lowPower, end):
            do { try PowerSettings(lowPowerFloor: lowPower, endFloor: end).validate() } catch { throw .settings }
        case let .updateAlerts(a):
            do { try PowerSettings(alerts: a).validate() } catch { throw .settings }
        case let .watchAgent(pid), let .stopAgent(pid):
            guard pid > 1 else { throw .process }
        case let .startPresence(m):
            if let m { guard (1...Self.maxPresenceMinutes).contains(m) else { throw .duration } }
        case .stopSession, .sleepNow, .pauseDocker, .resumeDocker, .stopPresence, .displayOff, .lockScreen,
             .setMuted, .pauseApps, .resumeApps:
            break
        }
    }
}

/// What the phone signs. Encoded once to `SignedCommand.payload`; the
/// signature covers those exact bytes.
public struct CommandEnvelope: Codable, Equatable, Sendable {
    public var id: UUID
    public var kind: CommandKind
    public var deviceID: UUID
    public var macID: UUID
    public var issuedAt: Date
    public var expiresAt: Date

    public init(id: UUID = UUID(), kind: CommandKind, deviceID: UUID, macID: UUID, issuedAt: Date, lifetime: TimeInterval = Policy.commandLifetime) {
        self.id = id
        self.kind = kind
        self.deviceID = deviceID
        self.macID = macID
        self.issuedAt = issuedAt
        self.expiresAt = issuedAt.addingTimeInterval(lifetime)
    }
}

public struct SignedCommand: Codable, Equatable, Sendable {
    public var deviceID: UUID
    /// `CommandEnvelope`, JSON.
    public var payload: Data
    /// Ed25519 over `payload`, by the device's signing key.
    public var signature: Data
    /// ECDSA P-256 over `payload` by the Secure Enclave key, which needs Face
    /// ID. Required for sensitive commands.
    public var biometricSignature: Data?

    public init(deviceID: UUID, payload: Data, signature: Data, biometricSignature: Data?) {
        self.deviceID = deviceID
        self.payload = payload
        self.signature = signature
        self.biometricSignature = biometricSignature
    }
}

public struct CommandResult: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case executed
        case failed
        case rejected
        case expired
        case duplicate
        case unauthorized
    }

    public var commandID: UUID
    public var status: Status
    /// French message for the phone.
    public var message: String?
    public var at: Date

    public init(commandID: UUID, status: Status, message: String?, at: Date) {
        self.commandID = commandID
        self.status = status
        self.message = message
        self.at = at
    }
}

public enum LinkCoding {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
