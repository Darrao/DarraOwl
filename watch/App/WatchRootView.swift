import DarraOwlShared
import SwiftUI

struct WatchRootView: View {
    @Bindable var model: WatchModel
    @State private var confirmStop = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    if let state = model.state {
                        session(state)
                        if !state.agents.isEmpty { agents(state) }
                        controls(state)
                        macLine(state)
                    } else {
                        Text("Ouvre DarraOwl sur l'iPhone et appaire ton Mac.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let message = model.message {
                        Text(message).font(.footnote).foregroundStyle(model.failed ? .red : .secondary)
                    }
                }
                .scenePadding(.horizontal)
            }
            .disabled(model.busy)
        }
        .task {
            model.start()
            await model.refresh()
        }
    }

    /// What the iPhone said, unless it said it long ago: then when.
    private var presenceText: String {
        guard let snapshot = model.snapshot else { return "Recherche de l'iPhone…" }
        if snapshot.state != nil, Date().timeIntervalSince(snapshot.at) > 180 {
            return "Dernières nouvelles à \(DurationText.clock(snapshot.at))"
        }
        return snapshot.presence
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 8) {
            OwlShape(awake: model.state?.session != nil).stroke(lineWidth: 1.6).frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(model.snapshot?.macName ?? "Mac").font(.headline).lineLimit(1)
                Text(presenceText).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private func session(_ state: MacState) -> some View {
        if let session = state.session {
            VStack(alignment: .leading, spacing: 2) {
                Text(timerInterval: Date()...max(Date(), session.endsAt), countsDown: true)
                    .font(.system(size: 34, weight: .light, design: .rounded).monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(session.whileWatchingText ?? "jusqu'à \(DurationText.clock(session.endsAt))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack {
                Button("+30 min") { Task { await model.send(.extendSession(minutes: 30)) } }
                Button("+1 h") { Task { await model.send(.extendSession(minutes: 60)) } }
            }
            Button("Arrêter", role: .destructive) { confirmStop = true }
                .confirmationDialog("Le Mac retrouvera sa veille normale.", isPresented: $confirmStop) {
                    Button("Arrêter la session", role: .destructive) { Task { await model.send(.stopSession) } }
                }
        } else {
            Text("Veille normale").font(.title3)
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    startButton(30)
                    startButton(60)
                }
                GridRow {
                    startButton(120)
                    startButton(240)
                }
            }
        }
    }

    private func startButton(_ minutes: Int) -> some View {
        Button(DurationText.short(TimeInterval(minutes * 60))) { Task { await model.send(.startSession(minutes: minutes)) } }
    }

    private func agents(_ state: MacState) -> some View {
        let watched = Set(state.session?.watching.map(\.pid) ?? [])
        return VStack(alignment: .leading, spacing: 6) {
            Text("Agents").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(state.agents.enumerated()), id: \.offset) { _, agent in
                VStack(alignment: .leading, spacing: 4) {
                    Text(agent.project.map { "\(agent.tool) · \($0)" } ?? agent.tool).font(.footnote).lineLimit(1)
                    if agent.waitingForApproval {
                        Text("attend ta validation").font(.caption2).foregroundStyle(.orange)
                    }
                    if let pid = agent.pid {
                        if watched.contains(pid) {
                            Text("suivi").font(.caption2).foregroundStyle(.secondary)
                        } else {
                            Button("Suivre") { Task { await model.send(.watchAgent(pid: pid)) } }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func controls(_ state: MacState) -> some View {
        if let presence = state.presence {
            VStack(alignment: .leading, spacing: 6) {
                Text("Contrôles").font(.caption).foregroundStyle(.secondary)
                Toggle("Toujours actif", isOn: Binding(
                    get: { presence.active },
                    set: { on in Task { await model.send(on ? .startPresence(minutes: nil) : .stopPresence) } }
                ))
                Button { Task { await model.send(.displayOff) } } label: { Label("Éteindre l'écran", systemImage: "display") }
                Button { Task { await model.send(.lockScreen) } } label: { Label("Verrouiller", systemImage: "lock.fill") }
                if let muted = state.muted {
                    Button { Task { await model.send(.setMuted(!muted)) } } label: {
                        Label(muted ? "Remettre le son" : "Couper le son", systemImage: muted ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    }
                }
            }
        }
    }

    private func macLine(_ state: MacState) -> some View {
        var parts: [String] = []
        if let p = state.powerSnapshot {
            if let percent = p.battery.percent { parts.append("Batterie \(percent) %") }
            parts.append(p.onExternalPower ? "sur secteur" : "sur batterie")
            if p.lidClosed == true { parts.append("capot fermé") }
        }
        return Text(parts.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
    }
}
