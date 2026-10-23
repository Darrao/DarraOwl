import Foundation

/// The phone's terminal, as a terminal window: one current folder, kept on
/// the Mac. A command starts there, and the folder it ends in (after a cd)
/// is the next one's. The phone never sends a path. Pure.
public enum TerminalSession {
    public static let marker = "__DARRAOWL_PWD__"

    /// The command, then the folder it ended in, printed last; its exit
    /// status kept. Through eval, so the command stays one piece: a last
    /// line ending in \, && or |, or an open heredoc, does not run into
    /// what follows; a parse error is the command's. A command that exits
    /// prints no folder. POSIX shells only (zsh, bash, sh…).
    public static func wrap(_ text: String) -> String {
        "eval \(ClaudeLauncher.quoted(text))\n__darraowl_status=$?\nprintf '\\n%s%s\\n' \(marker) \"$PWD\"\nexit $__darraowl_status"
    }

    /// What the command printed, without the folder line, and that folder.
    public static func split(_ output: String) -> (text: String, directory: String?) {
        // Literal: after a lone CR, "\r\n" is one Character and would hide the "\n".
        guard let start = output.range(of: "\n" + marker, options: [.backwards, .literal]) else { return (output, nil) }
        let rest = output[start.upperBound...]
        let line = rest.prefix { $0 != "\n" }
        // Something left in the background may print after it.
        let after = rest.dropFirst(line.count).dropFirst()
        let before = String(output[..<start.lowerBound])
        return (after.isEmpty ? before : before + "\n" + after, line.isEmpty ? nil : String(line))
    }

    /// "~/Dev/api" for a folder in the home folder, "~" for the home folder.
    public static func shown(_ path: String, home: String, masked: Bool = false) -> String {
        if path == home { return "~" }
        // Project names masked (Réglages): only whether it is under home.
        if masked { return path == "/" ? "/" : path.hasPrefix(home + "/") ? "~/…" : "/…" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
