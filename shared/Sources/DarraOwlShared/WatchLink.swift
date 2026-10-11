import Foundation

/// What the iPhone and the Apple Watch say to each other over
/// WatchConnectivity. The watch never signs anything: it asks the iPhone,
/// which signs with its own keys and refuses what needs Face ID.
public enum WatchLink {
    /// Key of the single entry in every WatchConnectivity dictionary.
    public static let key = "darraowl"

    /// What the watch shows, pushed by the iPhone.
    public struct Snapshot: Codable, Equatable, Sendable {
        public var state: MacState?
        public var macName: String?
        /// "En ligne, par réseau local", "Vu pour la dernière fois à 18:42"…
        public var presence: String
        public var online: Bool
        public var at: Date

        public init(state: MacState?, macName: String?, presence: String, online: Bool, at: Date) {
            self.state = state
            self.macName = macName
            self.presence = presence
            self.online = online
            self.at = at
        }
    }

    public enum Request: Codable, Equatable, Sendable {
        case refresh
        case command(CommandKind)
    }

    public struct Reply: Codable, Equatable, Sendable {
        public var ok: Bool
        public var message: String?
        public var snapshot: Snapshot?

        public init(ok: Bool, message: String?, snapshot: Snapshot?) {
            self.ok = ok
            self.message = message
            self.snapshot = snapshot
        }
    }

    /// Commands the watch may ask for: everything that does not need Face ID.
    public static func allowed(_ kind: CommandKind) -> Bool {
        !kind.isSensitive
    }

    public static let needsPhone = "Depuis l'iPhone uniquement : cette commande demande Face ID."

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try LinkCoding.encoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try LinkCoding.decoder().decode(type, from: data)
    }
}
