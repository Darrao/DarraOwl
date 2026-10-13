@testable import DarraOwlCore
import DarraOwlShared
import Foundation
import Testing

@Suite struct AgentDetectorTests {
    let t = Date(timeIntervalSince1970: 1_800_000_000)

    func c(_ pid: Int32, _ ppid: Int32, _ name: String, _ args: [String] = [], cwd: String? = "/Users/me/Dev/DarraOwl", at: TimeInterval = 0) -> AgentDetector.Candidate {
        .init(pid: pid, ppid: ppid, name: name, arguments: args, cwd: cwd, startedAt: t.addingTimeInterval(at))
    }

    @Test func findsNativeAndNodeAgents() {
        let agents = AgentDetector.agents(in: [
            c(10, 1, "zsh"),
            c(11, 10, "claude", at: 1),
            c(12, 11, "claude", at: 2),               // helper of 11
            c(20, 1, "node", ["node", "/opt/homebrew/bin/gemini"], cwd: "/Users/me/Dev/site", at: 3),
            c(30, 1, "codex", cwd: "/", at: 4),
            c(40, 1, "node", ["node", "server.js"]),
        ])
        #expect(agents.map(\.tool) == ["claude", "gemini", "codex"])
        #expect(agents.map(\.project) == ["DarraOwl", "site", nil])
    }

    @Test func signalsAndMasking() {
        var s = AgentSignals()
        let a = AgentProcess(pid: 11, tool: "claude", cwd: "/Users/me/Dev/DarraOwl", startedAt: t)
        s.record(.waiting, cwd: "/Users/me/Dev/DarraOwl", at: t)
        #expect(s.states([a], now: t.addingTimeInterval(60), mask: false) == [MacState.Agent(tool: "claude", project: "DarraOwl", since: t, waitingForApproval: true, pid: 11)])
        #expect(s.states([a], now: t.addingTimeInterval(60), mask: true).first?.project == nil)
        s.record(.finished, cwd: "/Users/me/Dev/DarraOwl", at: t.addingTimeInterval(90))
        #expect(!s.isWaiting(cwd: a.cwd, now: t.addingTimeInterval(100)))
        s.record(.waiting, cwd: "/Users/me/Dev/DarraOwl", at: t)
        #expect(!s.isWaiting(cwd: a.cwd, now: t.addingTimeInterval(3600)), "stale after 30 min")
    }
}

