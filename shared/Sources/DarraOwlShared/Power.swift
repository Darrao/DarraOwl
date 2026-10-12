import Foundation

/// The built-in battery as read from the power source list.
public enum BatteryStatus: Codable, Equatable, Sendable {
    /// No internal battery (a desktop): battery floors do not apply.
    case none
    case percent(Int)
    /// A battery exists but its level could not be read.
    case unreadable

    public var percent: Int? {
        if case let .percent(p) = self { return p }
        return nil
    }
}

/// `ProcessInfo.ThermalState`, as data. No temperature in °C: that would need
/// private APIs.
public enum ThermalLevel: String, Codable, Sendable {
    case nominal
    case fair
    case serious
    case critical

    public var label: String {
        switch self {
        case .nominal: "Normale"
        case .fair: "Tiède"
        case .serious: "Élevée"
        case .critical: "Critique"
        }
    }
}

/// One read of battery, charger and thermal state.
public struct PowerSnapshot: Codable, Equatable, Sendable {
    public var battery: BatteryStatus
    /// True on AC power or while charging.
    public var onExternalPower: Bool
    public var thermal: ThermalLevel
    /// nil on a Mac without a lid, or when the registry could not be read.
    public var lidClosed: Bool?
    /// macOS's estimate on battery power; nil while it is still computing or on AC.
    public var minutesToEmpty: Int?

    public init(battery: BatteryStatus, onExternalPower: Bool, thermal: ThermalLevel, lidClosed: Bool? = nil, minutesToEmpty: Int? = nil) {
        self.battery = battery
        self.onExternalPower = onExternalPower
        self.thermal = thermal
        self.lidClosed = lidClosed
        self.minutesToEmpty = minutesToEmpty
    }
}
