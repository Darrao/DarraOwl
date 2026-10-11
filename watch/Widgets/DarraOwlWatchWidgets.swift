import SwiftUI
import WidgetKit

@main
struct DarraOwlWatchWidgets: WidgetBundle {
    var body: some Widget {
        MacComplication()
    }
}

struct MacEntry: TimelineEntry {
    let date: Date
    let snapshot: ComplicationSnapshot?
}

struct MacProvider: TimelineProvider {
    func placeholder(in context: Context) -> MacEntry {
        MacEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (MacEntry) -> Void) {
        completion(MacEntry(date: Date(), snapshot: context.isPreview ? .placeholder : ComplicationStore.load()))
    }

    /// One entry now; another when the session ends, so the face drops the countdown.
    func getTimeline(in context: Context, completion: @escaping (Timeline<MacEntry>) -> Void) {
        let now = Date()
        let snapshot = ComplicationStore.load()
        var entries = [MacEntry(date: now, snapshot: snapshot)]
        if let end = snapshot?.sessionEndsAt, end > now {
            var after = snapshot
            after?.sessionStartedAt = nil
            after?.sessionEndsAt = nil
            after?.following = nil
            entries.append(MacEntry(date: end, snapshot: after))
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60))))
    }
}

struct MacComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DarraOwlMac", provider: MacProvider()) { entry in
            MacComplicationView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Mac")
        .description("Session et batterie du Mac.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

struct MacComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MacEntry

    private var session: (start: Date, end: Date)? {
        guard let s = entry.snapshot, let start = s.sessionStartedAt, let end = s.sessionEndsAt, end > entry.date else { return nil }
        return (start, end)
    }

    var body: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .accessoryInline: inline
        default: corner
        }
    }

    private var owl: some View {
        OwlShape(awake: session != nil).stroke(lineWidth: 1.5)
    }

    @ViewBuilder
    private var circular: some View {
        if let session {
            ProgressView(timerInterval: session.start...session.end, countsDown: true) {
                EmptyView()
            } currentValueLabel: {
                owl.frame(width: 20, height: 20)
            }
            .progressViewStyle(.circular)
        } else {
            ZStack {
                AccessoryWidgetBackground()
                owl.frame(width: 24, height: 24)
            }
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                owl.frame(width: 14, height: 14)
                Text(entry.snapshot?.macName ?? "Mac").font(.headline).lineLimit(1)
            }
            if let session {
                Text(timerInterval: entry.date...session.end, countsDown: true).font(.body.monospacedDigit())
                Text(entry.snapshot?.following.map { "tant que \($0) tourne" } ?? "éveillé")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text("Veille normale").font(.body)
            }
            if let battery = entry.snapshot?.battery {
                Text("\(battery) %\(entry.snapshot?.charging == true ? ", sur secteur" : "")").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var inline: some View {
        if let session {
            Text("Mac éveillé \(Text(timerInterval: entry.date...session.end, countsDown: true))")
        } else {
            Text("Mac : veille normale")
        }
    }

    private var corner: some View {
        owl.frame(width: 20, height: 20)
            .widgetLabel {
                if let session {
                    Text(timerInterval: entry.date...session.end, countsDown: true)
                } else if let battery = entry.snapshot?.battery {
                    Text("\(battery) %")
                }
            }
    }
}
