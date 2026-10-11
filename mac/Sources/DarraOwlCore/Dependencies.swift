import DarraOwlShared
import Foundation

/// The power settings the helper reads and changes. Live: `pmset`, run as root
/// by the helper. Tests: a fake that records calls.
public struct PowerSettingsState: Equatable, Sendable {
    public var sleepDisabled: Bool
    /// Low Power Mode of the battery profile (`pmset -b`).
    public var lowPowerOnBattery: Bool
    /// Low Power Mode of the AC profile (`pmset -c`).
    public var lowPowerOnAC: Bool

    public init(sleepDisabled: Bool, lowPowerOnBattery: Bool, lowPowerOnAC: Bool) {
        self.sleepDisabled = sleepDisabled
        self.lowPowerOnBattery = lowPowerOnBattery
        self.lowPowerOnAC = lowPowerOnAC
    }
}

public protocol PowerControlling: Sendable {
    func readState() async throws -> PowerSettingsState
    /// `pmset -a disablesleep 0|1`.
    func setSleepDisabled(_ disabled: Bool) async throws
    /// `pmset -b lowpowermode` and `pmset -c lowpowermode`, each profile on its own.
    func setLowPowerMode(onBattery: Bool, onAC: Bool) async throws
}

public protocol PowerSourceReading: Sendable {
    func read() -> PowerSnapshot
}

public protocol NowProviding: Sendable {
    func now() -> Date
}

public struct SystemClock: NowProviding {
    public init() {}
    public func now() -> Date { Date() }
}

public protocol EngineLogging: Sendable {
    func info(_ message: String)
    func error(_ message: String)
}
