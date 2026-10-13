import DarraOwlShared
import Foundation

/// A coding agent process found on the Mac.
public struct AgentProcess: Equatable, Sendable {
    public var pid: Int32
    public var tool: String
    /// Working directory, read from the process; only its last component is ever shown.
    public var cwd: String?
    public var startedAt: Date

    public init(pid: Int32, tool: String, cwd: String?, startedAt: Date) {
        self.pid = pid
        self.tool = tool
        self.cwd = cwd
        self.startedAt = startedAt
    }

    public var project: String? {
        cwd.map { URL(fileURLWithPath: $0).lastPathComponent }.flatMap { $0.isEmpty || $0 == "/" ? nil : $0 }
    }
}

/// Recognises agents from process names and arguments. Pure.
public enum AgentDetector {
    public static let tools = ["claude", "codex", "gemini"]

    public struct Candidate: Sendable {
        public var pid: Int32
        public var ppid: Int32
        /// p_comm, the executable name (16 chars max).
        public var name: String
        /// argv, when readable.
        public var arguments: [String]
        public var cwd: String?
        public var startedAt: Date
        /// The executable's path, when read.
        public var path: String?

        public init(pid: Int32, ppid: Int32, name: String, arguments: [String], cwd: String?, startedAt: Date, path: String? = nil) {
            self.pid = pid
            self.ppid = ppid
            self.name = name
            self.arguments = arguments
            self.cwd = cwd
            self.startedAt = startedAt
            self.path = path
        }
    }

