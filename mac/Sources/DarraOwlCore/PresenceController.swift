import DarraOwlShared
import Foundation

/// Power assertions held by the app itself (never by the helper). macOS drops
/// them when the process exits, so nothing ever needs restoring: unlike a
/// session, presence changes no system setting.
public protocol PresenceAsserting: AnyObject {
    /// Keeps the display, hence the system, awake while the lid is open.
    func hold() throws
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
/// keep a closed lid awake; that is the job of a (bounded) session.
@MainActor
public final class PresenceController {
    public static let activityInterval: TimeInterval = 60

    public private(set) var isActive = false
    /// nil while active means no end time.
    public private(set) var until: Date?
    public private(set) var lastStop: PresenceStopReason?
    /// The lid is closed: nothing is held, nothing declared, whether or not
    /// presence is on (it can be turned on with the lid closed, from the phone).
    public private(set) var suspended = false
    /// The display was turned off on purpose (from the phone): activity is
    /// not declared again until it wakes, or it would light up at once.
    public private(set) var quiet = false

    private let asserter: any PresenceAsserting
    private var lastActivity: Date?
    private var holding = false

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
    public func setQuiet(_ quiet: Bool, now: Date = Date()) {
        guard quiet != self.quiet else { return }
        self.quiet = quiet
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

    /// Holds and declares only while active, the lid open and the display
    /// not put to sleep on purpose.
    private func apply(now: Date) throws {
        let wanted = isActive && !suspended && !quiet
        if wanted, !holding {
            try asserter.hold()
            holding = true
            asserter.declareActivity()
            lastActivity = now
        } else if !wanted, holding {
            asserter.release()
            holding = false
        }
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
        guard holding else { return }
        if let last = lastActivity, now.timeIntervalSince(last) < Self.activityInterval { return }
        asserter.declareActivity()
        lastActivity = now
    }
}
