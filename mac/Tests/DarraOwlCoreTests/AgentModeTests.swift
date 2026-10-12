@testable import DarraOwlCore
import DarraOwlShared
import Foundation
import Testing

/// Agent mode: a session that follows processes, always bounded by an end time.
@Suite struct AgentModeTests {
    static let uid: UInt32 = 501

    /// A running process of the user, as the engine and its caller see it.
    func spawn(_ h: Harness, pid: Int32, name: String = "claude", start: Int64 = 1000) -> WatchedProcess {
        h.processes.set(pid, FakeProcesses.state(uid: Self.uid, start: start))
        return WatchedProcess(pid: pid, name: name, project: "DarraOwl", startSeconds: start, startMicros: 7)
    }

    @Test func watchStartsASessionEndingAtTheCap() async throws {
        let h = Harness()
        _ = await h.engine.reconcile()
        let p = spawn(h, pid: 300)

        let status = try await h.engine.watch(p, seconds: nil, origin: .agent, requesterUID: Self.uid)

        #expect(status.session?.watching == [p])
        #expect(status.session?.origin == .agent)
        #expect(status.session?.endsAt == h.clock.now().addingTimeInterval(PowerSettings.default.maxSessionDuration))
        #expect(status.sleepHeld)
        #expect(h.journal.value?.session?.watching == [p])
    }

    @Test func sessionEndsWhenTheProcessExits() async throws {
        let h = Harness()
        _ = await h.engine.reconcile()
        let p = spawn(h, pid: 300)
        _ = try await h.engine.watch(p, seconds: 3 * 3600, origin: .cli, requesterUID: Self.uid)

        h.clock.advance(60)
        #expect(await h.engine.evaluate().session != nil)

        h.processes.set(300, nil)
        let status = await h.engine.evaluate()
        #expect(status.session == nil)
        #expect(status.lastEnd?.reason == .agentFinished)
        #expect(!status.sleepHeld)
        #expect(!h.power.current.sleepDisabled)
    }

    @Test func aReusedPidIsNotTheWatchedProcess() async throws {
        let h = Harness()
        _ = await h.engine.reconcile()
        let p = spawn(h, pid: 300, start: 1000)
        _ = try await h.engine.watch(p, seconds: nil, origin: .agent, requesterUID: Self.uid)

        h.processes.set(300, FakeProcesses.state(uid: Self.uid, start: 5000))
        #expect(await h.engine.evaluate().lastEnd?.reason == .agentFinished)
    }

    @Test func theEndTimeStillApplies() async throws {
        let h = Harness()
        _ = await h.engine.reconcile()
        let p = spawn(h, pid: 300)
        _ = try await h.engine.watch(p, seconds: 3600, origin: .cli, requesterUID: Self.uid)

        h.clock.advance(3600)
        let status = await h.engine.evaluate()
        #expect(status.session == nil)
        #expect(status.lastEnd?.reason == .expired)
    }

    @Test func anUnreadableProcessIsStillFollowed() async throws {
        let h = Harness()
        _ = await h.engine.reconcile()
        let p = spawn(h, pid: 300)
        _ = try await h.engine.watch(p, seconds: nil, origin: .agent, requesterUID: Self.uid)
        h.processes.set(300, nil)
        h.processes.unreadable.withLock { $0.insert(300) }

        #expect(await h.engine.evaluate().session?.watching == [p])
    }

    @Test func endsWhenTheLastOfSeveralExits() async throws {
        let h = Harness()
        _ = await h.engine.reconcile()
        let a = spawn(h, pid: 300)
        let b = spawn(h, pid: 301, name: "codex")
        _ = try await h.engine.watch(a, seconds: nil, origin: .agent, requesterUID: Self.uid)
        _ = try await h.engine.watch(b, seconds: nil, origin: .agent, requesterUID: Self.uid)

        h.processes.set(300, nil)
        #expect(await h.engine.evaluate().session?.watching == [b])
        h.processes.set(301, nil)
        #expect(await h.engine.evaluate().session == nil)
    }

    @Test func aTimedSessionGoesBackToItsEndWhenTheAgentFinishesFirst() async throws {
        let h = Harness()
        _ = await h.engine.reconcile()
        let started = try await h.engine.start(duration: 4 * 3600, origin: .menuBar)
        let planned = try #require(started.session?.endsAt)
        let p = spawn(h, pid: 300)

        let joined = try await h.engine.watch(p, seconds: nil, origin: .agent, requesterUID: Self.uid)
        #expect(joined.session?.keepUntil == planned)
        #expect(joined.session?.endsAt == h.clock.now().addingTimeInterval(PowerSettings.default.maxSessionDuration))

        h.clock.advance(600)
        h.processes.set(300, nil)
        let status = await h.engine.evaluate()
        #expect(status.session?.endsAt == planned)
        #expect(status.session?.watching == [])
        #expect(status.session?.keepUntil == nil)
    }

