import AppKit
import CoreGraphics
import DarraOwlCore
import DarraOwlShared
import DarraOwlSystem
import DarraOwlXPC
import Foundation
import Observation
import os
import Synchronization

/// State of the menu bar app. The helper owns the session; this only shows
/// it and forwards requests.
@MainActor
@Observable
public final class AppModel {
    public private(set) var registration: HelperRegistration = .notRegistered
    public private(set) var status: EngineStatus?
    public private(set) var reachable = false
    public private(set) var lastError: String?
    public private(set) var busy = false
    public private(set) var now = Date()
    public private(set) var loginItemEnabled = false

    /// Presence ("toujours actif"): held by the app, independent of sessions.
    public private(set) var presenceActive = false
    public private(set) var presenceUntil: Date?
    public private(set) var presenceLastStop: PresenceStopReason?
    private let presence = PresenceController(asserter: IOPMPresenceAsserter())
    static let presenceIndefiniteKey = "presenceIndefinite"
    /// The lid as the app last saw it, kept across launches.
    static let lidClosedKey = "lidClosedAtLastLook"

    /// Lid-close actions.
    public private(set) var lidClosed = false
    public private(set) var lidProblems: [String] = []
    /// Why the display or keyboard backlight is left alone on this Mac.
    public let displayRefusal: String?
    public let keyboardRefusal: String?
    @ObservationIgnored private var lid: LidCoordinator!
    @ObservationIgnored private let lidObserver = LidObserver()
    @ObservationIgnored private var restoring = false
    /// The lid opened while the helper did not answer: the open is done
    /// once it answers again (apps resumed, brightness and sound back).
    @ObservationIgnored private var openPending = false
    /// Apps paused before this launch are checked once the helper answers.
    @ObservationIgnored private var checkedFrozenAtLaunch = false
    /// The previous run of the app ended with the lid closed (crash, quit):
    /// apps paused then are resumed at this launch if the lid is open. Apps
    /// paused from the phone with the lid open stay paused.
    @ObservationIgnored private var lidWasClosedAtLastRun = false
    /// The session the close actions ran for, during this close: once per
    /// session and per close, even when the app learns of the session after
    /// the lid closed (started from the Terminal or the phone a moment before).
    @ObservationIgnored private var closeActionsFor: UUID?
    /// An external display is on: a closed lid is then a Mac on a desk.
    @ObservationIgnored private var externalDisplay = ExternalDisplays.anyActive()
    @ObservationIgnored private var lidUpkeepRunning = false
    /// Restores in a row that left problems: past a few, no more tries until
    /// the lid moves (each try wakes the display).
    @ObservationIgnored private var failedRestores = 0
    static let maxFailedRestores = 3
    @ObservationIgnored private var lastHelperRestart: Date?
    @ObservationIgnored private let powerSource = IOPSPowerSource()
    /// Phone link: pairing, direct server, iCloud.
    public private(set) var remote: RemoteController!

    private let client = HelperClient()
    private let log = Logger(subsystem: "com.darrao.darraowl", category: "app")
    private var loop: Task<Void, Never>?
    static let firstLaunchKey = "didConfigureLoginItem"

    public init() {
        let display = DisplayServicesDimmer()
        let keyboard = CoreBrightnessKeyboard()
        displayRefusal = display.refusal()
        keyboardRefusal = keyboard.refusal()
        let gateway = AppHelperGateway(client: client) { [weak self] status in
            self?.status = status
        }
        lid = LidCoordinator(.init(
            display: displayRefusal == nil ? display : nil,
            keyboard: keyboardRefusal == nil ? keyboard : nil,
            displaySleep: PublicDisplaySleep(),
            audio: CoreAudioControl(),
            processes: WorkspaceProcesses(),
            docker: DockerDesktopProbe(),
            helper: gateway,
            log: OSLogEngineLogger(category: "lid"),
            externalDisplayActive: { ExternalDisplays.anyActive() },
            microphoneInUse: { CoreAudioControl().inputInUse() }
        ))
        remote = RemoteController(model: self)
    }

    public var session: Session? { status?.session }

    public var remaining: TimeInterval? {
        session.map { $0.remaining(at: now) }
    }