    /// A process name that is a version number: Claude Code's native
    /// installer runs `~/.local/share/claude/versions/2.1.220`, so the
    /// kernel names the process "2.1.220".
    public static func isVersionName(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    /// Helper modes of an agent's binary that are not a coding session: the
    /// Chrome bridge (`--chrome-native-host`) and MCP servers (`claude mcp …`,
    /// or `node …/claude mcp …` for an npm install).
    static func isHelperMode(_ arguments: [String]) -> Bool {
        if arguments.contains("--chrome-native-host") { return true }
        if arguments.dropFirst().first == "mcp" { return true }
        return arguments.count > 2 && arguments[2] == "mcp" && arguments[1].contains("/")
    }

    /// The tool a process is, or nil. Node-based CLIs run as `node <path>/gemini`.
    public static func tool(of c: Candidate) -> String? {
        if isHelperMode(c.arguments) { return nil }
        if tools.contains(c.name) { return c.name }
        if isVersionName(c.name) {
            for tool in tools {
                if c.path?.contains("/\(tool)/versions/") == true { return tool }
                if let argv0 = c.arguments.first, URL(fileURLWithPath: argv0).lastPathComponent == tool { return tool }
            }
            return nil
        }
        guard c.name == "node" || c.name.hasPrefix("node") || c.name == "bun" else { return nil }
        for arg in c.arguments.prefix(3) {
            let base = URL(fileURLWithPath: arg).lastPathComponent
            if tools.contains(base) { return base }
            if arg.contains("@google/gemini-cli") { return "gemini" }
            if arg.contains("@openai/codex") { return "codex" }
            if arg.contains("@anthropic-ai/claude-code") { return "claude" }
        }
        return nil
    }

    /// One entry per agent: a process whose parent is the same tool is a
    /// helper of that agent, not another one.
    public static func agents(in candidates: [Candidate]) -> [AgentProcess] {
        let byPID = Dictionary(candidates.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [AgentProcess] = []
        for c in candidates {
            guard let tool = tool(of: c) else { continue }
            if let parent = byPID[c.ppid], Self.tool(of: parent) == tool { continue }
            out.append(AgentProcess(pid: c.pid, tool: tool, cwd: c.cwd, startedAt: c.startedAt))
        }
        return out.sorted { $0.startedAt < $1.startedAt }
    }
}

/// What a Claude Code hook told us, keyed by project folder.
public struct AgentSignals: Sendable {
    public enum Signal: Equatable, Sendable {
        case waiting
        case finished
    }

    private var byProject: [String: (Signal, Date)] = [:]

    public init() {}

    public mutating func record(_ signal: Signal, cwd: String, at date: Date) {
        byProject[cwd] = (signal, date)
    }

    /// A new turn starts when the agent works again: a stale "waiting" goes
    /// away after 30 min.
    public func isWaiting(cwd: String?, now: Date) -> Bool {
        guard let cwd, let (signal, at) = byProject[cwd] else { return false }
        return signal == .waiting && now.timeIntervalSince(at) < 1800
    }

    /// Agents as the phone sees them; project names masked on request.
    public func states(_ agents: [AgentProcess], now: Date, mask: Bool) -> [MacState.Agent] {
        agents.map {
            MacState.Agent(tool: $0.tool, project: mask ? nil : $0.project, since: $0.startedAt,
                           waitingForApproval: isWaiting(cwd: $0.cwd, now: now), pid: $0.pid)
        }
    }
}

/// Claude Code HTTP hook payloads. Read: the event name, its type, the
/// folder and who asked; for a permission request, the tool and what it
/// would do. The prompt, transcript and answers are ignored (safety rule 8).
public enum ClaudeHook {
    public struct Payload: Decodable, Sendable {
        public var hook_event_name: String
        public var cwd: String?
        /// "permission_prompt", "elicitation_dialog", "idle_prompt",
        /// "auth_success"… Absent in older Claude Code versions.
        public var notification_type: String?
        /// PermissionRequest: the tool Claude wants to use.
        public var tool_name: String?
        public var session_id: String?
        /// Set when the hook fires inside a subagent.
        public var agent_id: String?
    }

    /// Which Claude sent a hook: its session, and the subagent in it (nil
    /// for the main agent). Older versions send neither.
    public struct Asker: Hashable, Sendable {
        public var session: String?
        public var agent: String?

        public init(session: String? = nil, agent: String? = nil) {
            self.session = session
            self.agent = agent
        }
    }

    /// Claude is about to ask for a permission.
    public struct Permission: Equatable, Sendable {
        public var tool: String
        /// What it wants to do, in full: the command, the file, the address…
        public var detail: String
        public var cwd: String?
        public var asker: Asker

        public init(tool: String, detail: String, cwd: String?, asker: Asker = Asker()) {
            self.tool = tool
            self.detail = detail
            self.cwd = cwd
            self.asker = asker
        }
    }

    /// Notifications that mean Claude needs the user to answer.
    static let waitingTypes: Set<String> = ["permission_prompt", "elicitation_dialog"]

    /// Tools that Claude Code only lets its own dialog answer: a hook's bare
    /// "allow" is ignored for them (a question, a plan to approve).
    static let dialogOnlyTools: Set<String> = ["AskUserQuestion", "ExitPlanMode", "ShowOnboardingRolePicker"]

    public enum Parsed: Equatable, Sendable {
        case finished(cwd: String?, asker: Asker)
        case waiting(cwd: String?, asker: Asker)
        case permission(Permission)
        case ignored
    }

    public static func parse(_ body: Data) -> Parsed? {
        guard let p = try? JSONDecoder().decode(Payload.self, from: body) else { return nil }
        let asker = Asker(session: p.session_id, agent: p.agent_id)
        switch p.hook_event_name {
        case "PermissionRequest":
            guard let tool = p.tool_name, !tool.isEmpty, !dialogOnlyTools.contains(tool) else { return .ignored }
            let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            let input = root?["tool_input"] as? [String: Any] ?? [:]
            return .permission(Permission(tool: tool, detail: AgentApprovals.describe(tool: tool, input: input), cwd: p.cwd, asker: asker))
        case "Stop": return .finished(cwd: p.cwd, asker: asker)
        case "Notification":
            // "idle_prompt" (a minute after a finished turn) is not a question.
            guard let type = p.notification_type else { return .waiting(cwd: p.cwd, asker: asker) }
            return waitingTypes.contains(type) ? .waiting(cwd: p.cwd, asker: asker) : .ignored
        default: return .ignored
        }
    }
}

/// The local hook endpoint's HTTP, minimal and strict: POST, one path, a
/// bearer token compared in constant time, a small body. Pure.
public enum LocalHTTP {
    /// A permission request carries the tool's whole input: a file Claude
    /// wants to write, for one.
    public static let maxBody = 8 * 1024 * 1024

    public struct Request: Equatable, Sendable {
        public var method: String
        public var path: String
        public var headers: [String: String]
        public var body: Data
    }

    public enum ParseResult: Equatable, Sendable {
        case incomplete
        case invalid
        case request(Request)
    }

    public static func parse(_ data: Data) -> ParseResult {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > 16 * 1024 ? .invalid : .incomplete
        }
        guard let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return .invalid }
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count == 3, start[2].hasPrefix("HTTP/1.") else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard (0...maxBody).contains(length) else { return .invalid }
        let body = data[headerEnd.upperBound...]
        guard body.count >= length else { return .incomplete }
        return .request(Request(method: String(start[0]), path: String(start[1]), headers: headers, body: Data(body.prefix(length))))
    }

    public static func authorized(_ r: Request, token: String) -> Bool {
        guard let value = r.headers["authorization"], value.hasPrefix("Bearer ") else { return false }
        let given = Array(value.dropFirst(7).utf8)
        let expected = Array(token.utf8)
        guard given.count == expected.count else { return false }
        return zip(given, expected).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// `body`: a JSON object, "{}" for "nothing to say".
    public static func response(_ status: Int, _ text: String, body: Data = Data("{}".utf8)) -> Data {
        Data("HTTP/1.1 \(status) \(text)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
    }
}
