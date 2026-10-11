import DarraOwlCore
import DarraOwlSystem
import Foundation

/// DarraOwl's hooks in Claude Code's own settings file, added and removed on
/// request. The file is backed up before each change.
@MainActor
enum ClaudeCodeSetup {
    static var directory: URL { URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".claude") }
    /// Followed if it is a symlink (dotfiles), so the link itself stays.
    static var file: URL { directory.appending(path: "settings.json").resolvingSymlinksInPath() }
    static var backup: URL { file.appendingPathExtension("darraowl-backup") }

    static var claudeInstalled: Bool {
        FileManager.default.fileExists(atPath: directory.path)
    }

    static func state() -> ClaudeHookConfig.State {
        ClaudeHookConfig.state(try? Data(contentsOf: file), port: HookServer.port, token: HookToken.current())
    }

    static func install() throws {
        let current = try? Data(contentsOf: file)
        try write(ClaudeHookConfig.install(current, port: HookServer.port, token: HookToken.current()), replacing: current)
    }

    static func remove() throws {
        guard let current = try? Data(contentsOf: file) else { return }
        try write(ClaudeHookConfig.remove(current, port: HookServer.port), replacing: current)
    }

    private static func write(_ new: Data, replacing current: Data?) throws {
        guard new != current else { return }
        let fm = FileManager.default
        let permissions = (try? fm.attributesOfItem(atPath: file.path))?[.posixPermissions] as? NSNumber
        if let current {
            try current.write(to: backup, options: .atomic)
            if let permissions { try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: backup.path) }
        } else {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try new.write(to: file, options: .atomic)
        if let permissions { try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path) }
    }
}

/// The `darraowl` command: a link in ~/.local/bin to the copy inside the app.
/// No sudo, nothing outside the user's home.
@MainActor
enum CommandLineLink {
    enum State: Equatable {
        case installed
        case absent
        /// A link to another copy of DarraOwl: replaced on install.
        case elsewhere(String)
        /// Something that is not ours: never touched.
        case foreign
        /// This build has no embedded tool (a SwiftPM run).
        case unavailable
    }

    static var directory: URL { URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".local/bin") }
    static var link: URL { directory.appending(path: "darraowl") }
    static var tool: URL { Bundle.main.bundleURL.appending(path: "Contents/Helpers/darraowl") }

    static func state() -> State {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: tool.path) else { return .unavailable }
        guard let destination = try? fm.destinationOfSymbolicLink(atPath: link.path) else {
            return (try? fm.attributesOfItem(atPath: link.path)) == nil ? .absent : .foreign
        }
        if destination == tool.path { return .installed }
        return isOurs(destination) ? .elsewhere(destination) : .foreign
    }

    static func install() throws {
        switch state() {
        case .installed, .unavailable: return
        case .foreign: throw CocoaError(.fileWriteFileExists)
        case .elsewhere: try FileManager.default.removeItem(at: link)
        case .absent: break
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tool)
    }

    /// Removes the link only when it points to a DarraOwl copy.
    static func remove() throws {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path), isOurs(destination) else { return }
        try FileManager.default.removeItem(at: link)
    }

    private static func isOurs(_ path: String) -> Bool {
        path.hasSuffix("DarraOwl.app/Contents/Helpers/darraowl")
    }
}
