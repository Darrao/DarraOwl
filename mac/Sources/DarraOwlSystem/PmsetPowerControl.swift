import DarraOwlCore
import Foundation

/// `/usr/bin/pmset`, run directly by the root helper. Only these argument
/// lists are ever built; nothing comes from outside.
public struct PmsetPowerControl: PowerControlling {
    static let pmset = "/usr/bin/pmset"

    public init() {}

    public func readState() async throws -> PowerSettingsState {
        let get = try await ProcessRunner.runChecked(Self.pmset, ["-g"])
        let custom = try await ProcessRunner.runChecked(Self.pmset, ["-g", "custom"])
        guard let sleepDisabled = PmsetParser.sleepDisabled(fromGet: get) else {
            throw ProcessError(command: "pmset -g", detail: "SleepDisabled absent")
        }
        let modes = PmsetParser.lowPowerModes(fromCustom: custom)
        // Without a plain lowpowermode line, Low Power Mode is left alone.
        return PowerSettingsState(sleepDisabled: sleepDisabled, lowPowerOnBattery: modes.ac == nil ? nil : modes.battery, lowPowerOnAC: modes.ac)
    }

    public func setSleepDisabled(_ disabled: Bool) async throws {
        try await ProcessRunner.runChecked(Self.pmset, ["-a", "disablesleep", disabled ? "1" : "0"])
    }

    public func sleepNow() async throws {
        try await ProcessRunner.runChecked(Self.pmset, ["sleepnow"])
    }

    public func setLowPowerMode(onBattery: Bool?, onAC: Bool) async throws {
        if let onBattery {
            try await ProcessRunner.runChecked(Self.pmset, ["-b", "lowpowermode", onBattery ? "1" : "0"])
        }
        try await ProcessRunner.runChecked(Self.pmset, ["-c", "lowpowermode", onAC ? "1" : "0"])
    }
}
