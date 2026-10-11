import Foundation

/// Reads the text `pmset` prints. Pure, so it is tested on captured output.
public enum PmsetParser {
    /// `SleepDisabled` from `pmset -g`. nil when the line is absent: a
    /// missing line is not proof that sleep is enabled.
    public static func sleepDisabled(fromGet output: String) -> Bool? {
        for raw in output.split(whereSeparator: \.isNewline) {
            let parts = raw.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2, parts[0] == "SleepDisabled" else { continue }
            return parts[1] == "1"
        }
        return nil
    }

    /// `lowpowermode` of each profile from `pmset -g custom`. A profile the
    /// output does not list (a desktop has no battery profile) reads as nil.
    public static func lowPowerModes(fromCustom output: String) -> (battery: Bool?, ac: Bool?) {
        var section: String?
        var battery: Bool?
        var ac: Bool?
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if !line.hasPrefix(" "), !line.hasPrefix("\t"), line.hasSuffix(":") {
                section = line
                continue
            }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2, parts[0] == "lowpowermode" else { continue }
            let on = parts[1] == "1"
            switch section {
            case "Battery Power:": battery = on
            case "AC Power:": ac = on
            default: break
            }
        }
        return (battery, ac)
    }
}
