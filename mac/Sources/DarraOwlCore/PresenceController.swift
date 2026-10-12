import DarraOwlShared
import Foundation

/// Power assertions held by the app itself (never by the helper). macOS drops
/// them when the process exits, so nothing ever needs restoring: unlike a
/// session, presence changes no system setting.
public protocol PresenceAsserting: AnyObject {
    /// `display` true: keeps the display, hence the system, awake while the
    /// lid is open. false: keeps only the system awake, the display may
    /// sleep. Switching from one to the other takes the new assertion before
    /// dropping the old one; on failure the old one stays.
    func hold(display: Bool) throws
    func release()
    /// Resets the system idle time, as a key press would. Apps that mark the
    /// user away after some idle time (Teams) then see an active user.
    func declareActivity()
}

public enum PresenceStopReason: String, Codable, Sendable {
    case user
    case timeUp
    case batteryLow
    case thermalCritical

    public var label: String {
        switch self {
        case .user: "Arrêté"
        case .timeUp: "Durée écoulée"
        case .batteryLow: "Batterie sous le seuil"
        case .thermalCritical: "Température critique"
        }
    }
}

/// "Presence" mode, à la Caffeine or Amphetamine: display awake and user
/// activity declared every minute, with or without an end time. It does not
/// keep a closed lid awake; that is the job of a (bounded) session. As an
/// option, while a session keeps the Mac awake with the lid closed, activity
/// is still declared every 4 minutes (apps such as Teams mark the user away
/// after 5), and the display goes dark again right after each one.
@MainActor
public final class PresenceController {
    public static let activityInterval: TimeInterval = 60
    /// Lid closed: as rarely as Teams' 5 minutes allow, each one wakes the display.
    public static let closedActivityInterval: TimeInterval = 240

    public private(set) var isActive = false
    /// nil while active means no end time.
    public private(set) var until: Date?
    public private(set) var lastStop: PresenceStopReason?
    /// The lid is closed: nothing is held, nothing declared, whether or not
    /// presence is on (it can be turned on with the lid closed, from the phone).
    public private(set) var suspended = false
    /// The display was turned off on purpose (from the phone): activity is
    /// not declared again until it wakes, or it would light up at once. The
    /// Mac itself stays awake.
    public private(set) var quiet = false
    /// Option: keep declaring activity with the lid closed, during a session.
    public private(set) var whileClosed = false
    /// A session keeps the Mac awake: without one, a closed lid sleeps anyway.
    public private(set) var sessionRunning = false
    /// Called after each activity declared with the lid closed: the display
    /// it woke goes dark again.
    public var onClosedActivity: (() -> Void)?

    private enum Hold { case none, display, system, closed }

    private let asserter: any PresenceAsserting
    private var lastActivity: Date?
    private var holding = Hold.none

    public init(asserter: any PresenceAsserting) {
        self.asserter = asserter
    }

    public func start(until: Date?, now: Date) throws {
        isActive = true
        self.until = until
        lastStop = nil
        do {
            try apply(now: now)
        } catch {
            isActive = false
            self.until = nil
            throw error
        }
    }

    /// Lid closed: drop the display assertion without ending presence.
    public func setSuspended(_ suspended: Bool, now: Date = Date()) {
        guard suspended != self.suspended else { return }
        self.suspended = suspended
        try? apply(now: now)
    }

    /// The display was put to sleep from the phone (true) or woke (false).
    /// Kept while presence is off too: presence turned on afterwards does
    /// not light the display either.
    public func setQuiet(_ quiet: Bool, now: Date = Date()) {
        guard quiet != self.quiet else { return }
        self.quiet = quiet
        try? apply(now: now)
    }

    public func setWhileClosed(_ on: Bool, now: Date = Date()) {
        guard on != whileClosed else { return }
        whileClosed = on
        try? apply(now: now)
    }

    public func setSessionRunning(_ running: Bool, now: Date = Date()) {
        guard running != sessionRunning else { return }
        sessionRunning = running
        try? apply(now: now)
    }

    public func stop(_ reason: PresenceStopReason) {
        guard isActive else { return }
        isActive = false
        until = nil
        lastActivity = nil
        lastStop = reason
        try? apply(now: Date())
    }

    /// Active with the lid open: the display is held and activity declared,
    /// or, with the display put to sleep on purpose, only the system is held.
    /// Lid closed: nothing, or with the option during a session, activity
    /// only (the session keeps the Mac awake, nothing holds the display).
    private func apply(now: Date) throws {
        let wanted: Hold
        if !isActive {
            wanted = .none
        } else if suspended {
            wanted = whileClosed && sessionRunning ? .closed : .none
        } else {
            wanted = quiet ? .system : .display
        }
        guard wanted != holding else { return }
        switch wanted {
        case .none:
            asserter.release()
        case .display:
            try asserter.hold(display: true)
            asserter.declareActivity()
            lastActivity = now
        case .system:
            try asserter.hold(display: false)
        case .closed:
            asserter.release()
            asserter.declareActivity()
            lastActivity = now
            onClosedActivity?()
        }
        holding = wanted
    }

    /// Called about every second. `power` is nil when unknown: presence then
    /// goes on, as Caffeine would.
    public func tick(now: Date, power: PowerSnapshot?, settings: PowerSettings) {
        guard isActive else { return }
        if let until, now >= until {
            stop(.timeUp)
            return
        }
        if let power {
            switch FloorRules.decide(power: power, unreadableReads: 0, settings: settings).endReason {
            case .batteryLow?: stop(.batteryLow); return
            case .thermalCritical?: stop(.thermalCritical); return
            default: break
            }
        }
        let interval: TimeInterval
        switch holding {
        case .display: interval = Self.activityInterval
        case .closed: interval = Self.closedActivityInterval
        case .none, .system: return
        }
        if let last = lastActivity, now.timeIntervalSince(last) < interval { return }
        asserter.declareActivity()
        lastActivity = now
        if holding == .closed { onClosedActivity?() }
    }
}
