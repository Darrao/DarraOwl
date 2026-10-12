import DarraOwlCore
import DarraOwlSystem
import Foundation

/// DarraOwl's hooks in Claude Code's own settings file, added and removed on
/// request. Nothing is written when the file exists but cannot be read, and
/// the user's own version is kept as a backup before the first change.
@MainActor
enum ClaudeCodeSetup {
    enum SetupError: Error, LocalizedError {
        case keychain

        var errorDescription: String? {
            "Le trousseau ne répond pas : réessaie dans un instant."
        }
    }

    static var directory: URL { URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".claude") }
    /// Followed if it is a symlink (dotfiles), so the link itself stays.
    static var file: URL { directory.appending(path: "settings.json").resolvingSymlinksInPath() }
    static var backup: URL { file.appendingPathExtension("darraowl-backup") }

    static var claudeInstalled: Bool {
        FileManager.default.fileExists(atPath: directory.path)
    }

    /// The file's bytes, nil when there is none. Any other read error is
    /// thrown: an unreadable file must never be taken for a missing one.
    static func read() throws -> Data? {
        do {
            return try Data(contentsOf: file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    static func state() throws -> ClaudeHookConfig.State {
        guard let token = HookToken.current() else { throw SetupError.keychain }
        return ClaudeHookConfig.state(try read(), port: HookServer.port, token: token)
    }

    static func install() throws {
        guard let token = HookToken.current() else { throw SetupError.keychain }
        let current = try read()
        let new = try ClaudeHookConfig.install(current, port: HookServer.port, token: token)
        // The user's version, before DarraOwl touched it.
        if let current, ClaudeHookConfig.state(current, port: HookServer.port, token: token) == .absent {
            try write(current, to: backup, permissionsOf: file)
        }
        if new != current { try write(new, to: file, permissionsOf: file) }
    }

    /// Takes out exactly DarraOwl's hooks; needs no token.
    /// Returns false when none was there: the file is then left untouched.
    @discardableResult
    static func remove() throws -> Bool {
        guard let current = try read(), ClaudeHookConfig.hasOurs(current, port: HookServer.port) else { return false }
        let new = try ClaudeHookConfig.remove(current, port: HookServer.port)
        try write(new, to: file, permissionsOf: file)
        return true
    }

    /// Written to a temporary file that already has the final permissions,
    /// then renamed over the target: never readable by others, never half
    /// written.
    private static func write(_ data: Data, to target: URL, permissionsOf reference: URL) throws {
        let fm = FileManager.default
        let dir = target.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let permissions = (try? fm.attributesOfItem(atPath: reference.path))?[.posixPermissions] as? NSNumber ?? 0o600
        let tmp = dir.appending(path: ".\(target.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: permissions]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: target.path])
        }
        guard rename(tmp.path, target.path) == 0 else {
            let code = errno
            try? fm.removeItem(at: tmp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
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
