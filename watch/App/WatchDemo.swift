import DarraOwlShared
import Foundation

/// Screenshots and App Review: launched with `-DarraOwlDemo`, the watch shows
/// a believable Mac without an iPhone. Never active otherwise.
enum WatchDemo {
    static func snapshot(now: Date) -> WatchLink.Snapshot {
        let state = MacState(
            macID: UUID(), macName: "MacBook Pro", updatedAt: now, power: .awake,
            session: Session(startedAt: now.addingTimeInterval(-2400), endsAt: now.addingTimeInterval(6420), origin: .phone),
            powerSnapshot: PowerSnapshot(battery: .percent(82), onExternalPower: false, thermal: .nominal, lidClosed: true, minutesToEmpty: 310),
            lowPowerActive: true, pausedApps: ["Slack"], network: .init(kind: .wifi),
            agents: [.init(tool: "claude", project: "site-vitrine", since: now.addingTimeInterval(-2300), waitingForApproval: true, pid: 4101)],
            dockerPaused: false, settings: .default,
            presence: .init(active: false, until: nil), muted: false
        )
        return WatchLink.Snapshot(state: state, macName: state.macName, presence: "En ligne, par réseau local", online: true, at: now)
    }

    static func apply(_ kind: CommandKind, to snapshot: WatchLink.Snapshot?) -> WatchLink.Snapshot? {
        guard var snapshot, var state = snapshot.state else { return snapshot }
        let now = Date()
        switch kind {
        case let .startSession(m): state.session = Session(startedAt: now, endsAt: now.addingTimeInterval(TimeInterval(m * 60)), origin: .phone)
        case let .extendSession(m): state.session?.endsAt.addTimeInterval(TimeInterval(m * 60))
        case .stopSession: state.session = nil
        case let .startPresence(m): state.presence = .init(active: true, until: m.map { now.addingTimeInterval(TimeInterval($0 * 60)) })
        case .stopPresence: state.presence = .init(active: false, until: nil)
        case let .setMuted(muted): state.muted = muted
        case let .watchAgent(pid):
            if state.session == nil { state.session = Session(startedAt: now, endsAt: now.addingTimeInterval(12 * 3600), origin: .agent) }
            if let agent = state.agents.first(where: { $0.pid == pid }) {
                state.session?.watching.append(WatchedProcess(pid: pid, name: agent.tool, project: agent.project, startSeconds: 0, startMicros: 0))
            }
        default: break
        }
        snapshot.state = state
        return snapshot
    }
}
