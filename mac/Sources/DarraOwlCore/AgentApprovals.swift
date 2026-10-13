import DarraOwlShared
import Foundation

/// Claude Code's permission requests, answered from the phone while nobody
/// is at the Mac. A request waits for the phone, the user coming back to the
/// Mac, the hook's connection closing, or about an hour; anything but an
/// answer leaves Claude to ask in the terminal, as without DarraOwl.
@MainActor
public final class AgentApprovals {
    public enum Decision: Equatable, Sendable {
        case allow
        case deny
    }

    public enum Change: Equatable, Sendable {
        case added(MacState.AgentRequest)
        case removed(UUID)
    }

    /// Just under the hook's own timeout: the answer still reaches Claude.
    public nonisolated static let waitLimit = TimeInterval(ClaudeHookConfig.permissionTimeout - 30)
    /// What the phone shows of a request, at most.
    public nonisolated static let detailLimit = 300

    public private(set) var pending: [MacState.AgentRequest] = []
    /// A request appeared or went: the state is published again, the
    /// notification posted or removed.
    public var onChange: ((Change) -> Void)?

    private var waiters: [UUID: CheckedContinuation<Decision?, Never>] = [:]
    private let clock: any NowProviding
    private let sleep: @Sendable (TimeInterval) async -> Void

    public init(clock: any NowProviding, sleep: @escaping @Sendable (TimeInterval) async -> Void) {
        self.clock = clock
        self.sleep = sleep
    }

    /// Waits for the phone's answer to request `id`. Nil: no answer, Claude
    /// asks in the terminal.
    public func decide(id: UUID, tool: String, detail: String, project: String?) async -> Decision? {
        await withCheckedContinuation { continuation in
            waiters[id] = continuation
            let request = MacState.AgentRequest(id: id, tool: tool, detail: detail, project: project, at: clock.now())
            pending.append(request)
            onChange?(.added(request))
            let sleep = self.sleep
            Task { [weak self] in
                await sleep(Self.waitLimit)
                self?.resolve(id, nil)
            }
        }
    }

    /// The phone's answer. False: nothing waits for it any more.
    @discardableResult
    public func answer(_ id: UUID, allow: Bool) -> Bool {
        resolve(id, allow ? .allow : .deny)
    }

    /// The hook's connection went away: answered in the terminal, Claude quit.
    public func withdraw(_ id: UUID) {
        resolve(id, nil)
    }

    /// Back at the Mac: every request goes to the terminal.
    public func releaseAll() {
        for id in Array(waiters.keys) { resolve(id, nil) }
    }

    @discardableResult
    private func resolve(_ id: UUID, _ decision: Decision?) -> Bool {
        guard let waiter = waiters.removeValue(forKey: id) else { return false }
        pending.removeAll { $0.id == id }
        onChange?(.removed(id))
        waiter.resume(returning: decision)
        return true
    }

    /// What Claude wants to do, as the phone shows it: the command, the
    /// file, the address, else the tool's input; cut short.
    public nonisolated static func detail(tool: String, input: [String: Any]) -> String {
        func field(_ key: String) -> String? {
            (input[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        let text: String
        switch tool {
        case "Bash": text = field("command") ?? ""
        case "Edit", "MultiEdit", "Write", "Read", "NotebookEdit": text = field("file_path") ?? field("notebook_path") ?? ""
        case "WebFetch": text = field("url") ?? ""
        case "WebSearch": text = field("query") ?? ""
        case "Glob", "Grep": text = field("pattern") ?? ""
        default:
            let data = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
            text = input.isEmpty ? "" : String(decoding: data, as: UTF8.self)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > detailLimit ? String(trimmed.prefix(detailLimit - 1)) + "…" : trimmed
    }

    /// The hook's answer to Claude Code: a decision, or "{}" for none.
    public nonisolated static func hookAnswer(_ decision: Decision?) -> Data {
        guard let decision else { return Data("{}".utf8) }
        var inner: [String: Any] = ["behavior": decision == .allow ? "allow" : "deny"]
        if decision == .deny { inner["message"] = "Refusé depuis l'iPhone." }
        let body: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": inner]]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}
