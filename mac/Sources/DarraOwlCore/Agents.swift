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

        public init(pid: Int32, ppid: Int32, name: String, arguments: [String], cwd: String?, startedAt: Date) {
            self.pid = pid
            self.ppid = ppid
            self.name = name
            self.arguments = arguments
            self.cwd = cwd
            self.startedAt = startedAt
        }
    }

    /// The tool a process is, or nil. Node-based CLIs run as `node <path>/gemini`.
    public static func tool(of c: Candidate) -> String? {
        if tools.contains(c.name) { return c.name }
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

/// Claude Code HTTP hook payloads. Only the event name and the folder are
/// read: the message, prompt and transcript are ignored (safety rule 8).
public enum ClaudeHook {
    public struct Payload: Decodable, Sendable {
        public var hook_event_name: String
        public var cwd: String?
    }

    public enum Parsed: Equatable, Sendable {
        case finished(cwd: String?)
        case waiting(cwd: String?)
        case ignored
    }

    public static func parse(_ body: Data) -> Parsed? {
        guard let p = try? JSONDecoder().decode(Payload.self, from: body) else { return nil }
        switch p.hook_event_name {
        case "Stop": return .finished(cwd: p.cwd)
        case "Notification": return .waiting(cwd: p.cwd)
        default: return .ignored
        }
    }
}

/// The local hook endpoint's HTTP, minimal and strict: POST, one path, a
/// bearer token compared in constant time, a small body. Pure.
public enum LocalHTTP {
    public static let maxBody = 64 * 1024

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

    public static func response(_ status: Int, _ text: String) -> Data {
        let body = Data("{}".utf8)
        return Data("HTTP/1.1 \(status) \(text)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
    }
}
