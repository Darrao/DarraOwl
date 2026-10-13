import DarraOwlShared
import Foundation

/// Claude Code's permission requests, answered from the phone while nobody
/// is at the Mac. A request waits for the phone, the user coming back to the
/// Mac, the hook's connection closing, the end of its session's turn, or
/// about an hour; anything but an answer leaves Claude to ask in the
/// terminal, as without DarraOwl.
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

    private struct Waiter {
        var continuation: CheckedContinuation<Decision?, Never>
        var asker: ClaudeHook.Asker
        var cwd: String?
    }

    private var waiters: [UUID: Waiter] = [:]
    private let clock: any NowProviding
    private let sleep: @Sendable (TimeInterval) async -> Void

    public init(clock: any NowProviding, sleep: @escaping @Sendable (TimeInterval) async -> Void) {
        self.clock = clock
        self.sleep = sleep
    }

    /// Waits for the phone's answer to request `id`. Nil: no answer, Claude
    /// asks in the terminal.
    public func decide(id: UUID, tool: String, detail: String, project: String?,
                       asker: ClaudeHook.Asker = ClaudeHook.Asker(), cwd: String? = nil) async -> Decision? {
        await withCheckedContinuation { continuation in
            waiters[id] = Waiter(continuation: continuation, asker: asker, cwd: cwd)
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

    /// The hook's connection went away: Claude was interrupted, or quit.
    public func withdraw(_ id: UUID) {
        resolve(id, nil)
    }

    /// Back at the Mac: every request goes to the terminal.
    public func releaseAll() {
        for id in Array(waiters.keys) { resolve(id, nil) }
    }

    /// `asker` ended its turn: it waits for none of its requests any more
    /// (answered in a terminal over SSH, from another device…).
    public func finished(_ asker: ClaudeHook.Asker) {
        guard asker.session != nil else { return }
        for (id, waiter) in waiters where waiter.asker == asker { resolve(id, nil) }
    }

    /// A request of this session (without one, of this folder) waits for
    /// the phone: Claude's own "waiting" notification would say it twice.
    public func waits(_ asker: ClaudeHook.Asker, cwd: String?) -> Bool {
        if let session = asker.session { return waiters.values.contains { $0.asker.session == session } }
        guard let cwd else { return false }
        return waiters.values.contains { $0.cwd == cwd }
    }

    @discardableResult
    private func resolve(_ id: UUID, _ decision: Decision?) -> Bool {
        guard let waiter = waiters.removeValue(forKey: id) else { return false }
        pending.removeAll { $0.id == id }
        onChange?(.removed(id))
        waiter.continuation.resume(returning: decision)
        return true
    }

    /// What Claude wants to do: the command, the file, the address, else
    /// the tool's input.
    public nonisolated static func describe(tool: String, input: [String: Any]) -> String {
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
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What the phone shows of `detail`: with project names masked, the
    /// project's folder becomes "." and its name "[projet]"; cut short.
    public nonisolated static func shown(_ detail: String, cwd: String?, mask: Bool) -> String {
        var text = detail
        if mask, let cwd {
            let folder = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
            let name = URL(fileURLWithPath: folder).lastPathComponent
            if !folder.isEmpty, folder != "/" {
                // The folder itself: "/x/api-old" is another one.
                text = replacing(folder, in: text, with: ".", notAfter: nil, notBefore: #"\p{L}\p{N}_.-"#, ignoringCase: false)
            }
            if !name.isEmpty, name != "/" {
                // The name as a word of its own, in any case: project "api"
                // leaves "rapid" alone.
                text = replacing(name, in: text, with: "[projet]", notAfter: #"\p{L}\p{N}_-"#, notBefore: #"\p{L}\p{N}_-"#, ignoringCase: true)
            }
        }
        return text.count > detailLimit ? String(text.prefix(detailLimit - 1)) + "…" : text
    }

    private nonisolated static func replacing(_ literal: String, in text: String, with replacement: String,
                                              notAfter: String?, notBefore: String, ignoringCase: Bool) -> String {
        var pattern = NSRegularExpression.escapedPattern(for: literal) + "(?![\(notBefore)])"
        if let notAfter { pattern = "(?<![\(notAfter)])" + pattern }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: ignoringCase ? [.caseInsensitive] : []) else { return text }
        let template = NSRegularExpression.escapedTemplate(for: replacement)
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
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
