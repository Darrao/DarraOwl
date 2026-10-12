@testable import DarraOwlCore
import DarraOwlShared
import Foundation
import Synchronization

/// Ordered record of every side effect, shared by the fakes, so a test can
/// check that the journal was written before a change was applied.
final class EventLog: Sendable {
    private let events = Mutex<[String]>([])
    func add(_ e: String) { events.withLock { $0.append(e) } }
    var all: [String] { events.withLock { $0 } }
    func clear() { events.withLock { $0.removeAll() } }
}

struct FakeError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class FakePower: PowerControlling, Sendable {
    struct State {
        var settings = PowerSettingsState(sleepDisabled: false, lowPowerOnBattery: false, lowPowerOnAC: false)
        var failSetSleep: Bool? = nil // fail when asked to set this value
        var failLowPower = false
        var failRead = false
        /// Each pmset call takes this long, so concurrent requests overlap.
        var delay: Duration = .zero
    }

    let log: EventLog
    private let state: Mutex<State>

    init(log: EventLog, settings: PowerSettingsState = .init(sleepDisabled: false, lowPowerOnBattery: false, lowPowerOnAC: false)) {
        self.log = log
        self.state = Mutex(State(settings: settings))
    }

    var current: PowerSettingsState { state.withLock { $0.settings } }
    func update(_ body: (inout State) -> Void) { state.withLock { body(&$0) } }

    private func pause() async {
        let delay = state.withLock { $0.delay }
        if delay > .zero { try? await Task.sleep(for: delay) }
    }

    func readState() async throws -> PowerSettingsState {
        await pause()
        return try state.withLock {
            if $0.failRead { throw FakeError(message: "read failed") }
            return $0.settings
        }
    }

    func setSleepDisabled(_ disabled: Bool) async throws {
        await pause()
        try state.withLock {
            if $0.failSetSleep == disabled { throw FakeError(message: "pmset disablesleep failed") }
            $0.settings.sleepDisabled = disabled
        }
        log.add("pmset disablesleep \(disabled ? 1 : 0)")
    }

    func sleepNow() async throws {
        log.add("pmset sleepnow")
    }

    func setLowPowerMode(onBattery: Bool?, onAC: Bool) async throws {
        await pause()
        try state.withLock {
            if $0.failLowPower { throw FakeError(message: "pmset lowpowermode failed") }
            if let onBattery { $0.settings.lowPowerOnBattery = onBattery }
            $0.settings.lowPowerOnAC = onAC
        }
        log.add("pmset lowpowermode b=\(onBattery.map { $0 ? "1" : "0" } ?? "-") c=\(onAC ? 1 : 0)")
    }
}

final class FakeSource: PowerSourceReading, Sendable {
    private let snapshot: Mutex<PowerSnapshot>
    init(_ s: PowerSnapshot = PowerSnapshot(battery: .percent(80), onExternalPower: false, thermal: .nominal)) {
        snapshot = Mutex(s)
    }
    func set(_ s: PowerSnapshot) { snapshot.withLock { $0 = s } }
    func read() -> PowerSnapshot { snapshot.withLock { $0 } }
}

final class FakeClock: NowProviding, Sendable {
    private let date: Mutex<Date>
    init(_ d: Date = Date(timeIntervalSince1970: 1_800_000_000)) { date = Mutex(d) }
    func now() -> Date { date.withLock { $0 } }
    func advance(_ s: TimeInterval) { date.withLock { $0 = $0.addingTimeInterval(s) } }
}

final class InMemoryStore<Value: Codable & Sendable & Equatable>: ValueStoring, Sendable {
    struct State {
        var value: Value?
        var unreadable = false
        var failWrites = false
        var quarantined = 0
        var removed = false
    }

    let name: String
    let log: EventLog
    private let state: Mutex<State>

    init(name: String, log: EventLog, value: Value? = nil) {
        self.name = name
        self.log = log
        state = Mutex(State(value: value))
    }

    var value: Value? { state.withLock { $0.value } }
    var snapshot: State { state.withLock { $0 } }
    func update(_ body: (inout State) -> Void) { state.withLock { body(&$0) } }

    func load() throws(StoreError) -> Value? {
        let s = state.withLock { $0 }
        if s.unreadable { throw .unreadable("garbage") }
        return s.value
    }

    func save(_ value: Value) throws(StoreError) {
        let failed = state.withLock { s -> Bool in
            if s.failWrites { return true }
            s.value = value
            s.unreadable = false
            return false
        }
        if failed { throw .writeFailed("disk full") }
        log.add("save \(name)")
    }