@Suite struct ClaudeHookTests {
    @Test func parsesOnlyEventAndFolder() {
        let stop = Data(#"{"hook_event_name":"Stop","cwd":"/p/x","session_id":"s","transcript_path":"/secret"}"#.utf8)
        #expect(ClaudeHook.parse(stop) == .finished(cwd: "/p/x", asker: ClaudeHook.Asker(session: "s")))
        let note = Data(#"{"hook_event_name":"Notification","cwd":"/p/x","message":"Claude needs your permission to use Bash"}"#.utf8)
        #expect(ClaudeHook.parse(note) == .waiting(cwd: "/p/x", asker: ClaudeHook.Asker()))
        let inSubagent = Data(#"{"hook_event_name":"Notification","cwd":"/p/x","session_id":"s","agent_id":"a1"}"#.utf8)
        #expect(ClaudeHook.parse(inSubagent) == .waiting(cwd: "/p/x", asker: ClaudeHook.Asker(session: "s", agent: "a1")))
        #expect(ClaudeHook.parse(Data(#"{"hook_event_name":"PreToolUse"}"#.utf8)) == .ignored)
        #expect(ClaudeHook.parse(Data("nope".utf8)) == nil)
    }
}

@Suite struct LocalHTTPTests {
    func raw(_ s: String) -> Data { Data(s.utf8) }

    @Test func parsesCompleteRequest() {
        let body = #"{"hook_event_name":"Stop"}"#
        let r = LocalHTTP.parse(raw("POST /hooks/claude HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer t0k\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"))
        guard case let .request(req) = r else { Issue.record("not parsed"); return }
        #expect(req.method == "POST" && req.path == "/hooks/claude")
        #expect(String(decoding: req.body, as: UTF8.self) == body)
        #expect(LocalHTTP.authorized(req, token: "t0k"))
        #expect(!LocalHTTP.authorized(req, token: "t0K"))
    }

    @Test func waitsForTheBody() {
        #expect(LocalHTTP.parse(raw("POST / HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc")) == .incomplete)
        #expect(LocalHTTP.parse(raw("POST / HTTP/1.1\r\n")) == .incomplete)
    }

    @Test func refusesOversizeAndGarbage() {
        #expect(LocalHTTP.parse(raw("POST / HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n")) == .invalid)
        #expect(LocalHTTP.parse(raw("POST / HTTP/1.1\r\nContent-Length: 999999\r\n\r\n")) == .incomplete, "a big file Claude wants to write")
        #expect(LocalHTTP.parse(raw("hello\r\n\r\n")) == .invalid)
        #expect(LocalHTTP.parse(raw("POST / HTTP/1.1\r\nbad header\r\n\r\n")) == .invalid)
    }

    @Test func missingTokenIsRefused() {
        guard case let .request(req) = LocalHTTP.parse(raw("POST / HTTP/1.1\r\nContent-Length: 0\r\n\r\n")) else { return }
        #expect(!LocalHTTP.authorized(req, token: "x"))
    }
}

@Suite struct NativeInstallerAgentTests {
    let t = Date(timeIntervalSince1970: 1_800_000_000)

    /// Claude Code's native installer: the process is named after its version.
    @Test func aVersionNamedClaudeIsFound() {
        let c = AgentDetector.Candidate(pid: 10, ppid: 1, name: "2.1.220", arguments: ["claude", "--resume"], cwd: "/p/site",
                                        startedAt: t, path: "/Users/me/.local/share/claude/versions/2.1.220")
        #expect(AgentDetector.agents(in: [c]).map(\.tool) == ["claude"])
    }

    @Test func aVersionNamedProcessOfSomethingElseIsNot() {
        let c = AgentDetector.Candidate(pid: 11, ppid: 1, name: "3.12", arguments: ["python3.12"], cwd: nil,
                                        startedAt: t, path: "/opt/homebrew/Cellar/python/3.12/bin/3.12")
        #expect(AgentDetector.agents(in: [c]).isEmpty)
    }

    @Test(arguments: [("2.1.220", true), ("3.12", true), ("node", false), ("v2", false), ("1.", false), (".5", false), ("2..1", false)])
    func versionNames(name: String, expected: Bool) {
        #expect(AgentDetector.isVersionName(name) == expected)
    }
}

@Suite struct ClaudeNotificationTypeTests {
    func payload(_ type: String?) -> Data {
        var json = #"{"hook_event_name":"Notification","cwd":"/p/x""#
        if let type { json += #","notification_type":"\#(type)""# }
        return Data((json + "}").utf8)
    }

    @Test func onlyQuestionsCountAsWaiting() {
        #expect(ClaudeHook.parse(payload("permission_prompt")) == .waiting(cwd: "/p/x", asker: ClaudeHook.Asker()))
        #expect(ClaudeHook.parse(payload("elicitation_dialog")) == .waiting(cwd: "/p/x", asker: ClaudeHook.Asker()))
        #expect(ClaudeHook.parse(payload("idle_prompt")) == .ignored)
        #expect(ClaudeHook.parse(payload("auth_success")) == .ignored)
        #expect(ClaudeHook.parse(payload(nil)) == .waiting(cwd: "/p/x", asker: ClaudeHook.Asker()), "older versions send no type")
    }
}

@Suite struct AgentHelperModeTests {
    let t = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func theChromeBridgeAndMCPServersAreNotSessions() {
        let bridge = AgentDetector.Candidate(pid: 20, ppid: 1, name: "2.1.220", arguments: ["/Users/me/.local/share/claude/versions/2.1.220", "--chrome-native-host"],
                                             cwd: "/", startedAt: t, path: "/Users/me/.local/share/claude/versions/2.1.220")
        let mcp = AgentDetector.Candidate(pid: 21, ppid: 1, name: "claude", arguments: ["claude", "mcp", "serve"], cwd: "/p", startedAt: t)
        let session = AgentDetector.Candidate(pid: 22, ppid: 1, name: "claude", arguments: ["claude"], cwd: "/p/site", startedAt: t)
        #expect(AgentDetector.agents(in: [bridge, mcp, session]).map(\.pid) == [22])
    }

    @Test func anNpmInstalledMCPServerIsNotASession() {
        let mcp = AgentDetector.Candidate(pid: 30, ppid: 1, name: "node", arguments: ["node", "/opt/homebrew/bin/claude", "mcp", "serve"], cwd: "/p", startedAt: t)
        let prompt = AgentDetector.Candidate(pid: 31, ppid: 1, name: "claude", arguments: ["claude", "-p", "mcp"], cwd: "/p", startedAt: t)
        #expect(AgentDetector.agents(in: [mcp, prompt]).map(\.pid) == [31], "a prompt that says mcp is still a session")
    }
}
