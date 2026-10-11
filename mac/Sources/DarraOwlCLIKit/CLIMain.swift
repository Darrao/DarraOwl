import Darwin
import DarraOwlCore
import DarraOwlShared
import DarraOwlXPC
import Foundation

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
            guard await request(client, .stop(reason: .userStopped)) != nil else { return 1 }
            print("Session arrêtée, veille normale rétablie.")
            return 0
        case let .run(seconds, arguments):
            return await run(arguments, seconds: seconds, client: client)
        }
    }

    /// Keeps the Mac awake while the command runs. The helper follows this
    /// process (not the command's): it outlives the command by a moment and
    /// tells the helper when the command is done; if it is killed, the helper
    /// sees it gone at its next check.
    static func run(_ arguments: [String], seconds: TimeInterval?, client: HelperClient) async -> Int32 {
        let pid = getpid()
        guard let start = ProcessStart.of(pid) else {
            say("darraowl : impossible de lire l'heure de démarrage de ce process.")
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

        let code = Spawn.runAndWait(arguments)

        if let after = await request(client, .release(pid: pid), quiet: true) {
            if let session = after.session {
                say("darraowl : \(name) terminé, la session continue jusqu'à \(DurationText.clock(session.endsAt)).")
            } else {
                say("darraowl : \(name) terminé, veille normale rétablie.")
            }
        }
        return code
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

    nonisolated static func say(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
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
    nonisolated(unsafe) private static var child: pid_t = 0
    nonisolated(unsafe) private static var sources: [DispatchSourceSignal] = []

    /// The command's exit code, 128 + the signal that killed it, or 126/127
    /// when it could not start (as a shell does).
    static func runAndWait(_ arguments: [String]) -> Int32 {
        // Ctrl-C and Ctrl-\\ go to the whole foreground group: the command
        // decides, and darraowl waits for it to end.
        signal(SIGINT, SIG_IGN)
        signal(SIGQUIT, SIG_IGN)
        // A kill or a closed terminal is passed on to the command.
        for sig in [SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { if child > 0 { kill(child, sig) } }
            source.resume()
            sources.append(source)
        }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for sig in [SIGINT, SIGQUIT, SIGTERM, SIGHUP] { sigaddset(&defaults, sig) }
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
            return rc == ENOENT ? 127 : 126
        }
        child = pid

        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            guard errno == EINTR else { return 1 }
        }
        child = 0
        let low = status & 0x7f
        if low == 0 { return (status >> 8) & 0xff }
        return 128 + low
    }
}
