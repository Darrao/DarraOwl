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
/// a time limit. Past the limit the process gets SIGTERM.
public enum ProcessRunner {
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

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { p in
                let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                continuation.resume(returning: ProcessResult(status: p.terminationStatus, stdout: stdout, stderr: stderr))
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: ProcessError(command: command, detail: error.localizedDescription))
                return
            }
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning, process.processIdentifier == pid {
                    process.terminate()
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
