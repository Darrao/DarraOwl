import Darwin
import DarraOwlCore
import DarraOwlShared
import DarraOwlXPC
import Foundation
import Synchronization

/// `darraowl`, the command line client of the helper. Signed with the
/// identifier the helper accepts (`com.darrao.darraowl.mac.cli`).
@MainActor
public enum CLIMain {
    public static func run() async -> Int32 {
        let command: CLICommand
        do {
            command = try CLICommand.parse(Array(CommandLine.arguments.dropFirst()))
        } catch {
            say("darraowl : \(error.localizedDescription)")
            say("darraowl help pour l'aide.")
            return 64
        }
        let client = HelperClient()
        defer { client.invalidate() }
        switch command {
        case .help:
            print(CLICommand.usage)
            return 0
        case .version:
            print(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
            return 0
        case .status:
            guard let status = await request(client, .status) else { return 1 }
            print(CLIText.status(status))
            return 0
        case let .start(seconds):
            guard let status = await request(client, .start(seconds: seconds, origin: .cli)) else { return 1 }
            print(CLIText.status(status))
            return 0
        case let .extend(seconds):
            guard let status = await request(client, .extend(seconds: seconds)) else { return 1 }
            print(CLIText.status(status))
            return 0
        case .stop:
            guard let status = await request(client, .stop(reason: .userStopped)) else { return 1 }
            print(CLIText.backToNormal(status)
                ? "Session arrêtée, veille normale rétablie."
                : "Session arrêtée. Retour à la normale en cours : voir darraowl status.")
            return 0
        case let .run(seconds, arguments):
            return await run(arguments, seconds: seconds, client: client)
        case let .claude(request):
            switch request {
            case let .new(folder): return openClaude(in: folder)
            case let .list(folder): return listConversations(in: folder)
            case let .latest(folder): return resumeLatest(in: folder)
            case let .resume(id): return resume(id)
            }
        }
    }

    // MARK: Claude Code

    /// Claude Code's Remote Control server in a new Terminal window, found
    /// then in the Claude app (Code). The folder should be one Claude has
    /// already opened on this Mac: in another, it asks in the window whether
    /// to trust it.
    static func openClaude(in folder: String?) -> Int32 {
        let target = absolute(folder)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target, isDirectory: &isFolder), isFolder.boolValue else {
            say("darraowl : dossier introuvable : \(target)")
            return 1
        }
        guard let claude = claudePath(), openInTerminal(ClaudeLauncher.script(folder: target, claude: claude)) else { return 1 }
        print("Claude Code démarre dans une fenêtre Terminal du Mac, dans \(target).")
        print("Retrouve la session « \(ClaudeLauncher.sessionName(folder: target)) » dans l'app Claude, onglet Code.")
        return 0
    }

    /// The latest conversations, the open ones marked. Read from Claude's
    /// transcripts only: nothing in the folders themselves (macOS would ask
    /// on the Mac before DarraOwl reads Documents, and nobody is there).
    static func listConversations(in folder: String?) -> Int32 {
        let target = folder.map(absolute)
        let found = ClaudeConversations.recent(in: projectsRoot, folder: target, limit: 12)
        guard !found.isEmpty else {
            print(target.map { "Aucune conversation Claude Code dans \($0)." } ?? "Aucune conversation Claude Code sur ce Mac.")
            return 0
        }
        let open = claudePath(quiet: true).flatMap(openConversations) ?? []
        print(ClaudeConversations.listing(found, open: open, home: NSHomeDirectory(), now: Date(), calendar: .current))
        return 0
    }

    static func resumeLatest(in folder: String?) -> Int32 {
        let target = absolute(folder)
        guard let latest = ClaudeConversations.recent(in: projectsRoot, folder: target, limit: 1).first else {
            say("darraowl : aucune conversation Claude Code dans \(target). darraowl claude en commence une.")
            return 1
        }
        return take(latest)
    }

    static func resume(_ id: String) -> Int32 {
        switch ClaudeConversations.find(id, in: projectsRoot) {
        case let .found(conversation):
            return take(conversation)
        case .none:
            say("darraowl : aucune conversation \(id). darraowl claude --list les montre.")
        case .several:
            say("darraowl : plusieurs conversations commencent par \(id) : donne plus de caractères.")
        }
        return 1
    }

    /// In a Terminal window, in its folder, unless it is open already: two
    /// copies would each go their own way.
    static func take(_ conversation: ClaudeConversations.Conversation) -> Int32 {
        guard let folder = conversation.folder else {
            say("darraowl : le dossier de cette conversation est inconnu.")
            return 1
        }
        guard let claude = claudePath() else { return 1 }
        if openConversations(claude: claude)?.contains(conversation.id) == true {
            say("darraowl : cette conversation est déjà ouverte sur le Mac (app Claude ou Terminal) : la reprendre ici en ferait deux. "
                + "Si Remote Control y est activé, elle est dans l'app Claude, onglet Code.")
            return 1
        }
        let name = conversation.title ?? ClaudeLauncher.sessionName(folder: folder)
        guard openInTerminal(ClaudeLauncher.resumeScript(folder: folder, claude: claude, id: conversation.id, name: name)) else { return 1 }
        print("Claude Code reprend « \(name) » dans une fenêtre Terminal du Mac, dans \(ClaudeConversations.shown(folder, home: NSHomeDirectory())).")
        print("Retrouve-la dans l'app Claude, onglet Code.")
        return 0
    }

