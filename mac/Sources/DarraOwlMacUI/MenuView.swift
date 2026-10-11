import DarraOwlShared
import SwiftUI

struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: OwlIcon.image(awake: model.session != nil))
            if let remaining = model.remaining {
                Text(DurationText.countdown(remaining))
                    .monospacedDigit()
            }
        }
    }
}

struct MenuView: View {
    @Bindable var model: AppModel
    @State private var freeText = ""
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.registration != .enabled || !model.reachable {
                setup
            } else if let session = model.session {
                active(session)
            } else {
                idle
            }
            messages
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 300)
        .task { await model.refresh() }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("DarraOwl").font(.headline)
            Text(stateLine).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var stateLine: String {
        if let session = model.session {
            return "Éveillé jusqu'à \(DurationText.clock(session.endsAt))"
        }
        return "Veille normale"
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.registration.label).font(.callout)
            switch model.registration {
            case .notRegistered:
                Text("DarraOwl a besoin d'un composant système pour désactiver la veille et la rétablir à l'heure de fin, même si l'app est fermée.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Installer le composant système") { model.installHelper() }
            case .requiresApproval:
                Text("Dans Réglages Système, section Ouverture, active DarraOwl sous « Autoriser en arrière-plan ».")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Ouvrir Réglages Système") { model.openApprovalSettings() }
            case .notFound:
                Text("Réinstalle DarraOwl dans le dossier Applications.")
                    .font(.caption).foregroundStyle(.secondary)
            case .enabled:
                Text("Le composant système ne répond pas encore.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Réessayer") { Task { await model.refresh() } }
            }
        }
    }

    private func active(_ session: Session) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(DurationText.countdown(model.remaining ?? 0))
                .font(.system(size: 32, weight: .light).monospacedDigit())
                .contentTransition(.numericText())
            powerLine
            HStack {
                ForEach(Policy.extensionSteps, id: \.self) { step in
                    Button("+\(DurationText.short(step))") { model.extend(seconds: step) }
                }
            }
            .disabled(model.busy)
            HoldToStopButton { model.stopSession() }
        }
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Garder éveillé").font(.callout)
            HStack {
                ForEach(Policy.quickDurations, id: \.self) { duration in
                    Button(DurationText.short(duration)) { model.startSession(seconds: duration) }
                        .keyboardShortcut(duration == Policy.defaultSessionDuration ? .defaultAction : nil)
                }
            }
            HStack {
                TextField("Durée libre, ex. 1h30", text: $freeText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(startFree)
                Button("Démarrer", action: startFree)
                    .disabled(DurationText.parse(freeText) == nil)
            }
            powerLine
        }
        .disabled(model.busy)
    }

    @ViewBuilder
    private var powerLine: some View {
        if let power = model.status?.power {
            Text(powerText(power)).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var messages: some View {
        if let error = model.lastError {
            Text(error).font(.caption).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let status = model.status {
            if !status.pendingUndo.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Restauration incomplète, nouvel essai en cours :").font(.caption).bold()
                    ForEach(status.pendingUndo, id: \.self) { Text($0).font(.caption) }
                }
                .foregroundStyle(.orange)
            }
            ForEach(status.notices, id: \.self) { notice in
                Text(notice).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.session == nil, let end = status.lastEnd {
                Text("Dernière session : \(end.reason.label.lowercased()) à \(DurationText.clock(end.endedAt))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Réglages…") {
                // A menu bar app is never active by itself: bring the window forward.
                NSApp.activate()
                openSettings()
            }
            Spacer()
            Button(model.session == nil ? "Quitter" : "Arrêter et quitter") { model.quit() }
        }
        .buttonStyle(.borderless)
    }

    // MARK: Helpers

    private func startFree() {
        guard let seconds = DurationText.parse(freeText) else { return }
        model.startSession(seconds: seconds)
        freeText = ""
    }

    private func powerText(_ power: PowerSnapshot) -> String {
        var parts: [String] = []
        switch power.battery {
        case let .percent(p): parts.append("Batterie \(p) %")
        case .unreadable: parts.append("Batterie illisible")
        case .none: break
        }
        parts.append(power.onExternalPower ? "sur secteur" : "sur batterie")
        if power.thermal != .nominal { parts.append("température : \(power.thermal.label.lowercased())") }
        if model.status?.lowPowerHeld == true { parts.append("économie d'énergie activée") }
        return parts.joined(separator: " · ")
    }
}

/// Ends the session only after a 1.5 s press, so a stray click does nothing.
struct HoldToStopButton: View {
    let action: () -> Void
    @State private var progress: CGFloat = 0
    static let duration = 1.5

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.secondary.opacity(0.15))
            GeometryReader { geo in
                Capsule().fill(Color.primary.opacity(0.25))
                    .frame(width: geo.size.width * progress)
            }
            Text(progress > 0 ? "Continue d'appuyer…" : "Maintenir pour arrêter")
                .font(.callout)
                .frame(maxWidth: .infinity)
        }
        .frame(height: 28)
        .contentShape(Capsule())
        .onLongPressGesture(minimumDuration: Self.duration) {
            progress = 0
            action()
        } onPressingChanged: { pressing in
            withAnimation(pressing ? .linear(duration: Self.duration) : .easeOut(duration: 0.2)) {
                progress = pressing ? 1 : 0
            }
        }
        .accessibilityLabel("Arrêter la session")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }
}
