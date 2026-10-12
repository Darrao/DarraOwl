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
                    ActivityOwl(state: context.state, lineWidth: 1.6).frame(width: 22, height: 22)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    BatteryLabel(percent: context.state.battery, charging: context.state.charging)
                }
                DynamicIslandExpandedRegion(.center) {
                    if context.state.ended == true {
                        Text("Session terminée").font(.title3)
                    } else {
                        Countdown(endsAt: context.state.endsAt)
                            .font(.system(size: 30, weight: .light).monospacedDigit())
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    // The expanded island is 160 pt tall at most: one line,
                    // then the buttons.
                    VStack(spacing: 6) {
                        if context.state.ended != true { IslandLine(state: context.state) }
                        // Past its end time the session may be over: no
                        // button that would act on a guess.
                        if !context.isStale, context.state.ended != true {
                            HStack {
                                Button(intent: ExtendSessionIntent()) { Text("+1 h") }
                                    .buttonStyle(.bordered).tint(.white)
                                Button(intent: StopSessionIntent()) { Label("Arrêter", systemImage: "stop.fill") }
                                    .buttonStyle(.bordered).tint(.red)
                            }
                        }
                    }
                }
            } compactLeading: {
                ActivityOwl(state: context.state, lineWidth: 1.4).frame(width: 18, height: 18)
            } compactTrailing: {
                if context.state.ended == true {
                    Text("Fin").font(.caption)
                } else {
                    // Wide enough for "23:59:59": a session following an
                    // agent can last up to 24 h.
                    Countdown(endsAt: context.state.endsAt)
                        .font(.caption.monospacedDigit())
                        .frame(maxWidth: 64)
                }
            } minimal: {
                ActivityOwl(state: context.state, lineWidth: 1.4).frame(width: 16, height: 16)
            }
            .keylineTint(.white)
        }
    }
}

struct LockScreenActivityView: View {
    let context: ActivityViewContext<DarraOwlActivityAttributes>

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ActivityOwl(state: context.state, lineWidth: 2).frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(context.state.following.map { "\(context.attributes.macName) · \($0)" } ?? context.attributes.macName)
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                if context.state.ended == true {
                    Text("Session terminée").font(.title3)
                    Text("Veille normale rétablie.").font(.caption)
                } else if context.isStale {
                    Text("Heure de fin passée").font(.title3)
                    Text("Ouvre DarraOwl pour l'état du Mac.").font(.caption)
                } else {
                    Countdown(endsAt: context.state.endsAt)
                        .font(.system(size: 30, weight: .light).monospacedDigit())
                }
                // Over: the battery and agents of then are no news.
                if context.state.ended != true {
                    HStack(spacing: 10) {
                        BatteryLabel(percent: context.state.battery, charging: context.state.charging)
                        if context.state.lidClosed { Label("capot fermé", systemImage: "laptopcomputer").font(.caption) }
                        AgentsLine(running: context.state.agentsRunning, waiting: context.state.agentsWaiting)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !context.isStale, context.state.ended != true {
                VStack(spacing: 8) {
                    Button(intent: ExtendSessionIntent()) { Text("+1 h") }.buttonStyle(.bordered).tint(.white)
                    Button(intent: StopSessionIntent()) { Image(systemName: "stop.fill") }.buttonStyle(.bordered).tint(.red)
                }
            }
        }
        .padding(16)
        .foregroundStyle(.white)
    }
}

/// The Live Activity's owl. iOS plays no animation in a loop there, only
/// the change from one drawing to the next: the eyes blink with each new
/// state (see `OwlEyes.swapLids`), and close when the session is over.
struct ActivityOwl: View {
    let state: DarraOwlActivityAttributes.ContentState
    var lineWidth: CGFloat

    var body: some View {
        OwlShape(openness: state.ended == true ? 0 : 1, swapLids: (state.revision ?? 0) % 2 == 1)
            .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
    }
}

/// The one line the expanded island has room for: an agent waiting for
/// approval first, then the agent followed, then the agents at work.
struct IslandLine: View {
    let state: DarraOwlActivityAttributes.ContentState

    var body: some View {
        if let following = state.following, state.agentsWaiting == 0 {
            Text(following.prefix(1).uppercased() + following.dropFirst())
                .font(.caption).lineLimit(1).truncationMode(.middle)
        } else {
            AgentsLine(running: state.agentsRunning, waiting: state.agentsWaiting)
        }
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
        // Not a Label: a narrow place (the island's corner) shows only its icon.
        if let percent {
            HStack(spacing: 3) {
                Image(systemName: charging ? "battery.100.bolt" : batterySymbol(percent))
                Text("\(percent) %")
            }
            .font(.caption)
            .fixedSize()
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

    /// One entry now, one when "En ligne" gets too old to be said, and one
    /// at the session's end, so the countdown gives way to "Veille normale"
    /// on time without a reload. The app reloads the timeline on every change.
    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        let now = Date()
        let snapshot = SharedStore.load()
        var dates = [now]
        if let snapshot {
            let aged = snapshot.updatedAt.addingTimeInterval(MacStatusWidgetView.freshFor)
            if aged > now { dates.append(aged) }
        }
        if let end = snapshot?.sessionEndsAt, end > now { dates.append(end) }
        let entries = dates.sorted().map { StatusEntry(date: $0, snapshot: snapshot) }
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

    /// How long the presence and the dot are said as they were.
    static let freshFor: TimeInterval = 300

    private func fresh(_ s: WidgetSnapshot) -> Bool {
        entry.date.timeIntervalSince(s.updatedAt) < Self.freshFor
    }

    /// "En ligne…" only while it is recent: an old one says when it was true.
    private func presence(_ s: WidgetSnapshot) -> String {
        fresh(s) ? s.presence : "Vu à \(s.updatedAt.formatted(date: .omitted, time: .shortened))"
    }

    private func full(_ s: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                OwlShape(awake: s.sessionEndsAt.map { $0 > entry.date } ?? false).stroke(lineWidth: 1.6).frame(width: 22, height: 22)
                Text(s.macName).font(.caption).lineLimit(1)
                Spacer()
                Circle().fill(s.online && fresh(s) ? Color.green : Color.gray).frame(width: 7, height: 7)
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
