import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct DarraOwlWidgets: WidgetBundle {
    var body: some Widget {
        MacStatusWidget()
        DarraOwlLiveActivity()
    }
}

// MARK: Live Activity and Dynamic Island

struct DarraOwlLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DarraOwlActivityAttributes.self) { context in
            LockScreenActivityView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        OwlShape(awake: true).stroke(lineWidth: 1.6).frame(width: 22, height: 22)
                        Text(context.attributes.macName).font(.caption).lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    BatteryLabel(percent: context.state.battery, charging: context.state.charging)
                }
                DynamicIslandExpandedRegion(.center) {
                    Countdown(endsAt: context.state.endsAt)
                        .font(.system(size: 34, weight: .light).monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        if let following = context.state.following {
                            Text("Tant que \(following) tourne").font(.caption).lineLimit(1)
                        }
                        AgentsLine(running: context.state.agentsRunning, waiting: context.state.agentsWaiting)
                        HStack {
                            Button(intent: ExtendSessionIntent()) { Label("+1 h", systemImage: "plus") }
                                .buttonStyle(.bordered).tint(.white)
                            Button(intent: StopSessionIntent()) { Label("Arrêter", systemImage: "stop.fill") }
                                .buttonStyle(.bordered).tint(.red)
                        }
                    }
                }
            } compactLeading: {
                OwlShape(awake: true).stroke(lineWidth: 1.4).frame(width: 18, height: 18)
            } compactTrailing: {
                Countdown(endsAt: context.state.endsAt)
                    .font(.caption.monospacedDigit())
                    .frame(maxWidth: 52)
            } minimal: {
                OwlShape(awake: true).stroke(lineWidth: 1.4).frame(width: 16, height: 16)
            }
            .keylineTint(.white)
        }
    }
}

struct LockScreenActivityView: View {
    let context: ActivityViewContext<DarraOwlActivityAttributes>

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            OwlShape(awake: true).stroke(lineWidth: 2).frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(context.state.following.map { "\(context.attributes.macName) · tant que \($0) tourne" } ?? context.attributes.macName)
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                if context.isStale {
                    Text("Heure de fin passée").font(.title3)
                    Text("Ouvre DarraOwl pour l'état du Mac.").font(.caption)
                } else {
                    Countdown(endsAt: context.state.endsAt)
                        .font(.system(size: 30, weight: .light).monospacedDigit())
                }
                HStack(spacing: 10) {
                    BatteryLabel(percent: context.state.battery, charging: context.state.charging)
                    if context.state.lidClosed { Label("capot fermé", systemImage: "laptopcomputer").font(.caption) }
                    AgentsLine(running: context.state.agentsRunning, waiting: context.state.agentsWaiting)
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(spacing: 8) {
                Button(intent: ExtendSessionIntent()) { Text("+1 h") }.buttonStyle(.bordered).tint(.white)
                Button(intent: StopSessionIntent()) { Image(systemName: "stop.fill") }.buttonStyle(.bordered).tint(.red)
            }
        }
        .padding(16)
        .foregroundStyle(.white)
    }
}

struct Countdown: View {
    let endsAt: Date

    var body: some View {
        Text(timerInterval: Date()...max(Date(), endsAt), countsDown: true)
            .multilineTextAlignment(.center)
    }
}

struct BatteryLabel: View {
    let percent: Int?
    let charging: Bool

    var body: some View {
        if let percent {
            Label("\(percent) %", systemImage: charging ? "battery.100.bolt" : batterySymbol(percent))
                .font(.caption)
        }
    }

    private func batterySymbol(_ p: Int) -> String {
        switch p {
        case ..<15: "battery.0"
        case ..<40: "battery.25"
        case ..<65: "battery.50"
        case ..<90: "battery.75"
        default: "battery.100"
        }
    }
}

struct AgentsLine: View {
    let running: Int
    let waiting: Int

    var body: some View {
        if waiting > 0 {
            Label(waiting == 1 ? "Claude attend ta validation" : "\(waiting) agents attendent ta validation", systemImage: "hand.raised")
                .font(.caption).foregroundStyle(.orange)
        } else if running > 0 {
            Label(running == 1 ? "1 agent au travail" : "\(running) agents au travail", systemImage: "terminal")
                .font(.caption)
        }
    }
}

// MARK: Home and lock screen widget

struct StatusEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct StatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry { StatusEntry(date: Date(), snapshot: .placeholder) }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        completion(StatusEntry(date: Date(), snapshot: context.isPreview ? .placeholder : SharedStore.load()))
    }

    /// One entry now and one at the session's end, so the countdown gives
    /// way to "Veille normale" on time without a reload. The app reloads the
    /// timeline on every change.
    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        let now = Date()
        let snapshot = SharedStore.load()
        var entries = [StatusEntry(date: now, snapshot: snapshot)]
        if let end = snapshot?.sessionEndsAt, end > now {
            entries.append(StatusEntry(date: end, snapshot: snapshot))
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(1800))))
    }
}

struct MacStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MacStatus", provider: StatusProvider()) { entry in
            MacStatusWidgetView(entry: entry)
                .containerBackground(.black, for: .widget)
        }
        .configurationDisplayName("Mac")
        .description("Session, batterie et agents de ton Mac.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular])
    }
}

struct MacStatusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StatusEntry

    var body: some View {
        if let s = entry.snapshot {
            switch family {
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    if let end = s.sessionEndsAt, end > entry.date {
                        Countdown(endsAt: end).font(.caption2.monospacedDigit()).minimumScaleFactor(0.6)
                    } else {
                        OwlShape(awake: false).stroke(lineWidth: 1.4).padding(10)
                    }
                }
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.macName).font(.headline).lineLimit(1)
                    if let end = s.sessionEndsAt, end > entry.date {
                        HStack(spacing: 4) { Text("Éveillé"); Countdown(endsAt: end).monospacedDigit() }
                    } else {
                        Text(presence(s)).lineLimit(1)
                    }
                    if let b = s.battery { Text("Batterie \(b) %") }
                }
            default:
                full(s)
            }
        } else {
            VStack(spacing: 6) {
                OwlShape(awake: false).stroke(lineWidth: 2).frame(width: 30, height: 30)
                Text("Ouvre DarraOwl pour appairer ton Mac.").font(.caption).multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
        }
    }

    /// "En ligne…" only while it is recent: an old one says when it was true.
    private func presence(_ s: WidgetSnapshot) -> String {
        entry.date.timeIntervalSince(s.updatedAt) < 300 ? s.presence : "Vu à \(s.updatedAt.formatted(date: .omitted, time: .shortened))"
    }

    private func full(_ s: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                OwlShape(awake: s.sessionEndsAt.map { $0 > entry.date } ?? false).stroke(lineWidth: 1.6).frame(width: 22, height: 22)
                Text(s.macName).font(.caption).lineLimit(1)
                Spacer()
                Circle().fill(s.online ? Color.green : Color.gray).frame(width: 7, height: 7)
            }
            Spacer(minLength: 0)
            if let end = s.sessionEndsAt, end > entry.date {
                Countdown(endsAt: end).font(.system(size: family == .systemSmall ? 28 : 34, weight: .light).monospacedDigit())
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Fin à \(end.formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Veille normale").font(.title3)
                Text(presence(s)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 8) {
                BatteryLabel(percent: s.battery, charging: s.charging)
                if family == .systemMedium { AgentsLine(running: s.agentsRunning, waiting: s.agentsWaiting) }
            }
            .foregroundStyle(.secondary)
        }
        .foregroundStyle(.white)
    }
}