    /// Claude's transcripts: in CLAUDE_CONFIG_DIR when set, else ~/.claude.
    static var projectsRoot: URL {
        let configured = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let config = configured.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appending(path: ".claude", directoryHint: .isDirectory)
        return config.appending(path: "projects", directoryHint: .isDirectory)
    }

    /// The folder as an absolute path (the current one when nil), unchecked:
    /// `standardized`, not `standardizedFileURL`, which would look at the
    /// disk (symbolic links, /private), Documents included.
    static func absolute(_ folder: String?) -> String {
        let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let path = folder.map { ($0 as NSString).expandingTildeInPath } ?? here.path
        return URL(fileURLWithPath: path, relativeTo: here).absoluteURL.standardized.path
    }

    static func claudePath(quiet: Bool = false) -> String? {
        let found = ClaudeLauncher.findClaude(path: ProcessInfo.processInfo.environment["PATH"], home: NSHomeDirectory(),
                                              isExecutable: { FileManager.default.isExecutableFile(atPath: $0) })
        if found == nil, !quiet { say("darraowl : Claude Code est introuvable sur ce Mac (commande claude).") }
        return found
    }

    /// Ids of the conversations open on this Mac; nil when Claude does not
    /// say within a few seconds.
    static func openConversations(claude: String) -> Set<String>? {
        output(of: claude, ["agents", "--json"], timeout: 15).flatMap(ClaudeConversations.openIDs)
    }

    /// What a command prints, when it ends well within `timeout`. Into a
    /// file, not a pipe: nothing it starts can keep the read waiting.
    static func output(of executable: String, _ arguments: [String], timeout: TimeInterval) -> Data? {
        let files = FileManager.default
        let file = files.temporaryDirectory.appending(path: "darraowl-\(UUID().uuidString).out")
        guard files.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let out = try? FileHandle(forWritingTo: file) else { return nil }
        defer {
            try? out.close()
            try? files.removeItem(at: file)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        do { try process.run() } catch { return nil }
        guard ended.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        return try? Data(contentsOf: file)
    }

    /// Runs the script in a new Terminal window; it removes itself there.
    static func openInTerminal(_ text: String) -> Bool {
        let files = FileManager.default
        let script = files.temporaryDirectory.appending(path: "darraowl-claude-\(UUID().uuidString).command")
        do {
            try text.write(to: script, atomically: true, encoding: .utf8)
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        } catch {
            say("darraowl : \(error.localizedDescription)")
            return false
        }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-a", "Terminal", script.path]
        do {
            try open.run()
            open.waitUntilExit()
        } catch {
            try? files.removeItem(at: script)
            say("darraowl : Terminal ne s'ouvre pas : \(error.localizedDescription)")
            return false
        }
        guard open.terminationStatus == 0 else {
            try? files.removeItem(at: script)
            say("darraowl : Terminal ne s'ouvre pas.")
            return false
        }
        return true
    }

    /// Keeps the Mac awake while the command runs. The helper follows this
    /// process (not the command's): it outlives the command by a moment and
    /// tells the helper when the command is done; if it is killed, the helper
    /// sees it gone at its next check.
    static func run(_ arguments: [String], seconds: TimeInterval?, client: HelperClient) async -> Int32 {
        let pid = getpid()
        guard let start = ProcessStart.of(pid) else {
            say("darraowl : impossible de lire l'heure de démarrage de ce processus.")
            return 1
        }
        let name = URL(fileURLWithPath: arguments[0]).lastPathComponent
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).lastPathComponent
        let process = WatchedProcess(
            pid: pid, name: name, project: folder.isEmpty || folder == "/" ? nil : folder,
            startSeconds: start.seconds, startMicros: start.micros
        )
        guard let status = await request(client, .watch(process, seconds: seconds, origin: .cli)) else {
            say("darraowl : commande non lancée.")
            return 1
        }
        if let end = status.session?.endsAt {
            say("darraowl : Mac éveillé tant que \(name) tourne, au plus jusqu'à \(DurationText.clock(end)).")
        }

        let outcome = Spawn.runAndWait(arguments)

        if let after = await request(client, .release(pid: pid), quiet: true) {
            let what = outcome.started ? "\(name) terminé" : "\(name) n'a pas pu être lancé"
            if let session = after.session {
                say("darraowl : \(what), la session continue jusqu'à \(DurationText.clock(session.endsAt)).")
            } else if CLIText.backToNormal(after) {
                say("darraowl : \(what), veille normale rétablie.")
            } else {
                say("darraowl : \(what). Retour à la normale en cours : voir darraowl status.")
            }
        }
        // Killed by Ctrl-C (or Ctrl-\\): die the same way, so a shell loop stops too.
        if let signal = outcome.signal, signal == SIGINT || signal == SIGQUIT {
            Spawn.restoreDefaults()
            raise(signal)
        }
        return outcome.code
    }

