import Foundation

public struct ProcessResult: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
}

public struct ProcessError: Error, LocalizedError, Sendable {
    public let command: String
    public let detail: String
    public var errorDescription: String? { "\(command) : \(detail)" }
}

/// Runs a fixed executable with fixed arguments, never through a shell, with
/// a time limit. Past the limit the process gets SIGTERM, then SIGKILL, and
/// the caller gets an error whatever the process does: the helper's single
/// request lane never waits on a stuck command.
public enum ProcessRunner {
    /// Between SIGTERM and SIGKILL.
    static let killGrace: TimeInterval = 2

    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 20) async throws -> ProcessResult {
        let command = ([executable] + arguments).joined(separator: " ")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        let run = RunState()

        return try await withCheckedThrowingContinuation { continuation in
            run.set(continuation)
            process.terminationHandler = { p in
                let status = p.terminationStatus
                DispatchQueue.global().async {
                    // The output is read while the process runs (a full pipe
                    // would block it); give the readers a moment to finish.
                    _ = run.readers.wait(timeout: .now() + 1)
                    let (stdout, stderr) = run.output()
                    run.finish(.success(ProcessResult(status: status, stdout: stdout, stderr: stderr)))
                }
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                run.finish(.failure(ProcessError(command: command, detail: error.localizedDescription)))
                return
            }
            run.read(out.fileHandleForReading, isError: false)
            run.read(err.fileHandleForReading, isError: true)
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning, process.processIdentifier == pid else { return }
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + killGrace) {
                    if process.isRunning, process.processIdentifier == pid { kill(pid, SIGKILL) }
                    run.finish(.failure(ProcessError(command: command, detail: "pas de réponse en \(Int(timeout)) s")))
                }
            }
        }
    }

    /// Runs and throws unless the exit status is 0.
    @discardableResult
    public static func runChecked(_ executable: String, _ arguments: [String], timeout: TimeInterval = 20) async throws -> String {
        let r = try await run(executable, arguments, timeout: timeout)
        guard r.status == 0 else {
            let command = ([executable] + arguments).joined(separator: " ")
            let detail = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ProcessError(command: command, detail: "code \(r.status)\(detail.isEmpty ? "" : ", \(detail)")")
        }
        return r.stdout
    }
}

/// One run's output and its continuation, resumed once whichever of the
/// exit and the time limit comes first.
private final class RunState: @unchecked Sendable {
    let readers = DispatchGroup()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ProcessResult, Error>?
    private var stdout = Data()
    private var stderr = Data()

    func set(_ continuation: CheckedContinuation<ProcessResult, Error>) {
        lock.withLock { self.continuation = continuation }
    }

    func read(_ handle: FileHandle, isError: Bool) {
        readers.enter()
        DispatchQueue.global().async {
            let data = handle.readDataToEndOfFile()
            self.lock.withLock {
                if isError { self.stderr = data } else { self.stdout = data }
            }
            self.readers.leave()
        }
    }

    func output() -> (String, String) {
        lock.withLock { (String(decoding: stdout, as: UTF8.self), String(decoding: stderr, as: UTF8.self)) }
    }

    func finish(_ result: Result<ProcessResult, Error>) {
        let c: CheckedContinuation<ProcessResult, Error>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        c?.resume(with: result)
    }
}
