import Foundation

/// Who started a session.
public enum SessionOrigin: String, Codable, Sendable {
    case menuBar
    case phone
    case cli
    case agent
}

/// One awake session. `endsAt` always exists: there is no open-ended session.
public struct Session: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let startedAt: Date
    public var endsAt: Date
    public let origin: SessionOrigin

    public init(id: UUID = UUID(), startedAt: Date, endsAt: Date, origin: SessionOrigin) {
        self.id = id
        self.startedAt = startedAt
        self.endsAt = endsAt
        self.origin = origin
    }

    public func remaining(at now: Date) -> TimeInterval {
        max(0, endsAt.timeIntervalSince(now))
    }

    public func isExpired(at now: Date) -> Bool {
        now >= endsAt
    }
}

/// Why a session ended.
public enum SessionEndReason: String, Codable, Sendable {
    case expired
    case userStopped
    case batteryLow
    case batteryUnreadable
    case thermalCritical
    case helperTerminated
    case appQuit
    case uninstall
    case journalUnreadable

    /// French text for the menu and the phone.
    public var label: String {
        switch self {
        case .expired: "Heure de fin atteinte"
        case .userStopped: "Arrêtée"
        case .batteryLow: "Batterie sous le seuil"
        case .batteryUnreadable: "Batterie illisible"
        case .thermalCritical: "Température critique"
        case .helperTerminated: "Composant système arrêté"
        case .appQuit: "DarraOwl a été quitté"
        case .uninstall: "Désinstallation"
        case .journalUnreadable: "Journal illisible"
        }
    }
}
