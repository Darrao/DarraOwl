@testable import DarraOwlCore
import DarraOwlShared
import Foundation
import Testing

/// Claude Code's permission requests, answered from the phone.
@MainActor
@Suite struct AgentApprovalsTests {
    let clock = FakeClock()

    /// A wait that only ends when the test says so (or never).
    func approvals(waitGate: AsyncGate? = nil) -> AgentApprovals {
        AgentApprovals(clock: clock) { _ in
            if let waitGate { await waitGate.pass() } else { try? await Task.sleep(for: .seconds(3600)) }
        }
    }

    @Test func thePhonesAnswerIsClaudesDecision() async {
        let a = approvals()
        var changes: [AgentApprovals.Change] = []
        a.onChange = { changes.append($0) }
        let id = UUID()
        let waiting = Task { await a.decide(id: id, tool: "Bash", detail: "npm test", project: "portfolio") }
        while a.pending.isEmpty { await Task.yield() }
        #expect(a.pending.map(\.id) == [id])
        #expect(a.pending.first?.detail == "npm test")
        #expect(a.answer(id, allow: true))
        #expect(await waiting.value == .allow)
        #expect(a.pending.isEmpty)
        #expect(changes.count == 2)
        #expect(!a.answer(id, allow: false), "answered once")
    }

    @Test func refusedGivesDeny() async {
        let a = approvals()
        let id = UUID()
        let waiting = Task { await a.decide(id: id, tool: "Bash", detail: "rm -rf build", project: nil) }
        while a.pending.isEmpty { await Task.yield() }
        a.answer(id, allow: false)
        #expect(await waiting.value == .deny)
    }

    /// Back at the Mac, Claude's connection closing, or the wait limit:
    /// no decision, Claude asks in the terminal.
    @Test func withoutAnAnswerClaudeAsksInTheTerminal() async {
        let a = approvals()
        let first = UUID(), second = UUID()
        let one = Task { await a.decide(id: first, tool: "Bash", detail: "ls", project: nil) }
        let two = Task { await a.decide(id: second, tool: "Write", detail: "/tmp/x", project: nil) }
        while a.pending.count < 2 { await Task.yield() }
        a.withdraw(first)
        #expect(await one.value == nil)
        a.releaseAll()
        #expect(await two.value == nil)
        #expect(a.pending.isEmpty)

        let gate = AsyncGate()
        let timed = approvals(waitGate: gate)
        let late = Task { await timed.decide(id: UUID(), tool: "Bash", detail: "make", project: nil) }
        await gate.waitUntilEntered()
        gate.open()
        #expect(await late.value == nil)
        #expect(timed.pending.isEmpty)
    }

    @Test func theDetailIsWhatClaudeWouldDoCutShort() {
        #expect(AgentApprovals.describe(tool: "Bash", input: ["command": "  npm run build\n", "description": "Build"]) == "npm run build")
        #expect(AgentApprovals.describe(tool: "Edit", input: ["file_path": "/Users/me/app/main.swift", "new_string": "secret"]) == "/Users/me/app/main.swift")
        #expect(AgentApprovals.describe(tool: "WebFetch", input: ["url": "https://example.com"]) == "https://example.com")
        #expect(AgentApprovals.describe(tool: "mcp__x__y", input: ["b": 1, "a": "z"]) == #"{"a":"z","b":1}"#)
        let long = AgentApprovals.shown(String(repeating: "x", count: 1000), cwd: nil, mask: false)
        #expect(long.count == AgentApprovals.detailLimit)
        #expect(long.hasSuffix("…"))
        #expect(AgentApprovals.shown("cd /Users/me/Dev/api && npm test", cwd: "/Users/me/Dev/api", mask: false) == "cd /Users/me/Dev/api && npm test")
    }

    /// "Masquer les noms de projets" covers the detail too: the project's
    /// folder and its name, not other words that contain it.
    @Test func maskedProjectNamesLeaveTheDetail() {
        let cwd = "/Users/me/Dev/api"
        #expect(AgentApprovals.shown("cat /Users/me/Dev/api/src/main.ts", cwd: cwd, mask: true) == "cat ./src/main.ts")
        #expect(AgentApprovals.shown("cd ~/Dev/API && npm run rapid", cwd: cwd + "/", mask: true) == "cd ~/Dev/[projet] && npm run rapid")
        #expect(AgentApprovals.shown("ls /Users/me/Dev/api-old", cwd: cwd, mask: true) == "ls /Users/me/Dev/api-old")
        #expect(AgentApprovals.shown("git clone x/api.git", cwd: cwd, mask: true) == "git clone x/[projet].git")
        #expect(AgentApprovals.shown("echo $1 \\1", cwd: "/p/$1", mask: true) == "echo [projet] \\1", "no regex nor template syntax")
    }

