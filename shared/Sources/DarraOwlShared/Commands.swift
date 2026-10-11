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

    /// Needs a Face ID signature from the phone's Secure Enclave key.
    public var isSensitive: Bool {
        switch self {
        case .sleepNow, .stopContainer: true
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
        }
    }

    public static let extensionMinutes: Set<Int> = [30, 60]

    /// A Docker container id: 12 to 64 lower-case hex characters.
    public static func isWellFormedContainerID(_ id: String) -> Bool {
        (12...64).contains(id.count) && id.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    public enum ArgumentError: Error, Equatable, Sendable {
        case duration
        case extensionStep
        case containerID
        case settings
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
        case .stopSession, .sleepNow, .pauseDocker, .resumeDocker:
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