    @Test func aTimedSessionWhoseEndPassedEndsWithTheAgent() async throws {
        let h = Harness()
        _ = await h.engine.reconcile()
        _ = try await h.engine.start(duration: 3600, origin: .menuBar)
        let p = spawn(h, pid: 300)
        _ = try await h.engine.watch(p, seconds: nil, origin: .agent, requesterUID: Self.uid)

        h.clock.advance(2 * 3600)
        h.processes.set(300, nil)
        #expect(await h.engine.evaluate().lastEnd?.reason == .agentFinished)
    }

    @Test func releaseEndsAtOnce() async throws {
        let h = Harness()
        _ = await h.engine.reconcile()
        let p = spawn(h, pid: 300)
        _ = try await h.engine.watch(p, seconds: nil, origin: .cli, requesterUID: Self.uid)

        // The process is still in the table: the CLI says it is done.
        let status = await h.engine.release(pid: 300)
        #expect(status.session == nil)
        #expect(status.lastEnd?.reason == .agentFinished)
    }

    @Test func releaseOfAnotherPidChangesNothing() async throws {
        let h = Harness()
        _ = await h.engine.reconcile()
        let p = spawn(h, pid: 300)
        _ = try await h.engine.watch(p, seconds: nil, origin: .cli, requesterUID: Self.uid)
        #expect(await h.engine.release(pid: 999).session?.watching == [p])
    }

    @Test func refusesAGoneOrForeignOrChangedProcess() async throws {
        let h = Harness()
        _ = await h.engine.reconcile()
        let gone = WatchedProcess(pid: 300, name: "claude", project: nil, startSeconds: 1000, startMicros: 7)
        await #expect(throws: EngineError.processGone) {
            _ = try await h.engine.watch(gone, seconds: nil, origin: .agent, requesterUID: Self.uid)
        }
        h.processes.set(301, FakeProcesses.state(uid: 0, start: 1000))
        let root = WatchedProcess(pid: 301, name: "launchd", project: nil, startSeconds: 1000, startMicros: 7)
        await #expect(throws: EngineError.notYourProcess) {
            _ = try await h.engine.watch(root, seconds: nil, origin: .agent, requesterUID: Self.uid)
        }
        h.processes.set(302, FakeProcesses.state(uid: Self.uid, start: 2000))
        let changed = WatchedProcess(pid: 302, name: "claude", project: nil, startSeconds: 1000, startMicros: 7)
        await #expect(throws: EngineError.processGone) {
            _ = try await h.engine.watch(changed, seconds: nil, origin: .agent, requesterUID: Self.uid)
        }
        #expect(await h.engine.status().session == nil)
        #expect(!h.power.current.sleepDisabled)
    }

    @Test func aDurationOverTheCapIsRefused() async {
        let h = Harness()
        _ = await h.engine.reconcile()
        let p = spawn(h, pid: 300)
        await #expect(throws: EngineError.self) {
            _ = try await h.engine.watch(p, seconds: 13 * 3600, origin: .cli, requesterUID: Self.uid)
        }
    }

    @Test func joiningNeverPassesTheCap() async throws {
        let h = Harness()
        _ = await h.engine.reconcile()
        let a = spawn(h, pid: 300)
        _ = try await h.engine.watch(a, seconds: nil, origin: .agent, requesterUID: Self.uid)
        h.clock.advance(3600)
        let b = spawn(h, pid: 301)
        let status = try await h.engine.watch(b, seconds: nil, origin: .agent, requesterUID: Self.uid)
        #expect(status.session?.endsAt == h.clock.now().addingTimeInterval(PowerSettings.default.maxSessionDuration))
    }

    @Test func afterARestartAGoneProcessEndsTheSession() async throws {
        let h = Harness()
        _ = await h.engine.reconcile()
        let p = spawn(h, pid: 300)
        _ = try await h.engine.watch(p, seconds: nil, origin: .agent, requesterUID: Self.uid)

        // Reboot: a new engine on the same journal, the process is gone.
        let journal = h.journal.value
        let h2 = Harness(power: h.power.current, journal: journal)
        h2.clock.advance(h.clock.now().timeIntervalSince(h2.clock.now()))
        let status = await h2.engine.reconcile()
        #expect(status.session == nil)
        #expect(status.lastEnd?.reason == .agentFinished)
        #expect(!h2.power.current.sleepDisabled)
    }

    @Test func aJournalFromBeforeAgentModeStillLoads() throws {
        let old = #"{"id":"6A1F3E0C-0000-4000-8000-000000000001","startedAt":"2026-10-11T10:00:00Z","endsAt":"2026-10-11T12:00:00Z","origin":"menuBar"}"#
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let s = try d.decode(Session.self, from: Data(old.utf8))
        #expect(s.watching.isEmpty)
        #expect(s.keepUntil == nil)
    }
}