    func quarantine() throws(StoreError) -> String? {
        state.withLock { s in
            s.quarantined += 1
            s.unreadable = false
            s.value = nil
        }
        return "/tmp/\(name).unreadable"
    }

    func remove() throws(StoreError) {
        state.withLock { s in
            s.value = nil
            s.removed = true
        }
        log.add("remove \(name)")
    }
}

final class FakeProcesses: ProcessControlling, Sendable {
    private let table: Mutex<[Int32: ProcessState]>
    let log: EventLog

    init(log: EventLog, _ table: [Int32: ProcessState] = [:]) {
        self.log = log
        self.table = Mutex(table)
    }

    static let boot = "BOOT-A"

    static func state(uid: UInt32 = 501, start: Int64, stopped: Bool = false, boot: String = boot) -> ProcessState {
        ProcessState(ppid: 1, uid: uid, stopped: stopped, identity: ProcessIdentity(startSeconds: start, startMicros: 7, bootSession: boot))
    }

    func set(_ pid: Int32, _ state: ProcessState?) { table.withLock { $0[pid] = state } }
    func state(_ pid: Int32) -> ProcessState? { table.withLock { $0[pid] } }

    /// Pids the kernel does not answer for.
    let unreadable = Mutex<Set<Int32>>([])

    func lookup(_ pid: Int32) -> ProcessLookup {
        if unreadable.withLock({ $0.contains(pid) }) { return .unreadable(EPERM) }
        return table.withLock { t in t[pid].map { .present($0) } ?? .absent }
    }

    func signal(_ pid: Int32, _ signal: Int32) -> Int32 {
        let ok = table.withLock { t -> Bool in
            guard var s = t[pid] else { return false }
            s.stopped = signal == SIGSTOP
            t[pid] = s
            return true
        }
        log.add("\(signal == SIGSTOP ? "SIGSTOP" : "SIGCONT") \(pid)")
        return ok ? 0 : ESRCH
    }
}

struct SilentLog: EngineLogging {
    func info(_ message: String) {}
    func error(_ message: String) {}
}

/// Everything a SessionEngine test needs.
struct Harness {
    let events = EventLog()
    let power: FakePower
    let source = FakeSource()
    let processes: FakeProcesses
    let clock = FakeClock()
    let journal: InMemoryStore<Journal>
    let settings: InMemoryStore<PowerSettings>
    let engine: SessionEngine

    init(
        power settingsState: PowerSettingsState = .init(sleepDisabled: false, lowPowerOnBattery: false, lowPowerOnAC: false),
        journal initial: Journal? = nil,
        settings initialSettings: PowerSettings? = nil
    ) {
        power = FakePower(log: events, settings: settingsState)
        processes = FakeProcesses(log: events)
        journal = InMemoryStore(name: "journal", log: events, value: initial)
        settings = InMemoryStore(name: "settings", log: events, value: initialSettings)
        engine = SessionEngine(.init(
            power: power,
            source: source,
            processes: processes,
            clock: clock,
            journalStore: journal,
            settingsStore: settings,
            log: SilentLog()
        ))
    }
}

/// Holds whoever calls `pass()` until `open()`; `waitUntilEntered()` returns
/// once someone is held. For tests that need two calls to overlap.
final class AsyncGate: Sendable {
    private struct State {
        var isOpen = false
        var held: [CheckedContinuation<Void, Never>] = []
        var entered: [CheckedContinuation<Void, Never>] = []
        var count = 0
    }

    private let state = Mutex(State())

    func pass() async {
        let (open, waiters) = state.withLock { s -> (Bool, [CheckedContinuation<Void, Never>]) in
            if s.isOpen { return (true, []) }
            s.count += 1
            defer { s.entered = [] }
            return (false, s.entered)
        }
        waiters.forEach { $0.resume() }
        guard !open else { return }
        await withCheckedContinuation { c in
            let resumeNow = state.withLock { s -> Bool in
                if s.isOpen { return true }
                s.held.append(c)
                return false
            }
            if resumeNow { c.resume() }
        }
    }

    func waitUntilEntered() async {
        await withCheckedContinuation { c in
            let resumeNow = state.withLock { s -> Bool in
                if s.count > 0 { return true }
                s.entered.append(c)
                return false
            }
            if resumeNow { c.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.isOpen = true
            defer { s.held = [] }
            return s.held
        }
        waiters.forEach { $0.resume() }
    }
}
