import Foundation

/// Something worth a notification on the phone. Sent through iCloud as an
/// `Event` record; title and body are plain text so the notification can
/// show them without the app running. No file content, prompt or agent
/// output; project names only when not masked.
public struct MacEvent: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case endingSoon
        case batteryShort
        case hot
        case ended
        case lidOpened
        case chargerUnplugged
        case networkRestored
        case dataThreshold
        case agentDone
        case agentWaiting
        /// The Mac locked itself: Teams shows its user Away.
        case macLocked
    }

    public var id: UUID
    public var kind: Kind
    public var title: String
    public var body: String
    public var at: Date

    public init(id: UUID = UUID(), kind: Kind, title: String, body: String, at: Date) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.at = at
    }

    /// Notification category: session events carry the +1 h and Arrêter buttons.
    public var category: String {
        switch kind {
        case .endingSoon, .batteryShort, .hot, .lidOpened, .chargerUnplugged, .dataThreshold, .networkRestored:
            Self.sessionCategory
        case .ended, .agentDone, .agentWaiting, .macLocked:
            Self.infoCategory
        }
    }

    public static let sessionCategory = "DARRAOWL_SESSION"
    public static let infoCategory = "DARRAOWL_INFO"
    public static let extendAction = "EXTEND_1H"
    public static let stopAction = "STOP"
}

public enum ByteText {
    /// "350 Mo", "1,2 Go".
    public static func short(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_000_000
        if mb < 1000 { return "\(Int(mb.rounded())) Mo" }
        let gb = mb / 1000
        return String(format: "%.1f Go", gb).replacingOccurrences(of: ".", with: ",")
    }
}
