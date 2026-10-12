import DarraOwlShared
import Foundation

/// What `darraowl status` prints. Pure.
public enum CLIText {
    public static func status(_ s: EngineStatus, timeZone: TimeZone = .current) -> String {
        var lines: [String] = []
        if let session = s.session {
            let remaining = DurationText.short(session.remaining(at: s.now))
            let end = DurationText.clock(session.endsAt, timeZone: timeZone)
            if let watching = session.watchingText {
                lines.append("Éveillé tant que \(watching) \(session.watchingVerb), au plus jusqu'à \(end) (encore \(remaining)).")
                if let keep = session.keepUntil, keep > s.now {
                    lines.append("Session prévue jusqu'à \(DurationText.clock(keep, timeZone: timeZone)) même \(session.watching.count > 1 ? "s'ils finissent" : "s'il finit") avant.")
                }
            } else {
                lines.append("Éveillé jusqu'à \(end) (encore \(remaining)).")
            }
            lines.append("Lancée depuis \(origin(session.origin)).")
        } else {
            lines.append(backToNormal(s) ? "Veille normale : aucune session." : "Aucune session. Retour à la normale en cours.")
            if let last = s.lastEnd {
                lines.append("Dernière session : \(last.reason.inlineLabel) à \(DurationText.clock(last.endedAt, timeZone: timeZone)).")
            }
        }
        if let power = s.power {
            var parts: [String] = []
            if case let .percent(p) = power.battery { parts.append("Batterie \(p) %") }
            parts.append(power.onExternalPower ? "sur secteur" : "sur batterie")
            if power.thermal != .nominal { parts.append("température : \(power.thermal.label.lowercased())") }
            if s.lowPowerHeld { parts.append("économie d'énergie activée") }
            lines.append(parts.joined(separator: ", ") + ".")
        }
        if !s.pendingUndo.isEmpty {
            lines.append("Restauration incomplète, nouvel essai en cours : " + s.pendingUndo.joined(separator: " ; "))
        }
        return lines.joined(separator: "\n")
    }

    /// After a stop or a finished command: the Mac really is back to normal.
    public static func backToNormal(_ s: EngineStatus) -> Bool {
        s.session == nil && !s.sleepHeld && !s.lowPowerHeld && s.pendingUndo.isEmpty
    }

    public static func origin(_ o: SessionOrigin) -> String {
        switch o {
        case .menuBar: "la barre des menus"
        case .phone: "l'iPhone"
        case .cli: "le terminal"
        case .agent: "le mode agent"
        }
    }
}
