import Foundation

/// `darraowl claude`: the script a Terminal window runs to start Claude
/// Code's Remote Control server in a folder. A window, so the server lives
/// on: a command sent from the phone stops after five minutes. Pure.
public enum ClaudeLauncher {
    /// A word for the shell, between single quotes.
    public static func quoted(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The session's name in the Claude app: the folder's.
    public static func sessionName(folder: String) -> String {
        let name = URL(fileURLWithPath: folder).lastPathComponent
        return name.isEmpty || name == "/" ? "Mac" : name
    }

    /// Removes itself, goes to the folder and becomes the server.
    public static func script(folder: String, claude: String) -> String {
        """
        #!/bin/zsh
        rm -f -- "$0"
        cd -- \(quoted(folder)) || exit 1
        exec \(quoted(claude)) remote-control --name \(quoted(sessionName(folder: folder)))

        """
    }

    /// Removes itself, goes to the conversation's folder and takes it up,
    /// with Remote Control, under the name it already has.
    public static func resumeScript(folder: String, claude: String, id: String, name: String) -> String {
        """
        #!/bin/zsh
        rm -f -- "$0"
        cd -- \(quoted(folder)) || exit 1
        exec \(quoted(claude)) --resume \(quoted(id)) --remote-control=\(quoted(name))

        """
    }

    /// The first `claude` in PATH, else where Claude Code and Homebrew
    /// install it: a PATH without ~/.local/bin is common (it is often set in
    /// ~/.zshrc only).
    public static func findClaude(path: String?, home: String, isExecutable: (String) -> Bool) -> String? {
        let folders = (path ?? "").split(separator: ":").map(String.init) + ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        return folders.lazy.filter { !$0.isEmpty }.map { "\($0)/claude" }.first(where: isExecutable)
    }
}
