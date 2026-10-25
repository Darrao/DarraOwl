import Foundation

/// PATH as a Terminal window has it, for the commands sent from the phone.
/// zsh reads ~/.zshrc, where PATH is often extended (~/.local/bin for
/// claude, Homebrew, node), only when interactive: an interactive login
/// shell prints it once, between what its profile prints. Pure.
public enum TerminalPath {
    public static let marker = "__DARRAOWL_PATH__"

    /// What the interactive shell runs.
    public static let probe = "printf '\\n%s%s\\n' \(marker) \"$PATH\""

    /// The PATH the probe printed, nil if none.
    public static func parse(_ output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline).reversed() where line.hasPrefix(marker) {
            let path = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            return path.isEmpty ? nil : path
        }
        return nil
    }

    /// `first` ahead of `path`, without a second copy of it.
    public static func prepending(_ first: String, to path: String) -> String {
        ([first] + path.split(separator: ":").map(String.init).filter { $0 != first && !$0.isEmpty }).joined(separator: ":")
    }
}
