import Foundation

/// Fixed limits shared by the Mac and the phone. The helper enforces them; the
/// UIs only use them to offer valid choices.
public enum Policy {
    public static let minimumSessionDuration: TimeInterval = 60
    public static let defaultSessionDuration: TimeInterval = 2 * 3600
    /// Default cap on how far in the future a session may end.
    public static let defaultMaxSessionDuration: TimeInterval = 12 * 3600
    /// The cap itself can be raised up to this, never further.
    public static let absoluteMaxSessionDuration: TimeInterval = 24 * 3600
    public static let minimumMaxSessionDuration: TimeInterval = 3600

    public static let quickDurations: [TimeInterval] = [30 * 60, 3600, 2 * 3600, 4 * 3600]
    public static let extensionSteps: [TimeInterval] = [30 * 60, 3600]

    public static let defaultLowPowerFloor = 40
    public static let defaultEndFloor = 15
    public static let endFloorRange = 5...50
    /// The Low Power Mode floor stays at least this far above the end floor.
    public static let floorGap = 5
    public static let maxLowPowerFloor = 95

    /// A phone command expires this long after it was issued.
    public static let commandLifetime: TimeInterval = 60
}

/// Battery floors and session cap, edited from the Mac or the phone and
/// enforced by the helper.
public struct PowerSettings: Codable, Equatable, Sendable {
    /// Below this percentage on battery, Low Power Mode is switched on.
    public var lowPowerFloor: Int
    /// Below this percentage on battery, the session ends.
    public var endFloor: Int
    /// A session may never end further than this from now.
    public var maxSessionDuration: TimeInterval
    public var lid: LidSettings
    public var alerts: AlertSettings

    public init(
        lowPowerFloor: Int = Policy.defaultLowPowerFloor,
        endFloor: Int = Policy.defaultEndFloor,
        maxSessionDuration: TimeInterval = Policy.defaultMaxSessionDuration,
        lid: LidSettings = LidSettings(),
        alerts: AlertSettings = AlertSettings()
    ) {
        self.lowPowerFloor = lowPowerFloor
        self.endFloor = endFloor
        self.maxSessionDuration = maxSessionDuration
        self.lid = lid
        self.alerts = alerts
    }

    private enum CodingKeys: String, CodingKey {
        case lowPowerFloor, endFloor, maxSessionDuration, lid, alerts
    }

    /// A file written before a key existed gets that key's default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lowPowerFloor = try c.decodeIfPresent(Int.self, forKey: .lowPowerFloor) ?? Policy.defaultLowPowerFloor
        endFloor = try c.decodeIfPresent(Int.self, forKey: .endFloor) ?? Policy.defaultEndFloor
        maxSessionDuration = try c.decodeIfPresent(TimeInterval.self, forKey: .maxSessionDuration) ?? Policy.defaultMaxSessionDuration
        lid = try c.decodeIfPresent(LidSettings.self, forKey: .lid) ?? LidSettings()
        alerts = try c.decodeIfPresent(AlertSettings.self, forKey: .alerts) ?? AlertSettings()
    }

    public static let `default` = PowerSettings()

    public enum ValidationError: Error, Equatable, Sendable {
        case endFloorOutOfRange
        case lowPowerFloorOutOfRange
        case maxDurationOutOfRange
        case lid(LidSettings.ValidationError)
        case alerts
    }

    /// Throws unless every value is within the policy ranges.
    public func validate() throws(ValidationError) {
        guard Policy.endFloorRange.contains(endFloor) else { throw .endFloorOutOfRange }
        guard lowPowerFloor >= endFloor + Policy.floorGap, lowPowerFloor <= Policy.maxLowPowerFloor else {
            throw .lowPowerFloorOutOfRange
        }
        guard maxSessionDuration >= Policy.minimumMaxSessionDuration,
              maxSessionDuration <= Policy.absoluteMaxSessionDuration
        else { throw .maxDurationOutOfRange }
        do {
            try lid.validate()
        } catch {
            throw .lid(error)
        }
        guard AlertSettings.dataThresholdRange.contains(alerts.dataThresholdMB),
              AlertSettings.endingSoonRange.contains(alerts.endingSoonMinutes)
        else { throw .alerts }
    }
}

/// Which events notify the phone.
public struct AlertSettings: Codable, Equatable, Sendable {
    /// Lid opened or charger unplugged during a session.
    public var antitheft: Bool
    /// Notify once a session used this much data (MB).
    public var dataThresholdMB: Int
    /// "Session bientôt finie" this many minutes before the end.
    public var endingSoonMinutes: Int
    /// Agent project names are left out of everything sent to iCloud.
    public var maskProjectNames: Bool
    /// The Mac locked itself during a session or Toujours actif (Teams then
    /// shows its user Away).
    public var macLocked: Bool

    public static let dataThresholdRange = 50...100_000
    public static let endingSoonRange = 1...60

    public init(antitheft: Bool = true, dataThresholdMB: Int = 1000, endingSoonMinutes: Int = 10, maskProjectNames: Bool = false,
                macLocked: Bool = true) {
        self.antitheft = antitheft
        self.dataThresholdMB = dataThresholdMB
        self.endingSoonMinutes = endingSoonMinutes
        self.maskProjectNames = maskProjectNames
        self.macLocked = macLocked
    }

    private enum CodingKeys: String, CodingKey { case antitheft, dataThresholdMB, endingSoonMinutes, maskProjectNames, macLocked }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        antitheft = try c.decodeIfPresent(Bool.self, forKey: .antitheft) ?? true
        dataThresholdMB = try c.decodeIfPresent(Int.self, forKey: .dataThresholdMB) ?? 1000
        endingSoonMinutes = try c.decodeIfPresent(Int.self, forKey: .endingSoonMinutes) ?? 10
        maskProjectNames = try c.decodeIfPresent(Bool.self, forKey: .maskProjectNames) ?? false
        macLocked = try c.decodeIfPresent(Bool.self, forKey: .macLocked) ?? true
    }
}
