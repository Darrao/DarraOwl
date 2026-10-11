import DarraOwlShared
import Foundation

/// What the battery and thermal state ask for during a session.
public struct FloorDecision: Equatable, Sendable {
    /// Non-nil: the session must end now.
    public var endReason: SessionEndReason?
    /// Low Power Mode is wanted.
    public var wantsLowPower: Bool

    public init(endReason: SessionEndReason? = nil, wantsLowPower: Bool = false) {
        self.endReason = endReason
        self.wantsLowPower = wantsLowPower
    }
}

/// Safety rule 4, as a pure function. `unreadableReads` counts consecutive
/// reads where a battery exists but its level could not be read; one is
/// tolerated as a transient IOKit miss, the second ends the session on battery
/// power because the end floor can no longer be applied.
public enum FloorRules {
    public static let unreadableReadsBeforeEnd = 2

    public static func decide(power: PowerSnapshot, unreadableReads: Int, settings: PowerSettings) -> FloorDecision {
        if power.thermal == .critical {
            return FloorDecision(endReason: .thermalCritical)
        }
        let onBattery = !power.onExternalPower
        switch power.battery {
        case let .percent(p) where onBattery && p < settings.endFloor:
            return FloorDecision(endReason: .batteryLow)
        case .unreadable where onBattery && unreadableReads >= unreadableReadsBeforeEnd:
            return FloorDecision(endReason: .batteryUnreadable)
        default:
            break
        }
        var wants = power.thermal == .serious
        if case let .percent(p) = power.battery, onBattery, p < settings.lowPowerFloor {
            wants = true
        }
        return FloorDecision(wantsLowPower: wants)
    }

    /// Why a session may not start now, or nil when it may.
    public static func startRefusal(power: PowerSnapshot, settings: PowerSettings) -> SessionEndReason? {
        let decision = decide(power: power, unreadableReads: 0, settings: settings)
        if let reason = decision.endReason { return reason }
        if case .unreadable = power.battery, !power.onExternalPower { return .batteryUnreadable }
        return nil
    }
}