@Suite struct CLICommandTests {
    @Test func runForms() throws {
        #expect(try CLICommand.parse(["run", "3h", "--", "claude"]) == .run(seconds: 3 * 3600, command: ["claude"]))
        #expect(try CLICommand.parse(["run", "--", "npm", "test"]) == .run(seconds: nil, command: ["npm", "test"]))
        #expect(try CLICommand.parse(["run", "90", "make"]) == .run(seconds: 90 * 60, command: ["make"]))
        #expect(try CLICommand.parse(["run", "claude", "-p", "x"]) == .run(seconds: nil, command: ["claude", "-p", "x"]))
        // After --, a duration-looking word is the command's.
        #expect(try CLICommand.parse(["run", "--", "45", "x"]) == .run(seconds: nil, command: ["45", "x"]))
        #expect(try CLICommand.parse(["run", "1j", "--", "x"]) == .run(seconds: 86_400, command: ["x"]))
        // A `--` further on is the command's own.
        #expect(try CLICommand.parse(["run", "npm", "test", "--", "--watch"]) == .run(seconds: nil, command: ["npm", "test", "--", "--watch"]))
        #expect(try CLICommand.parse(["run", "claude", "--", "--resume"]) == .run(seconds: nil, command: ["claude", "--", "--resume"]))
        #expect(try CLICommand.parse(["run", "2h", "--", "cargo", "run", "--", "-v"]) == .run(seconds: 7200, command: ["cargo", "run", "--", "-v"]))
        #expect(try CLICommand.parse(["run", "2h", "cargo", "run", "--", "-v"]) == .run(seconds: 7200, command: ["cargo", "run", "--", "-v"]))
    }

    @Test func runErrors() {
        #expect(throws: CLICommand.ParseError.missingCommand) { try CLICommand.parse(["run"]) }
        #expect(throws: CLICommand.ParseError.missingCommand) { try CLICommand.parse(["run", "3h", "--"]) }
        #expect(throws: CLICommand.ParseError.missingCommand) { try CLICommand.parse(["run", "45"]) }
        #expect(throws: CLICommand.ParseError.badDuration("2:75")) { try CLICommand.parse(["run", "2:75", "--", "x"]) }
        #expect(throws: CLICommand.ParseError.badDuration("9999999999999999999999h")) { try CLICommand.parse(["run", "9999999999999999999999h", "--", "x"]) }
    }

    @Test func hugeNumbersDoNotCrash() {
        #expect(CLICommand.duration("999999999999999999") != nil)
        #expect(throws: (any Error).self) { try CLICommand.parse(["start", "99999999999999999999999"]) }
    }

    @Test func otherVerbs() throws {
        #expect(try CLICommand.parse([]) == .status)
        #expect(try CLICommand.parse(["status"]) == .status)
        #expect(try CLICommand.parse(["stop"]) == .stop)
        #expect(try CLICommand.parse(["start", "1h30"]) == .start(seconds: 5400))
        #expect(try CLICommand.parse(["extend", "30m"]) == .extend(seconds: 1800))
        #expect(try CLICommand.parse(["--help"]) == .help)
        #expect(throws: CLICommand.ParseError.missingDuration("start")) { try CLICommand.parse(["start"]) }
        #expect(throws: CLICommand.ParseError.unknown("sudo")) { try CLICommand.parse(["sudo"]) }
        #expect(throws: CLICommand.ParseError.extraArguments("now")) { try CLICommand.parse(["stop", "now"]) }
    }

    @Test(arguments: [("2j", 172_800), ("1j12h", 129_600), ("1d30m", 88_200), ("45m", 2700), ("0j", nil), ("31j", nil), ("jx", nil)] as [(String, TimeInterval?)])
    func durations(text: String, seconds: TimeInterval?) {
        #expect(CLICommand.duration(text) == seconds)
    }
}
