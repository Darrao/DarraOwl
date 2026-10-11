import Foundation

/// Stops an agent from the phone: SIGINT, what Ctrl-C sends, then SIGTERM
/// if it is still there after a few seconds. Only the process that was
/// checked is signalled: a pid now used by another process is left alone.
@MainActor
public struct AgentStopper {
    public enum Outcome: Equatable, Sendable {
        case stopped
        case stillRunning
    }

    public static let grace: Duration = .seconds(3)

    let processes: any ProcessControlling
    let sleep: (Duration) async -> Void

    public init(processes: any ProcessControlling, sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.processes = processes
        self.sleep = sleep
    }

    public func stop(pid: Int32, identity: ProcessIdentity) async -> Outcome {
        for signal in [SIGINT, SIGTERM] {
            guard isTheSame(pid, identity) else { return .stopped }
            _ = processes.signal(pid, signal)
            await sleep(Self.grace)
        }
        return isTheSame(pid, identity) ? .stillRunning : .stopped
    }

    private func isTheSame(_ pid: Int32, _ identity: ProcessIdentity) -> Bool {
        guard case let .present(state) = processes.lookup(pid) else { return false }
        return state.identity == identity
    }
}
