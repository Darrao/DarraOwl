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
        guard let ac = modes.ac else {
            throw ProcessError(command: "pmset -g custom", detail: "lowpowermode absent")
        }
        // A Mac without a battery profile follows the AC value.
        return PowerSettingsState(sleepDisabled: sleepDisabled, lowPowerOnBattery: modes.battery ?? ac, lowPowerOnAC: ac)
    }

    public func setSleepDisabled(_ disabled: Bool) async throws {
        try await ProcessRunner.runChecked(Self.pmset, ["-a", "disablesleep", disabled ? "1" : "0"])
    }

    public func setLowPowerMode(onBattery: Bool, onAC: Bool) async throws {
        try await ProcessRunner.runChecked(Self.pmset, ["-b", "lowpowermode", onBattery ? "1" : "0"])
        try await ProcessRunner.runChecked(Self.pmset, ["-c", "lowpowermode", onAC ? "1" : "0"])
    }
}
