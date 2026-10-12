import DarraOwlShared
import Foundation

/// Turns state changes into notifications for the phone. Each kind fires at
/// most once per session (or once per change, for heat), never on a mere
/// state refresh.
public struct EventCenter: Sendable {
    public struct Input: Sendable {
        public var now: Date
        public var session: Session?
        public var power: PowerSnapshot?
        public var networkUp: Bool
        /// Bytes used since the session started.
        public var sessionBytes: Int64?
        public var lastEnd: SessionEndRecord?
        public var alerts: AlertSettings
        public var agentsDuringSession: [String]

        public init(now: Date, session: Session?, power: PowerSnapshot?, networkUp: Bool, sessionBytes: Int64?,
                    lastEnd: SessionEndRecord?, alerts: AlertSettings, agentsDuringSession: [String] = []) {
            self.now = now
            self.session = session
            self.power = power
            self.networkUp = networkUp
            self.sessionBytes = sessionBytes
            self.lastEnd = lastEnd
            self.alerts = alerts
            self.agentsDuringSession = agentsDuringSession
        }
    }

    public static let networkOutageThreshold: TimeInterval = 120
    /// In agent mode, warn below this much battery time.
    public static let agentBatteryWarning: TimeInterval = 45 * 60

    private var sessionID: UUID?
    private var fired: Set<MacEvent.Kind> = []
    private var startBattery: Int?
    private var lastHot = false
    private var lastLidClosed: Bool?
    private var lastExternal: Bool?
    private var networkDownSince: Date?
    private var seenEndID: UUID?
    private var primed = false
    /// The end time "bientôt finie" was sent for: a later one re-arms it.
    private var endingSoonFor: Date?

    public init() {}

    public mutating func update(_ input: Input) -> [MacEvent] {
        var events: [MacEvent] = []
        func emit(_ kind: MacEvent.Kind, _ title: String, _ body: String) {
            events.append(MacEvent(kind: kind, title: title, body: body, at: input.now))
        }

        // The first update only learns where things stand: an app launch
        // must not replay old events.
        defer { primed = true }

        // Session end first: the recap needs the battery level the session started at.
        if let end = input.lastEnd, end.sessionID != seenEndID {
            if primed, input.session == nil {
                emit(.ended, "Session terminée", Self.recap(end, input: input, startBattery: startBattery))
            }
            seenEndID = end.sessionID
        }
        if input.session?.id != sessionID {
            sessionID = input.session?.id
            fired = []
            startBattery = input.power?.battery.percent
            lastLidClosed = input.power?.lidClosed
            lastExternal = input.power?.onExternalPower
        }

        // Network outage, reported once it is over.
        if !input.networkUp {
            if networkDownSince == nil { networkDownSince = input.now }
        } else if let since = networkDownSince {
            networkDownSince = nil
            let gap = input.now.timeIntervalSince(since)
            if primed, input.session != nil, gap >= Self.networkOutageThreshold {
                emit(.networkRestored, "Réseau revenu", "Le Mac était hors ligne pendant \(DurationText.short(gap)).")
            }
        }

        // Heat: once each time it gets serious.
        let thermal = input.power?.thermal
        let hot = thermal == .serious || thermal == .critical
        if hot, !lastHot, primed, input.session != nil {
            if thermal == .critical {
                emit(.hot, "Le Mac surchauffe", "Température critique : la session s'arrête pour le protéger.")
            } else {
                emit(.hot, "Le Mac chauffe", "Température élevée : le mode économie d'énergie est activé.")
            }
        }
        lastHot = hot

        guard primed, let session = input.session, let power = input.power else {
            lastLidClosed = input.power?.lidClosed
            lastExternal = input.power?.onExternalPower
            return events
        }
        let remaining = session.remaining(at: input.now)

        func once(_ kind: MacEvent.Kind, _ title: String, _ body: String) {
            guard !fired.contains(kind) else { return }
            fired.insert(kind)
            emit(kind, title, body)
        }

        // Extended since the warning: warn again before the new end.
        if let warned = endingSoonFor, session.endsAt > warned.addingTimeInterval(60) {
            fired.remove(.endingSoon)
            endingSoonFor = nil
        }
        if remaining <= TimeInterval(input.alerts.endingSoonMinutes * 60), !fired.contains(.endingSoon) {
            endingSoonFor = session.endsAt
            once(.endingSoon, "Session bientôt finie", "Le Mac retrouve sa veille normale à \(DurationText.clock(session.endsAt)).")
        }
        if !power.onExternalPower, let minutes = power.minutesToEmpty {
            let autonomy = TimeInterval(minutes) * 60
            if session.isAgentMode {
                // The agent's end is unknown: warn when the battery is about to give out.
                if autonomy < Self.agentBatteryWarning {
                    once(.batteryShort, "Batterie bientôt vide", "Environ \(DurationText.short(autonomy)) d'autonomie : branche le chargeur pour que l'agent finisse.")
                }
            } else if autonomy < remaining - 300 {
                once(.batteryShort, "La batterie ne tiendra pas", "Environ \(DurationText.short(autonomy)) d'autonomie, la session finit à \(DurationText.clock(session.endsAt)).")
            }
        }
        if let bytes = input.sessionBytes, bytes >= Int64(input.alerts.dataThresholdMB) * 1_000_000 {
            once(.dataThreshold, "Data consommée", "\(ByteText.short(bytes)) depuis le début de la session.")
        }
        if input.alerts.antitheft {
            if lastLidClosed == true, power.lidClosed == false {
                emit(.lidOpened, "Capot ouvert", "Le capot du Mac vient d'être ouvert pendant la session.")
            }
            if lastExternal == true, !power.onExternalPower {
                emit(.chargerUnplugged, "Chargeur débranché", "Le Mac est passé sur batterie pendant la session.")
            }
        }
        lastLidClosed = power.lidClosed
        lastExternal = power.onExternalPower
        return events
    }

    static func recap(_ end: SessionEndRecord, input: Input, startBattery: Int?) -> String {
        var parts = ["\(end.reason.label) après \(DurationText.short(end.endedAt.timeIntervalSince(end.startedAt)))."]
        if let start = startBattery, let now = input.power?.battery.percent, start >= now {
            parts.append("Batterie : \(start - now) points.")
        }
        if let bytes = input.sessionBytes { parts.append("Data : \(ByteText.short(bytes)).") }
        if !input.agentsDuringSession.isEmpty { parts.append("Agents : \(input.agentsDuringSession.joined(separator: ", ")).") }
        if !end.failures.isEmpty { parts.append("Restauration incomplète, voir le Mac.") }
        return parts.joined(separator: " ")
    }
}

/// Session data usage from interface byte counters, which may reset (sleep,
/// interface going down): a counter going backwards starts a new baseline.
public struct DataMeter: Sendable {
    private var sessionID: UUID?
    private var last: Int64?
    public private(set) var used: Int64 = 0

    public init() {}

    /// Bytes of the session that just ended, for its recap.
    public private(set) var lastSessionTotal: Int64?

    public mutating func update(session: UUID?, counter: Int64?) -> Int64? {
        guard let session else {
            if sessionID != nil { lastSessionTotal = used }
            sessionID = nil
            last = nil
            used = 0
            return nil
        }
        if session != sessionID {
            sessionID = session
            last = counter
            used = 0
        } else if let counter, let previous = last {
            if counter >= previous { used += counter - previous }
            last = counter
        } else {
            last = counter
        }
        return used
    }
}