    public var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev"
    }

    // MARK: Lifecycle

    public func start() {
        guard loop == nil else { return }
        configureLoginItemOnFirstLaunch()
        lidObserver.onChange = { [weak self] closed in
            Task { await self?.handleLid(closed: closed) }
        }
        lidObserver.start()
        lidClosed = lidObserver.isClosed
        lidWasClosedAtLastRun = UserDefaults.standard.bool(forKey: Self.lidClosedKey)
        UserDefaults.standard.set(lidClosed, forKey: Self.lidClosedKey)
        // Presence learns about the lid before it may hold anything.
        presence.setSuspended(lidClosed)
        // "Sans limite" survives a relaunch, so the Mac stays active after a
        // restart; a timed presence does not.
        if UserDefaults.standard.bool(forKey: Self.presenceIndefiniteKey) {
            startPresence(duration: nil)
        }
        // A display put to sleep from the phone stays dark for presence until it wakes.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.presence.setQuiet(false) }
        }
        // A display plugged or unplugged with the lid closed changes what a
        // closed lid means.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.displaysChanged() }
        }
        loop = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                self.now = Date()
                self.tickPresence()
                if tick % 30 == 0 { self.sampleBrightnessIfPresent() }
                if self.reachable { self.remote.start() }
                self.remote.everySecond()
                // Ask the helper every 2 s during a session, every 10 s otherwise.
                let every = self.session == nil ? 10 : 2
                if tick % every == 0 { await self.refresh() }
                tick += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    public func refresh() async {
        // A missing plist is only learnt from register(); keep showing it.
        if registration != .notFound {
            registration = ServiceRegistration.helperState()
        }
        loginItemEnabled = ServiceRegistration.loginItemEnabled
        guard registration == .enabled else {
            reachable = false
            return
        }
        do {
            let response = try await client.send(.status)
            apply(response)
            await restartHelperIfOutdated(response)
            // The helper forgets the displays when it restarts (update,
            // crash): told again whenever it differs.
            if let helper = response.status, (helper.externalDisplay ?? false) != externalDisplay {
                _ = try? await client.send(.displays(external: externalDisplay))
            }
            // Lid work can last half a minute (display sleep requests, a
            // second brightness write): it never holds up the 1-second loop.
            if !lidUpkeepRunning { Task { await lidUpkeep() } }
        } catch {
            reachable = false
            client.invalidate()
            log.error("helper unreachable: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Session

    public func startSession(seconds: TimeInterval) {
        perform(.start(seconds: seconds, origin: .menuBar))
    }

    public func extend(seconds: TimeInterval) {
        perform(.extend(seconds: seconds))
    }

    public func stopSession() {
        perform(.stop(reason: .userStopped))
    }

    /// Agent mode from the menu: stay awake while this agent runs, at most the cap.
    public func follow(_ agent: AgentProcess) {
        guard let request = Self.watchRequest(agent) else {
            lastError = EngineError.processGone.localizedDescription
            return
        }
        perform(request)
    }

    /// The helper checks the identity read here against the process table.
    /// It must still be the scanned agent: same pid, same start second.
    static func watchRequest(_ agent: AgentProcess) -> HelperRequest? {
        guard case let .present(state) = SysctlProcessControl().lookup(agent.pid),
              state.identity.startSeconds == Int64(agent.startedAt.timeIntervalSince1970)
        else { return nil }
        let process = WatchedProcess(
            pid: agent.pid, name: agent.tool, project: agent.project,
            startSeconds: state.identity.startSeconds, startMicros: state.identity.startMicros
        )
        return .watch(process, seconds: nil, origin: .agent)
    }

    public func updateSettings(_ settings: PowerSettings) {
        perform(.updateSettings(settings))
    }

    public func clearError() {
        lastError = nil
    }

    /// Quitting ends the session first: the phone and the agent mode need the
    /// app, so a session never outlives it.
    public func quit() {
        NSApp.terminate(nil)
    }

    /// Called by the app delegate however the app is quit. The helper is
    /// asked even when this app saw no session (one may have started from
    /// the Terminal a moment ago), then the brightness and sound saved for
    /// the session come back: only the app can restore them. A few seconds
    /// at most, so a silent helper never holds up a quit or a logout.
    func stopBeforeQuitting() async {
        guard registration == .enabled else { return }
        await Bounded.run(seconds: 6) { [self] in
            let response = try? await client.send(.stop(reason: .appQuit), timeout: 3)
            guard let status = response?.status ?? status, !status.userChanges.isEmpty else { return }
            _ = await lid.restore(status.userChanges)
        }
    }

    // MARK: Remote

    /// For the remote controller: a helper request whose refusal throws.
    func sendHelper(_ request: HelperRequest) async throws -> EngineStatus {
        let response = try await client.send(request)
        // A refusal goes back to the phone; the menu does not show it.
        apply(response, showingError: false)
        if let error = response.error { throw HelperRefusal(message: error) }
        guard let status = response.status else { throw HelperClientError.badReply }
        return status
    }

    var lidCoordinator: LidCoordinator { lid }

    // MARK: Lid

    /// Gives up on an audio device that will not come back.
    public func forgetAudio(deviceUID: String) {
        Task { await lid.forgetAudio(deviceUID: deviceUID) }
    }

    private func handleLid(closed: Bool) async {
        lidClosed = closed
        failedRestores = 0
        UserDefaults.standard.set(closed, forKey: Self.lidClosedKey)
        closeActionsFor = nil
        // Presence holds a display assertion, which would keep the panel lit
        // under the lid: release it while closed, take it back at open.
        presence.setSuspended(closed)
        guard reachable, status != nil else {
            if !closed {
                // Delayed close steps must not run with the lid open, and the
                // open is finished when the helper answers again.
                lid.cancelPending()
                openPending = true
            }
            return
        }
        if closed {
            openPending = false
            // Asked afresh: a session started from the Terminal a moment ago counts.
            if let fresh = try? await client.send(.lidChanged) { apply(fresh, showingError: false) }
            await runCloseActionsIfDue(evenIfBusy: true)
        } else {
            openPending = false
            let problems = await lid.lidOpened(sessionActive: status?.session != nil)
            // The helper did not answer: done again once it does.
            if lid.resumeFailed { openPending = true }
            if !lidClosed { lidProblems = problems }
        }
    }

    private func lidUpkeep() async {
        guard !lidUpkeepRunning else { return }
        lidUpkeepRunning = true
        defer { lidUpkeepRunning = false }
        await finishLidOpenIfDue()
        await runCloseActionsIfDue()
        await restoreUserChangesIfDue()
    }

    /// The helper's status only, nothing acted upon: before the Mac sleeps.
    func fetchStatus() async {
        guard registration == .enabled, let response = try? await client.send(.status, timeout: 2) else { return }
        apply(response, showingError: false)
    }

    /// The close actions, once per session and per close.
    private func runCloseActionsIfDue(evenIfBusy: Bool = false) async {
        guard lidClosed, evenIfBusy || !lid.isBusy, let status, let session = status.session, closeActionsFor != session.id else { return }
        closeActionsFor = session.id
        let problems = await lid.lidClosed(settings: status.settings.lid, keeping: keptProcesses(status))
        // A later open already replaced these.
        if lidClosed { lidProblems = problems }
    }

    /// A display came or went. The helper is told (no Low Power Mode on a
    /// desk). With the lid closed during a session, docking undoes the close
    /// actions (someone works on the external display) and undocking runs
    /// them (the Mac goes in a bag).
    private func displaysChanged() async {
        let external = ExternalDisplays.anyActive()
        guard external != externalDisplay else { return }
        externalDisplay = external
        // Unreachable: refresh() tells the helper once it answers.
        guard reachable else { return }
        _ = try? await client.send(.displays(external: external))
        guard lidClosed, let status, let session = status.session else { return }
        if external {
            closeActionsFor = session.id
            lidProblems = await lid.lidOpened(sessionActive: true)
            if lid.resumeFailed { openPending = true }
        } else {
            closeActionsFor = nil
            await runCloseActionsIfDue(evenIfBusy: true)
        }
    }

    /// Running agents and followed processes: an app whose tree holds one is
    /// never paused (an agent in that terminal would stop with it). Scanned
    /// now: an agent started a moment ago counts, phone link or not.
    private func keptProcesses(_ status: EngineStatus) -> Set<Int32> {
        Set(AgentScanner.scan().map(\.pid)).union(status.session?.watching.map(\.pid) ?? [])
    }

    /// The lid is open but apps are still paused: the open happened while
    /// the helper did not answer, or the app quit (or crashed) lid closed.
    private func finishLidOpenIfDue() async {
        guard let status, !lidClosed, !lid.isBusy else { return }
        let firstLook = !checkedFrozenAtLaunch
        checkedFrozenAtLaunch = true
        guard openPending || (firstLook && lidWasClosedAtLastRun && !status.frozen.isEmpty) else { return }
        openPending = false
        lidProblems = await lid.lidOpened(sessionActive: status.session != nil)
        if lid.resumeFailed { openPending = true }
    }

    /// Brightness and sound saved at a lid close come back once the lid is
    /// open or the session is over, including after a crash or a relaunch.
    /// Sound muted from the phone waits for the end of the session.
    private func restoreUserChangesIfDue() async {
        guard let status, !restoring, !lid.isBusy, status.session == nil || !lidClosed,
              failedRestores < Self.maxFailedRestores else { return }
        let due = status.session == nil ? status.userChanges : status.userChanges.withoutHeld
        guard !due.isEmpty else { return }
        restoring = true
        defer { restoring = false }
        lidProblems = await lid.restore(due)
        failedRestores = lidProblems.isEmpty ? 0 : failedRestores + 1
    }

    /// From the phone: the display goes dark, and presence stops lighting it
    /// up until someone wakes it.
    func displayOffFromPhone() {
        presence.setQuiet(true)
        PublicDisplaySleep().requestSleep()
    }

    /// The open-lid brightness, read only while the user is at the Mac: the
    /// idle dim and a closing lid both lower it.
    private func sampleBrightnessIfPresent() {
        guard !lidClosed, status?.userChanges.displayBrightness == nil else { return }
        guard UserIdle.seconds() < 30 else { return }
        lid.sampleBrightness()
    }

    // MARK: Presence

    /// `duration` nil: no end time.
    public func startPresence(duration: TimeInterval?) {
        let now = Date()
        // Turned off from the phone earlier but lit again since (the request
        // can be deferred right after a wake): no longer quiet.
        if presence.quiet, CGDisplayIsAsleep(CGMainDisplayID()) == 0 { presence.setQuiet(false, now: now) }
        do {
            try presence.start(until: duration.map { now.addingTimeInterval($0) }, now: now)
            UserDefaults.standard.set(duration == nil, forKey: Self.presenceIndefiniteKey)
        } catch {
            lastError = "Mode présence : \(error.localizedDescription)"
        }
        syncPresence()
    }

    public func stopPresence() {
        presence.stop(.user)
        UserDefaults.standard.set(false, forKey: Self.presenceIndefiniteKey)
        syncPresence()
    }

    private func tickPresence() {
        guard presence.isActive else { return }
        // Read here, not from the helper: presence must stop on a low battery
        // even when the helper does not answer.
        presence.tick(now: now, power: powerSource.read(), settings: status?.settings ?? .default)
        if !presence.isActive {
            UserDefaults.standard.set(false, forKey: Self.presenceIndefiniteKey)
        }
        syncPresence()
    }

    private func syncPresence() {
        presenceActive = presence.isActive
        presenceUntil = presence.until
        presenceLastStop = presence.lastStop
    }

    // MARK: Helper and login item

    public func installHelper() {
        lastError = nil
        do {
            try ServiceRegistration.registerHelper()
            registration = ServiceRegistration.helperState()
        } catch where ServiceRegistration.isMissingPlist(error) {
            registration = .notFound
        } catch {
            // A daemon waiting for approval makes register() throw "Operation
            // not permitted"; the status tells the real story.
            registration = ServiceRegistration.helperState()
            if registration == .notRegistered {
                lastError = "Installation du composant système : \(error.localizedDescription)"
            }
        }
        if registration == .requiresApproval {
            ServiceRegistration.openLoginItemsSettings()
        }
        Task { await refresh() }
    }

    public func openApprovalSettings() {
        ServiceRegistration.openLoginItemsSettings()
    }

    public func setLoginItem(_ on: Bool) {
        do {
            try ServiceRegistration.setLoginItem(on)
        } catch {
            lastError = "Ouverture à la connexion : \(error.localizedDescription)"
        }
        loginItemEnabled = ServiceRegistration.loginItemEnabled
    }

    // MARK: Private

    private func perform(_ request: HelperRequest) {
        guard !busy else { return }
        busy = true
        lastError = nil
        Task {
            defer { busy = false }
            do {
                let response = try await client.send(request)
                apply(response)
            } catch {
                reachable = false
                client.invalidate()
                lastError = error.localizedDescription
            }
        }
    }

    private func apply(_ response: HelperResponse, showingError: Bool = true) {
        reachable = true
        if let status = response.status { self.status = status }
        if showingError, let error = response.error { lastError = error }
        now = Date()
    }

    /// After an update the running helper is still the old binary. An idle one
    /// is asked to exit; launchd starts the new one at once. A busy one is
    /// asked again once its session is over, at most once a minute.
    private func restartHelperIfOutdated(_ response: HelperResponse) async {
        guard response.helperBuild != appBuild, response.status?.session == nil else { return }
        if let last = lastHelperRestart, Date().timeIntervalSince(last) < 60 { return }
        lastHelperRestart = Date()
        _ = try? await client.send(.restartIfIdle)
        client.invalidate()
    }

    private func configureLoginItemOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.firstLaunchKey) else { return }
        defaults.set(true, forKey: Self.firstLaunchKey)
        try? ServiceRegistration.setLoginItem(true)
    }
}

/// Waits for an operation at most a given time; the operation itself may
/// go on after that.
enum Bounded {
    @MainActor
    static func run(seconds: Double, _ operation: @escaping @MainActor () async -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = Once()
            Task { @MainActor in
                await operation()
                if once.claim() { continuation.resume() }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if once.claim() { continuation.resume() }
            }
        }
    }

    private final class Once: Sendable {
        private let done = Mutex(false)
        func claim() -> Bool {
            done.withLock { done in
                defer { done = true }
                return !done
            }
        }
    }
}
