import AppKit
import DarraOwlCore
import DarraOwlShared
import DarraOwlXPC
import Foundation
import Observation
import os

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

    private let client = HelperClient()
    private let log = Logger(subsystem: "com.darrao.darraowl", category: "app")
    private var loop: Task<Void, Never>?
    private var checkedHelperBuild = false
    static let firstLaunchKey = "didConfigureLoginItem"

    public init() {}

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
        // "Sans limite" survives a relaunch, so the Mac stays active after a
        // restart; a timed presence does not.
        if UserDefaults.standard.bool(forKey: Self.presenceIndefiniteKey) {
            startPresence(duration: nil)
        }
        loop = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                self.now = Date()
                self.tickPresence()
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

    public func updateSettings(_ settings: PowerSettings) {
        perform(.updateSettings(settings))
    }

    public func clearError() {
        lastError = nil
    }

    /// Quitting ends the session first: the phone and the agent mode need the
    /// app, so a session never outlives it.
    public func quit() {
        Task {
            if session != nil {
                _ = try? await client.send(.stop(reason: .appQuit))
            }
            NSApp.terminate(nil)
        }
    }

    // MARK: Presence

    /// `duration` nil: no end time.
    public func startPresence(duration: TimeInterval?) {
        let now = Date()
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
        presence.tick(now: now, power: status?.power, settings: status?.settings ?? .default)
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

    private func apply(_ response: HelperResponse) {
        reachable = true
        if let status = response.status { self.status = status }
        if let error = response.error { lastError = error }
        now = Date()
    }

    /// After an update the running helper is still the old binary. An idle one
    /// is asked to exit; launchd starts the new one at once.
    private func restartHelperIfOutdated(_ response: HelperResponse) async {
        guard !checkedHelperBuild else { return }
        checkedHelperBuild = true
        guard response.helperBuild != appBuild, response.status?.session == nil else { return }
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