    /// Sends a request; prints why it failed and returns nil.
    static func request(_ client: HelperClient, _ request: HelperRequest, quiet: Bool = false) async -> EngineStatus? {
        do {
            let response = try await client.send(request)
            if let error = response.error {
                if !quiet { say("darraowl : \(error)") }
                return nil
            }
            return response.status
        } catch HelperClientError.unsignedBuild {
            if !quiet { say("darraowl : cette copie n'est pas signée. Utilise celle de DarraOwl (Réglages > Terminal).") }
            return nil
        } catch {
            if !quiet {
                say("darraowl : DarraOwl ne répond pas (\(error.localizedDescription)). Ouvre DarraOwl et vérifie le composant système.")
            }
            return nil
        }
    }

    /// To stderr. fputs, not FileHandle: writing to a terminal that went
    /// away must not raise an exception.
    nonisolated static func say(_ text: String) {
        fputs(text + "\n", stderr)
    }
}

/// Start time of a process, as the helper reads it.
enum ProcessStart {
    static func of(_ pid: pid_t) -> (seconds: Int64, micros: Int32)? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var entry = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &entry, &size, nil, 0) == 0, size == MemoryLayout<kinfo_proc>.stride else { return nil }
        let t = entry.kp_proc.p_starttime
        return (Int64(t.tv_sec), Int32(truncatingIfNeeded: t.tv_usec))
    }
}

/// Runs the command in the foreground, attached to the terminal, and waits.
enum Spawn {
    struct Outcome {
        /// The command's exit code, 128 + the signal that killed it, or
        /// 126/127 when it could not start (as a shell does).
        var code: Int32
        /// The signal that killed it.
        var signal: Int32?
        var started: Bool
    }

    /// The running command, read by the signal handlers on another thread.
    private static let child = Atomic<Int32>(0)
    /// A signal that came before the child existed, passed on once it does.
    private static let pending = Atomic<Int32>(0)
    nonisolated(unsafe) private static var sources: [DispatchSourceSignal] = []
    nonisolated(unsafe) private static var inherited: [Int32: Bool] = [:]

    static func runAndWait(_ arguments: [String]) -> Outcome {
        // A disposition inherited as "ignored" stays ignored for the command:
        // a background job keeps ignoring Ctrl-C, and `nohup darraowl run …`
        // keeps the command alive when the terminal closes.
        var keepIgnored = sigset_t()
        sigemptyset(&keepIgnored)
        for sig in [SIGINT, SIGQUIT, SIGTERM, SIGHUP] {
            let previous = signal(sig, SIG_IGN)
            // SIG_IGN is the handler value 1.
            let wasIgnored = previous.map { unsafeBitCast($0, to: Int.self) == 1 } ?? false
            inherited[sig] = wasIgnored
            if wasIgnored { sigaddset(&keepIgnored, sig) }
        }
        // Ctrl-C and Ctrl-\\ go to the whole foreground group: the command
        // decides, and darraowl waits for it to end. A kill or a closed
        // terminal is passed on to the command.
        for sig in [SIGTERM, SIGHUP] where inherited[sig] != true {
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler {
                // Stored first, then the child read: whichever side comes
                // second sends it (twice at worst, which is harmless).
                pending.store(sig, ordering: .sequentiallyConsistent)
                let pid = child.load(ordering: .sequentiallyConsistent)
                if pid > 0 { kill(pid, sig) }
            }
            source.resume()
            sources.append(source)
        }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for sig in [SIGINT, SIGQUIT, SIGTERM, SIGHUP] where sigismember(&keepIgnored, sig) == 0 {
            sigaddset(&defaults, sig)
        }
        posix_spawnattr_setsigdefault(&attr, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attr, &mask)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawnp(&pid, arguments[0], nil, &attr, argv, environ)
        guard rc == 0 else {
            CLIMain.say("darraowl : impossible de lancer \(arguments[0]) : \(String(cString: strerror(rc))).")
            return Outcome(code: rc == ENOENT ? 127 : 126, signal: nil, started: false)
        }
        child.store(pid, ordering: .sequentiallyConsistent)
        let early = pending.exchange(0, ordering: .sequentiallyConsistent)
        if early != 0 { kill(pid, early) }

        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            guard errno == EINTR else { return Outcome(code: 1, signal: nil, started: true) }
        }
        child.store(0, ordering: .sequentiallyConsistent)
        let low = status & 0x7f
        if low == 0 { return Outcome(code: (status >> 8) & 0xff, signal: nil, started: true) }
        return Outcome(code: 128 + low, signal: low, started: true)
    }

    /// Back to the dispositions darraowl started with, before raising the
    /// child's signal on itself.
    static func restoreDefaults() {
        for sig in [SIGINT, SIGQUIT] where inherited[sig] != true {
            signal(sig, SIG_DFL)
        }
    }
}
