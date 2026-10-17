import Darwin
import DarraOwlShared
import Foundation

/// Runs one shell command sent from the phone: the user's login shell
/// (`-l -c`), in a folder, with no terminal and no input, under a time
/// limit. Standard output and error come back together, the end of them
/// when they exceed the limit. The shell leads its own process group, so
/// the time limit stops everything it started: SIGTERM, then SIGKILL two
/// seconds later, and what was printed by then comes back with no exit
/// status. Something left running in the background keeps going; its
/// output is no longer read once the shell has ended.
public enum RemoteShell {
    /// Between SIGTERM and SIGKILL.
    static let killGrace: TimeInterval = 2
    /// After the shell ended, what its children still write is read this long.
    static let drainGrace: TimeInterval = 1

    public struct LaunchError: Error, LocalizedError, Sendable {
        public let detail: String
        public var errorDescription: String? { "Impossible de lancer la commande : \(detail)" }
    }

    /// The user's login shell as the directory service has it, /bin/zsh
    /// otherwise: the same PATH and aliases as a Terminal window, once the
    /// profile is read.
    public static var shell: String {
        if let entry = getpwuid(getuid()), let raw = entry.pointee.pw_shell, case let path = String(cString: raw),
           !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return "/bin/zsh"
    }

    public static func run(_ text: String, in directory: String, timeout: TimeInterval = Policy.remoteCommandTimeout,
                           limit: Int = Policy.remoteCommandOutputLimit) async throws -> ShellOutput {
        let shell = Self.shell
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw LaunchError(detail: String(cString: strerror(errno))) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // No input: a command that asks for one (sudo, a prompt) sees the
        // end of it and fails instead of waiting for the time limit.
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, fds[1], 1)
        posix_spawn_file_actions_adddup2(&actions, fds[1], 2)
        posix_spawn_file_actions_addchdir(&actions, directory)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // Its own process group: the time limit stops the whole tree. The
        // app's signal dispositions and mask are not the command's. Nothing
        // of the app's descriptors leaks into it (CLOEXEC_DEFAULT keeps only
        // the three set above).
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigdefault(&attr, &all)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attr, &none)
        posix_spawnattr_setpgroup(&attr, 0)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var argv: [UnsafeMutablePointer<CChar>?] = [shell, "-l", "-c", text].map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = environment(shell: shell).map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer { (argv + envp).forEach { free($0) } }

        let startedAt = Date()
        var spawned: pid_t = 0
        let rc = posix_spawn(&spawned, shell, &actions, &attr, argv, envp)
        close(fds[1])
        guard rc == 0 else {
            close(fds[0])
            throw LaunchError(detail: String(cString: strerror(rc)))
        }
        let pid = spawned
        let readEnd = fds[0]

        let run = RunState(limit: limit)
        // Read as it comes: a full pipe would block the command.
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global().async {
            run.read(readEnd)
            reader.leave()
        }
        // The time limit, unless the shell ended first (the pid could be
        // another process's by then).
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            guard run.markTimedOut() else { return }
            killpg(pid, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + killGrace) { killpg(pid, SIGKILL) }
        }

        let raw: Int32 = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var status: Int32 = 0
                while waitpid(pid, &status, 0) == -1, errno == EINTR {}
                // A child left behind holds the pipe open: a moment for what
                // it still says, then the reader is told to stop.
                _ = reader.wait(timeout: .now() + drainGrace)
                run.stop()
                continuation.resume(returning: status)
            }
        }
        let (text, truncated, timedOut) = run.snapshot()
        let seconds = Date().timeIntervalSince(startedAt)
        let low = raw & 0x7f
        if low == 0 { return ShellOutput(status: (raw >> 8) & 0xff, text: text, truncated: truncated, seconds: seconds) }
        // Killed: by the time limit, or by something else (128 + signal, as a shell reports it).
        return ShellOutput(status: timedOut ? nil : 128 + low, text: text, truncated: truncated, seconds: seconds)
    }

    /// The app's environment, with what a shell with no terminal needs:
    /// plain output, no colours (the phone shows the text as is).
    static func environment(shell: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = NSHomeDirectory()
        env["SHELL"] = shell
        env["TERM"] = "dumb"
        env["NO_COLOR"] = "1"
        env["DARRAOWL_REMOTE"] = "1"
        return env
    }
}

/// The output read so far, the end of it past the limit.
private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var total = 0
    private var timedOut = false
    private var stopping = false
    private let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    /// Reads until the pipe closes or `stop()` was called (then only what
    /// is already there). Closes the descriptor.
    func read(_ fd: Int32) {
        defer { close(fd) }
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let stopping = lock.withLock { self.stopping }
            var entry = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&entry, 1, stopping ? 0 : 500)
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            if ready == 0 {
                if stopping { return }
                continue
            }
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                append(chunk[..<n])
            } else if n == 0 || errno != EINTR {
                return
            }
        }
    }

    private func append(_ bytes: ArraySlice<UInt8>) {
        lock.withLock {
            total += bytes.count
            buffer.append(contentsOf: bytes)
            if buffer.count > 2 * limit { buffer = Data(buffer.suffix(limit)) }
        }
    }

    /// The time limit hit while the shell still ran: true, and the killing
    /// may begin. False once the shell has ended.
    func markTimedOut() -> Bool {
        lock.withLock {
            guard !stopping else { return false }
            timedOut = true
            return true
        }
    }

    /// The shell ended: no kill any more, and the reader takes what is
    /// there, then returns.
    func stop() {
        lock.withLock { stopping = true }
    }

    /// The text (the last `limit` bytes, from a character boundary), whether
    /// some was dropped, whether the time limit hit.
    func snapshot() -> (String, Bool, Bool) {
        lock.withLock {
            var tail = buffer.count > limit ? Data(buffer.suffix(limit)) : buffer
            if total > limit {
                // Not from the middle of a multi-byte character.
                while let first = tail.first, first & 0xC0 == 0x80 { tail = tail.dropFirst() }
            }
            return (String(decoding: tail, as: UTF8.self), total > limit, timedOut)
        }
    }
}
