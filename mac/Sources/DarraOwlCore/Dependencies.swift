import DarraOwlShared
import Foundation

/// The power settings the helper reads and changes. Live: `pmset`, run as root
/// by the helper. Tests: a fake that records calls.
public struct PowerSettingsState: Equatable, Sendable {
    public var sleepDisabled: Bool
    /// Low Power Mode of the battery profile (`pmset -b`); nil on a Mac
    /// without a battery profile.
    public var lowPowerOnBattery: Bool?
    /// Low Power Mode of the AC profile (`pmset -c`); nil when this Mac does
    /// not report it as `lowpowermode` (some MacBook Pros report a combined
    /// `powermode` with a High Power value DarraOwl must not lose). Low Power
    /// Mode is then left alone; sessions still work.
    public var lowPowerOnAC: Bool?

    public init(sleepDisabled: Bool, lowPowerOnBattery: Bool?, lowPowerOnAC: Bool?) {
        self.sleepDisabled = sleepDisabled
        self.lowPowerOnBattery = lowPowerOnBattery
        self.lowPowerOnAC = lowPowerOnAC
    }

    /// Low Power Mode can be read, changed and put back.
    public var lowPowerManageable: Bool { lowPowerOnAC != nil }
}

public protocol PowerControlling: Sendable {
    func readState() async throws -> PowerSettingsState
    /// `pmset -a disablesleep 0|1`.
    func setSleepDisabled(_ disabled: Bool) async throws
    /// `pmset -c lowpowermode`, and `pmset -b lowpowermode` when the Mac has
    /// a battery profile (`onBattery` nil: it has none).
    func setLowPowerMode(onBattery: Bool?, onAC: Bool) async throws
    /// `pmset sleepnow`.
    func sleepNow() async throws
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