    /// The questions and plans of Claude: its dialog alone answers them, a
    /// hook's "allow" would be ignored.
    @Test func questionsAndPlansStayInTheTerminal() {
        for tool in ["AskUserQuestion", "ExitPlanMode"] {
            let body = Data(#"{"hook_event_name":"PermissionRequest","cwd":"/p","tool_name":"\#(tool)","tool_input":{}}"#.utf8)
            #expect(ClaudeHook.parse(body) == .ignored)
        }
    }

    /// A session that ended its turn waits for none of its requests; a
    /// subagent's request is its own.
    @Test func aFinishedTurnTakesItsRequestsBack() async {
        let a = approvals()
        let main = ClaudeHook.Asker(session: "s1"), sub = ClaudeHook.Asker(session: "s1", agent: "a1")
        let first = Task { await a.decide(id: UUID(), tool: "Bash", detail: "ls", project: nil, asker: main, cwd: "/p") }
        let second = Task { await a.decide(id: UUID(), tool: "Bash", detail: "make", project: nil, asker: sub, cwd: "/p") }
        let other = Task { await a.decide(id: UUID(), tool: "Bash", detail: "pwd", project: nil, asker: ClaudeHook.Asker(session: "s2"), cwd: "/q") }
        while a.pending.count < 3 { await Task.yield() }
        #expect(a.waits(ClaudeHook.Asker(session: "s1"), cwd: nil))
        #expect(!a.waits(ClaudeHook.Asker(session: "s3"), cwd: "/p"), "another session's notification is not one of these")
        #expect(a.waits(ClaudeHook.Asker(), cwd: "/q"), "without a session, by folder")
        #expect(!a.waits(ClaudeHook.Asker(), cwd: nil))
        a.finished(ClaudeHook.Asker())
        #expect(a.pending.count == 3, "a hook without a session takes nothing back")
        a.finished(main)
        #expect(await first.value == nil)
        #expect(a.pending.count == 2)
        a.finished(sub)
        #expect(await second.value == nil)
        a.releaseAll()
        #expect(await other.value == nil)
    }

    /// A foreground subagent's request outlives the main agent's Stop, which
    /// names no subagent: its own end (SubagentStop) takes it back, and only it.
    @Test func aSubagentsEndTakesOnlyItsRequestBack() async {
        let a = approvals()
        let mainID = UUID(), subID = UUID(), otherID = UUID()
        let fromMain = Task { await a.decide(id: mainID, tool: "Bash", detail: "ls", project: nil, asker: ClaudeHook.Asker(session: "s1"), cwd: "/p") }
        let fromSub = Task { await a.decide(id: subID, tool: "Bash", detail: "make", project: nil, asker: ClaudeHook.Asker(session: "s1", agent: "a1"), cwd: "/p") }
        let fromOther = Task { await a.decide(id: otherID, tool: "Bash", detail: "pwd", project: nil, asker: ClaudeHook.Asker(session: "s1", agent: "a2"), cwd: "/p") }
        while a.pending.count < 3 { await Task.yield() }
        let end = Data(#"{"hook_event_name":"SubagentStop","cwd":"/p","session_id":"s1","agent_id":"a1"}"#.utf8)
        guard case let .subagentFinished(asker)? = ClaudeHook.parse(end) else {
            Issue.record("SubagentStop not read")
            a.releaseAll()
            return
        }
        a.finished(asker)
        #expect(await fromSub.value == nil)
        #expect(Set(a.pending.map(\.id)) == [mainID, otherID])
        a.releaseAll()
        #expect(await fromMain.value == nil)
        #expect(await fromOther.value == nil)
    }

    @Test func claudeGetsADecisionOrNothing() throws {
        let allow = try JSONSerialization.jsonObject(with: AgentApprovals.hookAnswer(.allow)) as? [String: Any]
        let output = allow?["hookSpecificOutput"] as? [String: Any]
        #expect(output?["hookEventName"] as? String == "PermissionRequest")
        #expect((output?["decision"] as? [String: Any])?["behavior"] as? String == "allow")
        let deny = try JSONSerialization.jsonObject(with: AgentApprovals.hookAnswer(.deny)) as? [String: Any]
        let denied = (deny?["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        #expect(denied?["behavior"] as? String == "deny")
        #expect(denied?["message"] as? String != nil)
        #expect(AgentApprovals.hookAnswer(nil) == Data("{}".utf8))
    }

    @Test func aPermissionRequestHookIsRead() {
        let body = Data(#"{"hook_event_name":"PermissionRequest","cwd":"/Users/me/portfolio","tool_name":"Bash","tool_input":{"command":"git push"}}"#.utf8)
        #expect(ClaudeHook.parse(body) == .permission(ClaudeHook.Permission(tool: "Bash", detail: "git push", cwd: "/Users/me/portfolio")))
        let withSession = Data(#"{"hook_event_name":"PermissionRequest","session_id":"s","agent_id":"a","tool_name":"Write","tool_input":{"file_path":"/x","content":"…"}}"#.utf8)
        #expect(ClaudeHook.parse(withSession) == .permission(ClaudeHook.Permission(tool: "Write", detail: "/x", cwd: nil, asker: ClaudeHook.Asker(session: "s", agent: "a"))))
        let noTool = Data(#"{"hook_event_name":"PermissionRequest"}"#.utf8)
        #expect(ClaudeHook.parse(noTool) == .ignored)
    }

    /// The permission hook waits an hour; an install of the two older hooks
    /// alone is out of date.
    @Test func thePermissionHookIsInstalledWithItsOwnTimeout() throws {
        let installed = try ClaudeHookConfig.install(nil, port: 52_526, token: "t")
        let root = try JSONSerialization.jsonObject(with: installed) as? [String: Any]
        let hooks = root?["hooks"] as? [String: Any]
        let permission = ((hooks?["PermissionRequest"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first
        #expect(permission?["timeout"] as? Int == ClaudeHookConfig.permissionTimeout)
        let stop = ((hooks?["Stop"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first
        #expect(stop?["timeout"] as? Int == 5)
        #expect(ClaudeHookConfig.state(installed, port: 52_526, token: "t") == .installed)

        let entry: [String: Any] = ["type": "http", "url": ClaudeHookConfig.url(port: 52_526), "timeout": 5, "headers": ["Authorization": "Bearer t"]]
        let older: [String: Any] = ["hooks": ["Stop": [["hooks": [entry]]], "Notification": [["hooks": [entry]]]]]
        let olderData = try JSONSerialization.data(withJSONObject: older)
        #expect(ClaudeHookConfig.state(olderData, port: 52_526, token: "t") == .outdated)
    }

    /// From the phone: yes or no to a request the Mac published.
    @Test func thePhoneAnswersWithAPlainCommand() async throws {
        let rig = HubRig().paired()
        let request = UUID()
        let withoutFaceID = try rig.phone.sign(.answerAgentRequest(id: request, allow: true), mac: rig.macID, at: rig.clock.now())
        #expect(await rig.hub.handle(withoutFaceID, via: .direct).status != .executed, "accepting needs Face ID")
        let allow = try rig.phone.sign(.answerAgentRequest(id: request, allow: true), mac: rig.macID, at: rig.clock.now(), faceID: true)
        #expect(await rig.hub.handle(allow, via: .direct).status == .executed)
        let deny = try rig.phone.sign(.answerAgentRequest(id: UUID(), allow: false), mac: rig.macID, at: rig.clock.now())
        #expect(await rig.hub.handle(deny, via: .direct).status == .executed, "refusing does not")
        #expect(rig.target.calls == ["agent allow", "agent deny"])
        #expect(!WatchLink.allowed(.answerAgentRequest(id: UUID(), allow: false)))
    }

    /// Held only for a phone that said it answers requests: an older one
    /// would show nothing while Claude waits up to an hour.
    @Test func heldOnlyWhenAPairedPhoneCanAnswer() {
        let older = TestPhone().device
        var current = TestPhone().device
        current.capabilities = [PhoneCapability.agentRequests.rawValue]
        var other = TestPhone().device
        other.capabilities = ["somethingElse"]
        #expect(!AgentApprovals.holds(nobodyAtTheMac: true, evenAtTheMac: false, devices: []))
        #expect(!AgentApprovals.holds(nobodyAtTheMac: true, evenAtTheMac: true, devices: [older, other]), "Claude asks in the terminal")
        #expect(AgentApprovals.holds(nobodyAtTheMac: true, evenAtTheMac: false, devices: [older, current]), "one is enough")
        #expect(!AgentApprovals.holds(nobodyAtTheMac: false, evenAtTheMac: false, devices: [current]), "back at the Mac")
        #expect(AgentApprovals.holds(nobodyAtTheMac: false, evenAtTheMac: true, devices: [current]))
    }

    /// The phone says it answers requests with a plain signed command: the
    /// Mac keeps that with this phone only, and does not show it as the
    /// last command.
    @Test func aPhoneDeclaresItAnswersRequests() async throws {
        let rig = HubRig().paired()
        let other = TestPhone()
        rig.store.stored.append(other.device)
        var updated: [UUID] = []
        rig.hub.onDeviceUpdated = { updated.append($0.id) }
        var announced: [CommandResult] = []
        rig.hub.onResult = { announced.append($0) }
        let names = PhoneCapability.allCases.map(\.rawValue)
        let declaration = try rig.phone.sign(.declareCapabilities(names), mac: rig.macID, at: rig.clock.now())
        #expect(await rig.hub.handle(declaration, via: .direct, peer: rig.phone.id).status == .executed, "without Face ID")
        #expect(rig.store.stored.first { $0.id == rig.phone.id }?.answersAgentRequests == true)
        #expect(rig.store.stored.first { $0.id == other.id }?.capabilities == nil, "only the signer's entry")
        #expect(updated == [rig.phone.id])
        #expect(announced.isEmpty)
        #expect(rig.ledger.value?.results.map(\.status) == [.executed], "recorded all the same")
        #expect(rig.target.calls.isEmpty)

        let again = try rig.phone.sign(.declareCapabilities(names), mac: rig.macID, at: rig.clock.now())
        #expect(await rig.hub.handle(again, via: .cloud).status == .executed)
        #expect(updated == [rig.phone.id], "the same list is not written again")

        let nothing = try rig.phone.sign(.declareCapabilities([]), mac: rig.macID, at: rig.clock.now())
        #expect(await rig.hub.handle(nothing, via: .cloud).status == .executed)
        #expect(rig.store.stored.first { $0.id == rig.phone.id }?.answersAgentRequests == false, "a later list replaces it")
    }

    /// Unpaired, then paired again: the phone starts over and declares anew.
    @Test func aNewPairingForgetsWhatThePhoneDeclared() async throws {
        let rig = HubRig()
        let invite = try rig.hub.makeInvite(macName: "MacBook", endpoints: nil)
        #expect(rig.hub.handlePairing(rig.phone.pairingRequest(for: invite, at: rig.clock.now()), macName: "MacBook").accepted)
        let declaration = try rig.phone.sign(.declareCapabilities([PhoneCapability.agentRequests.rawValue]), mac: rig.macID, at: rig.clock.now())
        #expect(await rig.hub.handle(declaration, via: .cloud).status == .executed)
        #expect(rig.hub.pairedDevices().first?.answersAgentRequests == true)
        try rig.hub.unpair(deviceID: rig.phone.id)
        let next = try rig.hub.makeInvite(macName: "MacBook", endpoints: nil)
        #expect(rig.hub.handlePairing(rig.phone.pairingRequest(for: next, at: rig.clock.now()), macName: "MacBook").accepted)
        #expect(rig.hub.pairedDevices().first?.answersAgentRequests == false)
    }

    /// A Keychain entry written by an earlier version has no capabilities:
    /// read as a phone that does not answer, never dropped.
    @Test func anEarlierKeychainEntryReadsWithoutCapabilities() throws {
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(TestPhone().device)) as? [String: Any])
        json.removeValue(forKey: "capabilities")
        let device = try JSONDecoder().decode(PairedDevice.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(device.capabilities == nil)
        #expect(!device.answersAgentRequests)
    }
}
