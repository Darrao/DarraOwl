import ActivityKit
import DarraOwlPhoneKit
import DarraOwlShared
import Foundation
import UIKit

/// The one PhoneModel of the app, shared by the UI, notifications, Siri and
/// the Live Activity buttons, plus what mirrors its state outside the app.
@MainActor
final class PhoneRuntime {
    static let shared = PhoneRuntime()

    let model: PhoneModel
    private let liveActivity = LiveActivityController()
    private var started = false

    private init() {
        model = PhoneModel(.init(
            store: KeychainPhoneStore(deviceName: UIDevice.current.name),
            direct: NWDirectLink(),
            cloud: CloudKitPhoneLink(),
            pairing: NWPairingDirect()
        ))
        model.onStateChange = { [weak self] state in self?.mirror(state) }
    }

    func start() async {
        guard !started else { return }
        started = true
        await model.start()
    }

    /// Siri and Live Activity buttons: sign and send, do not wait.
    func fire(_ kind: CommandKind) async -> Bool {
        await start()
        return await model.fire(kind)
    }

    func spokenStatus() async -> String {
        await start()
        await model.tick()
        guard let state = model.state else { return "Je ne trouve pas le Mac pour le moment." }
        var text: String
        switch model.presence {
        case .asleep: text = "\(state.macName) est en veille."
        case let .lastSeen(date): text = "\(state.macName) n'a pas donné de nouvelles depuis \(DurationText.clock(date))."
        default: text = "\(state.macName) est en ligne."
        }
        if let session = state.session {
            text += " Il reste éveillé jusqu'à \(DurationText.clock(session.endsAt))."
        } else {
            text += " Aucune session en cours."
        }
        if case let .percent(p)? = state.powerSnapshot?.battery { text += " Batterie à \(p) %." }
        return text
    }

    /// Live Activity and widgets follow every state the app receives,
    /// including in the background after an event push.
    private func mirror(_ state: MacState) {
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
        guard let session = state.session else {
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
            online: online
        )
        let activityContent = ActivityContent(state: content, staleDate: session.endsAt)
        if let current, current.activityState == .active {
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

    private func end() {
        guard current != nil || !Activity<DarraOwlActivityAttributes>.activities.isEmpty else { return }
        current = nil
        Task.detached {
            for activity in Activity<DarraOwlActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .default)
            }
        }
    }
}
