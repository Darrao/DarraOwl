import ActivityKit
import DarraOwlPhoneKit
import DarraOwlShared
import Foundation
import Observation
import UIKit

/// The one PhoneModel of the app, shared by the UI, notifications, Siri and
/// the Live Activity buttons, plus what mirrors its state outside the app.
@MainActor
@Observable
final class PhoneRuntime {
    static let shared = PhoneRuntime()

    private(set) var model: PhoneModel
    /// Showing the demonstration Mac (App Review, curious users).
    private(set) var isDemo = DemoMode.isOn
    /// A darraowl:// link opened from outside, waiting for confirmation.
    var pendingLink: URL?
    /// Why a link opened from outside cannot pair.
    var linkError: String?

    /// Pairs with a link the user confirmed: out of the demonstration first,
    /// so the real Mac is the one saved.
    func pairConfirmed(_ url: URL) async {
        pendingLink = nil
        if isDemo { leaveDemo() }
        await model.pair(url: url)
    }
    @ObservationIgnored private let liveActivity = LiveActivityController()
    @ObservationIgnored private var started = false

    private init() {
        model = PhoneModel(DemoMode.isOn ? DemoMode.dependencies() : Self.liveDependencies())
        wire()
    }

    private func wire() {
        model.onStateChange = { [weak self] state in self?.mirror(state) }
        model.onUnpair = { [weak self] in
            guard let self, !self.isDemo else { return }
            self.forget()
        }
    }

    private static func liveDependencies() -> PhoneModel.Dependencies {
        .init(
            store: KeychainPhoneStore(deviceName: UIDevice.current.name),
            direct: NWDirectLink(),
            cloud: CloudKitPhoneLink(),
            pairing: NWPairingDirect()
        )
    }

    func start() async {
        guard !started else { return }
        started = true
        await model.start()
    }

    /// Demonstration: a believable Mac, nothing sent anywhere. Widgets and
    /// the Live Activity stay untouched.
    func enterDemo() {
        isDemo = true
        model = PhoneModel(DemoMode.dependencies(forcePaired: true))
        Task {
            await model.start()
            // The watch shows the demonstration too (App Review).
            if let snapshot = watchSnapshot() { WatchBridge.shared.push(snapshot) }
        }
    }

    func leaveDemo() {
        isDemo = false
        model = PhoneModel(Self.liveDependencies())
        wire()
        Task {
            await model.start()
            if let snapshot = watchSnapshot() { WatchBridge.shared.push(snapshot) }
        }
    }

    /// Siri and Live Activity buttons: sign and send, do not wait. No full
    /// start first: an intent has a few seconds only.
    func fire(_ kind: CommandKind) async -> Bool {
        let sent = await model.fire(kind)
        if sent, !isDemo {
            // Shown at once; the Mac's own state confirms a moment later.
            switch kind {
            case let .extendSession(minutes): liveActivity.extendLocally(by: CommandKind.seconds(minutes))
            case .stopSession: liveActivity.end()
            default: break
            }
        }
        // The Mac's new state shows up on the Live Activity a moment later.
        if sent {
            Task {
                try? await Task.sleep(for: .seconds(4))
                await model.refreshFromCloud()
            }
        }
        return sent
    }

    func spokenStatus() async -> String {
        await start()
        await model.tick()
        guard let state = model.state else { return "Je ne trouve pas le Mac pour le moment." }
        switch model.presence {
        case .asleep:
            return "\(state.macName) est en veille."
        case let .lastSeen(date):
            return "\(state.macName) n'a pas donné de nouvelles depuis \(DurationText.clock(date))."
        default:
            break
        }
        var text = "\(state.macName) est en ligne."
        if let session = state.session, session.endsAt > Date(), let watching = session.watchingText {
            text += " Il reste éveillé tant que \(watching) \(session.watchingVerb), au plus jusqu'à \(DurationText.clock(session.endsAt))."
        } else if let session = state.session, session.endsAt > Date() {
            text += " Il reste éveillé jusqu'à \(DurationText.clock(session.endsAt))."
        } else {
            text += " Aucune session en cours."
        }
        if case let .percent(p)? = state.powerSnapshot?.battery { text += " Batterie à \(p) %." }
        return text
    }

    /// Unpaired: nothing about the old Mac stays on the lock screen, the
    /// widgets or the watch.
    private func forget() {
        liveActivity.end()
        SharedStore.clear()
        WatchBridge.shared.push(WatchLink.Snapshot(state: nil, macName: nil, presence: "Aucun Mac appairé sur l'iPhone.", online: false, at: Date()))
    }

