import Foundation
import Security

/// Code signing requirements that pin each side of the XPC connection to code
/// signed by the same Apple team, with a fixed identifier.
public enum CodeRequirements {
    /// A Team ID is ten upper-case letters or digits. Anything else is refused
    /// rather than spliced into a requirement string.
    public static func isValidTeamID(_ team: String) -> Bool {
        team.count == 10 && team.allSatisfy { ($0.isASCII && $0.isUppercase) || $0.isNumber }
    }

    /// What the helper requires of a client: the app or the CLI.
    public static func client(teamID: String) -> String? {
        guard isValidTeamID(teamID) else { return nil }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" and (identifier \"\(HelperConstants.appIdentifier)\" or identifier \"\(HelperConstants.cliIdentifier)\")"
    }

    /// What a client requires of the helper.
    public static func helper(teamID: String) -> String? {
        guard isValidTeamID(teamID) else { return nil }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" and identifier \"\(HelperConstants.helperIdentifier)\""
    }

    /// Team ID of the running code, nil when unsigned or ad-hoc signed. Both
    /// sides derive the pin from their own signature, so no Team ID is
    /// hard-coded and an unsigned build talks to nobody.
    public static func currentTeamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any]
        else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
