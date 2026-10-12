import Foundation

/// Who started a session.
public enum SessionOrigin: String, Codable, Sendable {
    case menuBar
    case phone
    case cli
    case agent
}

/// A process an agent-mode session follows.
public struct WatchedProcess: Codable, Equatable, Sendable {
    public var pid: Int32
    /// Executable name: "claude", "npm"… Never its arguments, which can hold
    /// a prompt (safety rule 8).
    public var name: String
    /// Folder name of its working directory; masked when publishing if the
    /// settings say so.
    public var project: String?
    /// Start time of the process, so a reused pid is not taken for it.
    public var startSeconds: Int64
    public var startMicros: Int32

    public init(pid: Int32, name: String, project: String?, startSeconds: Int64, startMicros: Int32) {
        self.pid = pid
        self.name = name
        self.project = project
        self.startSeconds = startSeconds
        self.startMicros = startMicros
    }

    /// "claude · DarraOwl", or "claude".
    public var label: String {
        project.map { "\(name) · \($0)" } ?? name
    }
}

/// One awake session. `endsAt` always exists: there is no open-ended session,
/// agent mode included.
///
/// Agent mode: while `watching` is not empty, the session also ends when the
/// last watched process exits. A timed session that an agent joined keeps its
/// planned end in `keepUntil` and goes back to it if the agents finish first.
public struct Session: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let startedAt: Date
    public var endsAt: Date
    public let origin: SessionOrigin
    public var watching: [WatchedProcess]
    public var keepUntil: Date?

    public init(
        id: UUID = UUID(), startedAt: Date, endsAt: Date, origin: SessionOrigin,
        watching: [WatchedProcess] = [], keepUntil: Date? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endsAt = endsAt
        self.origin = origin
        self.watching = watching
        self.keepUntil = keepUntil
    }

    private enum CodingKeys: String, CodingKey {
        case id, startedAt, endsAt, origin, watching, keepUntil
    }

    /// Journals and states written before agent mode lack the newer keys.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endsAt = try c.decode(Date.self, forKey: .endsAt)
        origin = try c.decode(SessionOrigin.self, forKey: .origin)
        watching = try c.decodeIfPresent([WatchedProcess].self, forKey: .watching) ?? []
        keepUntil = try c.decodeIfPresent(Date.self, forKey: .keepUntil)
    }

    public var isAgentMode: Bool { !watching.isEmpty }

    /// The end "+N" gives a session that ends at `end`: counted from now if
    /// it already ended, never more than `maxDuration` from now. The Mac
    /// applies it; the phone uses it to show the new end at once.
    public static func extendedEnd(_ end: Date, by seconds: TimeInterval, now: Date, maxDuration: TimeInterval) -> Date {
        min(max(end, now).addingTimeInterval(seconds), now.addingTimeInterval(maxDuration))
    }

    /// "tourne" or "tournent", to follow `watchingText`.
    public var watchingVerb: String {
        watching.count > 1 ? "tournent" : "tourne"
    }

    /// "claude · DarraOwl", "claude et npm", "3 processus".
    public var watchingText: String? {
        switch watching.count {
        case 0: nil
        case 1: watching[0].label
        case 2: "\(watching[0].name) et \(watching[1].name)"
        default: "\(watching.count) processus"
        }
    }

    /// "tant que claude · DarraOwl tourne", "tant que claude et npm tournent".
    public var whileWatchingText: String? {
        watchingText.map { "tant que \($0) \(watchingVerb)" }
    }

    /// The same, to start a line: "Tant que claude tourne".
    public var whileWatchingLine: String? {
        whileWatchingText.map(Self.capitalizingFirst)
    }

    public static func capitalizingFirst(_ s: String) -> String {
        s.prefix(1).uppercased() + s.dropFirst()
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
    case sleepRequested
    case agentFinished
    case macRestarted

    /// The label inside a sentence: "heure de fin atteinte", but
    /// "DarraOwl a été quitté".
    public var inlineLabel: String {
        let l = label
        guard !l.hasPrefix("DarraOwl"), let first = l.first else { return l }
        return first.lowercased() + l.dropFirst()
    }

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
        case .sleepRequested: "Mise en veille demandée"
        case .agentFinished: "L'agent a terminé"
        case .macRestarted: "Le Mac a redémarré"
        }
    }
}