    /// Live Activity and widgets follow every state the app receives,
    /// including in the background after an event push.
    private func mirror(_ state: MacState) {
        guard !isDemo else { return }
        let snapshot = WidgetSnapshot(
            macName: state.macName,
            presence: presenceText,
            online: { if case .online = model.presence { return true } else { return false } }(),
            sessionEndsAt: state.session?.endsAt,
            battery: state.powerSnapshot?.battery.percent,
            charging: state.powerSnapshot?.onExternalPower ?? false,
            agentsRunning: state.agents.count,
            agentsWaiting: state.agents.filter(\.waitingForApproval).count,
            updatedAt: state.updatedAt
        )
        SharedStore.save(snapshot)
        liveActivity.update(state: state, online: snapshot.online)
        if let watch = watchSnapshot() { WatchBridge.shared.push(watch) }
    }

    /// What the Apple Watch shows: the paired Mac, the demonstration, or
    /// that no Mac is paired.
    func watchSnapshot() -> WatchLink.Snapshot? {
        if isDemo {
            return WatchLink.Snapshot(state: model.state, macName: model.mac?.macName, presence: "Démonstration", online: true, at: Date())
        }
        guard let mac = model.mac else {
            return WatchLink.Snapshot(state: nil, macName: nil, presence: "Aucun Mac appairé sur l'iPhone.", online: false, at: Date())
        }
        let online = { if case .online = model.presence { return true } else { return false } }()
        return WatchLink.Snapshot(state: model.state, macName: mac.macName, presence: presenceText, online: online, at: Date())
    }

    var presenceText: String {
        switch model.presence {
        case let .online(path): "En ligne, par \(path.label)"
        case let .asleep(since): "En veille depuis \(DurationText.clock(since))"
        case let .lastSeen(date): "Vu pour la dernière fois à \(DurationText.clock(date))"
        case .unknown: "Recherche du Mac…"
        }
    }
}

/// One Live Activity while a session runs. It can only start while the app
/// is open (no push server), then follows the state and ends with the session.
@MainActor
final class LiveActivityController {
    private var current: Activity<DarraOwlActivityAttributes>?

    init() {
        current = Activity<DarraOwlActivityAttributes>.activities.first
    }

    func update(state: MacState, online: Bool) {
        // A Mac going to sleep, or past its end time, has no session to show.
        guard let session = state.session, state.power == .awake, session.endsAt > Date() else {
            end()
            return
        }
        let content = DarraOwlActivityAttributes.ContentState(
            endsAt: session.endsAt,
            battery: state.powerSnapshot?.battery.percent,
            charging: state.powerSnapshot?.onExternalPower ?? false,
            lidClosed: state.powerSnapshot?.lidClosed ?? false,
            agentsRunning: state.agents.count,
            agentsWaiting: state.agents.filter(\.waitingForApproval).count,
            online: online,
            following: session.whileWatchingText
        )
        let activityContent = ActivityContent(state: content, staleDate: session.endsAt)
        // A stale one (past its old end time) is updated too: it is still on screen.
        if let current, current.activityState == .active || current.activityState == .stale {
            // Looked up again inside the task: an Activity is not Sendable.
            let id = current.id
            Task.detached {
                for activity in Activity<DarraOwlActivityAttributes>.activities where activity.id == id {
                    await activity.update(activityContent)
                }
            }
        } else if ActivityAuthorizationInfo().areActivitiesEnabled, UIApplication.shared.applicationState == .active {
            current = try? Activity.request(attributes: DarraOwlActivityAttributes(macName: state.macName), content: activityContent)
        }
    }

    /// "+1 h" left from the Live Activity or Siri: its new end shows at once
    /// (a timed session only; an agent's end is not known here).
    func extendLocally(by seconds: TimeInterval) {
        guard let current else { return }
        let id = current.id
        Task.detached {
            for activity in Activity<DarraOwlActivityAttributes>.activities where activity.id == id && activity.content.state.following == nil {
                var state = activity.content.state
                state.endsAt = max(state.endsAt, Date()).addingTimeInterval(seconds)
                await activity.update(ActivityContent(state: state, staleDate: state.endsAt))
            }
        }
    }

    /// Ends the activities there are now, at once: one left on screen would
    /// keep counting down to an end time that no longer holds. Ids are taken
    /// now, so an activity requested right after is not ended by mistake.
    func end() {
        let ids = Set(Activity<DarraOwlActivityAttributes>.activities.map(\.id))
        current = nil
        guard !ids.isEmpty else { return }
        Task.detached {
            for activity in Activity<DarraOwlActivityAttributes>.activities where ids.contains(activity.id) {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
