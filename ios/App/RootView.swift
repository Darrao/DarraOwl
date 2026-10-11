import DarraOwlPhoneKit
import DarraOwlShared
import SwiftUI
import VisionKit

struct RootView: View {
    let model: PhoneModel

    var body: some View {
        if model.mac == nil {
            OnboardingView(model: model)
        } else {
            MacView(model: model)
        }
    }
}

// MARK: Onboarding

struct OnboardingView: View {
    let model: PhoneModel
    @State private var scanning = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        OwlShape(awake: true).stroke(lineWidth: 2.5).frame(width: 44, height: 44)
                        Text("DarraOwl").font(.largeTitle.bold())
                        Text("Garde ton Mac éveillé, capot fermé, et suis-le d'ici.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }
                Section("Avant de commencer") {
                    step(1, "Même compte iCloud que le Mac",
                         model.cloudProblem ?? "iCloud est disponible sur cet iPhone.",
                         ok: model.cloudProblem == nil)
                    step(2, "Sur le Mac", "Clique sur la chouette, puis iPhone…, puis Afficher le code d'appairage.", ok: nil)
                    step(3, "Notifications", "Après l'appairage, autorise-les : fin de session, batterie, chaleur, Claude.", ok: nil)
                }
                Section {
                    if DataScannerViewController.isSupported {
                        Button("Scanner le code") { scanning = true }
                    }
                    Button("Coller le lien du code") {
                        if let s = UIPasteboard.general.string, let url = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)) {
                            Task { await model.pair(url: url) }
                        }
                    }
                    if model.isPairing {
                        HStack { ProgressView(); Text("Appairage en cours…") }
                    }
                    if let error = model.pairingError {
                        Text(error).foregroundStyle(.red)
                    }
                } footer: {
                    Text("Le code ne sert qu'une fois et expire au bout de 5 minutes. Les clés restent dans le trousseau de cet iPhone.")
                }
            }
            .listStyle(.plain)
            .sheet(isPresented: $scanning) {
                QRScanner { url in
                    scanning = false
                    Task { await model.pair(url: url) }
                }
                .ignoresSafeArea()
            }
        }
    }

    private func step(_ n: Int, _ title: String, _ detail: String, ok: Bool?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(.headline.monospacedDigit()).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.footnote).foregroundStyle(ok == false ? .red : .secondary)
            }
        }
    }
}

/// VisionKit scanner limited to QR codes; returns the first darraowl:// link.
struct QRScanner: UIViewControllerRepresentable {
    let onFound: (URL) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onFound: (URL) -> Void
        var done = false
        init(onFound: @escaping (URL) -> Void) { self.onFound = onFound }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case let .barcode(code) in items {
                guard !done, let s = code.payloadStringValue, let url = URL(string: s), url.scheme == PairingInvite.scheme else { continue }
                done = true
                onFound(url)
            }
        }
    }
}

// MARK: Mac

struct MacView: View {
    let model: PhoneModel
    @State private var showSettings = false
    @State private var confirmStop = false
    @State private var confirmUnpair = false

    var body: some View {
        NavigationStack {
            List {
                Section { presenceLine }
                sessionSection
                if let state = model.state {
                    macSection(state)
                    networkSection(state)
                    if !state.containers.isEmpty || state.dockerPaused { dockerSection(state) }
                }
                Section {
                    Button("Mettre le Mac en veille", role: .destructive) {
                        Task { await model.send(.sleepNow) }
                    }
                    .disabled(!online)
                } footer: {
                    Text("Arrête la session, rétablit tout, puis met le Mac en veille. Demande Face ID.")
                }
                if let outcome = model.outcome {
                    Section { outcomeLine(outcome) }
                }
                Section {
                    Button("Désappairer cet iPhone", role: .destructive) { confirmUnpair = true }
                }
            }
            .listStyle(.plain)
            .navigationTitle(model.mac?.macName ?? "Mac")
            .toolbar {
                Button("Réglages") { showSettings = true }
                    .disabled(model.state == nil || !online)
            }
            .refreshable { await model.tick() }
            .sheet(isPresented: $showSettings) {
                if let state = model.state { SettingsSheet(model: model, settings: state.settings) }
            }
            .confirmationDialog("Arrêter la session ?", isPresented: $confirmStop, titleVisibility: .visible) {
                Button("Arrêter", role: .destructive) { Task { await model.send(.stopSession) } }
            }
            .confirmationDialog("Désappairer cet iPhone ?", isPresented: $confirmUnpair, titleVisibility: .visible) {
                Button("Désappairer", role: .destructive) { model.unpair() }
            } message: {
                Text("Sur le Mac, retire aussi cet iPhone dans DarraOwl > iPhone… pour couper son accès.")
            }
        }
    }

    private var online: Bool {
        if case .online = model.presence { return true }
        return false
    }

    @ViewBuilder
    private var presenceLine: some View {
        switch model.presence {
        case let .online(path):
            Label("En ligne, par \(path.label)", systemImage: "circle.fill").foregroundStyle(.primary)
        case let .asleep(since):
            Label("En veille depuis \(since.formatted(date: .omitted, time: .shortened))", systemImage: "moon")
        case let .lastSeen(date):
            Label("Vu pour la dernière fois à \(date.formatted(date: .omitted, time: .shortened))", systemImage: "circle")
                .foregroundStyle(.secondary)
        case .unknown:
            Label(model.cloudProblem ?? "Recherche du Mac…", systemImage: "circle.dashed").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var sessionSection: some View {
        Section("Session") {
            if let session = model.state?.session {
                VStack(alignment: .leading, spacing: 4) {
                    Text(timerInterval: Date()...max(Date(), session.endsAt), countsDown: true)
                        .font(.system(size: 44, weight: .light).monospacedDigit())
                    Text("Fin à \(DurationText.clock(session.endsAt))").foregroundStyle(.secondary)
                }
                HStack {
                    ForEach([30, 60], id: \.self) { m in
                        Button("+\(DurationText.short(TimeInterval(m * 60)))") {
                            Task { await model.send(.extendSession(minutes: m)) }
                        }
                        .buttonStyle(.bordered)
                    }
                    Spacer()
                    Button("Arrêter", role: .destructive) { confirmStop = true }
                        .buttonStyle(.bordered)
                }
                .disabled(model.isBusy || !online)
            } else {
                Text("Aucune session").foregroundStyle(.secondary)
                HStack {
                    ForEach(Policy.quickDurations, id: \.self) { d in
                        Button(DurationText.short(d)) {
                            Task { await model.send(.startSession(minutes: Int(d / 60))) }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .disabled(model.isBusy || !online)
            }
        }
    }

    private func macSection(_ s: MacState) -> some View {
        Section("Mac") {
            if let p = s.powerSnapshot {
                LabeledContent("Batterie", value: batteryText(p))
                if let m = p.minutesToEmpty { LabeledContent("Autonomie estimée", value: DurationText.short(TimeInterval(m * 60))) }
                LabeledContent("Température", value: p.thermal.label)
                if let lid = p.lidClosed { LabeledContent("Capot", value: lid ? "fermé" : "ouvert") }
            }
            if s.lowPowerActive { LabeledContent("Économie d'énergie", value: "activée") }
            if !s.pausedApps.isEmpty { LabeledContent("En pause", value: s.pausedApps.joined(separator: ", ")) }
        }
    }

    private func networkSection(_ s: MacState) -> some View {
        Section("Réseau") {
            LabeledContent("Connexion", value: networkText(s.network))
            if let name = s.network?.name { LabeledContent("Réseau", value: name) }
            if let bytes = s.network?.sessionBytes { LabeledContent("Data de la session", value: ByteText.short(bytes)) }
        }
    }

    private func dockerSection(_ s: MacState) -> some View {
        Section("Docker") {
            if s.dockerPaused {
                Button("Relancer Docker Desktop") { Task { await model.send(.resumeDocker) } }
            } else if s.session != nil, s.containers.isEmpty {
                Button("Mettre Docker Desktop en pause") { Task { await model.send(.pauseDocker) } }
            }
            ForEach(s.containers) { c in
                HStack {
                    Text(c.name)
                    Spacer()
                    Button("Arrêter", role: .destructive) { Task { await model.send(.stopContainer(id: c.id)) } }
                        .buttonStyle(.borderless)
                }
            }
        }
        .disabled(model.isBusy || !online)
    }

    @ViewBuilder
    private func outcomeLine(_ o: PhoneModel.Outcome) -> some View {
        switch o {
        case let .sending(label): HStack { ProgressView(); Text("\(label)…") }
        case let .done(text): Text(text)
        case let .failed(text): Text(text).foregroundStyle(.red)
        }
    }

    private func batteryText(_ p: PowerSnapshot) -> String {
        let level: String
        switch p.battery {
        case let .percent(v): level = "\(v) %"
        case .unreadable: level = "illisible"
        case .none: level = "aucune"
        }
        return level + (p.onExternalPower ? ", sur secteur" : ", sur batterie")
    }

    private func networkText(_ n: MacState.Network?) -> String {
        switch n?.kind {
        case .wifi?: "Wi-Fi"
        case .hotspot?: "Partage de connexion"
        case .ethernet?: "Ethernet"
        case .other?: "Autre"
        case .none?, nil: "Aucune"
        }
    }
}

// MARK: Settings

struct SettingsSheet: View {
    let model: PhoneModel
    @State var settings: PowerSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Capot fermé, pendant une session") {
                    Toggle("Éteindre l'écran et le clavier", isOn: $settings.lid.darkenDisplay)
                    Toggle("Couper le son", isOn: $settings.lid.mute)
                    Toggle("Mode économie d'énergie", isOn: $settings.lid.lowPower)
                    Toggle("Docker en pause sans conteneur", isOn: $settings.lid.pauseDocker)
                }
                Section("Alertes") {
                    Toggle("Antivol : capot ouvert, chargeur débranché", isOn: $settings.alerts.antitheft)
                    Stepper("Fin de session : \(settings.alerts.endingSoonMinutes) min avant", value: $settings.alerts.endingSoonMinutes,
                            in: AlertSettings.endingSoonRange, step: 5)
                    Stepper("Data : au-delà de \(ByteText.short(Int64(settings.alerts.dataThresholdMB) * 1_000_000))",
                            value: $settings.alerts.dataThresholdMB, in: AlertSettings.dataThresholdRange, step: 250)
                    Toggle("Masquer les noms de projets", isOn: $settings.alerts.maskProjectNames)
                }
                Section("Batterie") {
                    Stepper("Économie d'énergie sous \(settings.lowPowerFloor) %", value: $settings.lowPowerFloor,
                            in: (settings.endFloor + Policy.floorGap)...Policy.maxLowPowerFloor, step: 5)
                    Stepper("Fin de session sous \(settings.endFloor) %", value: $settings.endFloor, in: Policy.endFloorRange, step: 5)
                        .onChange(of: settings.endFloor) { _, new in
                            if settings.lowPowerFloor < new + Policy.floorGap { settings.lowPowerFloor = new + Policy.floorGap }
                        }
                }
            }
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Envoyer") {
                        let original = model.state?.settings
                        Task {
                            if settings.lid != original?.lid { await model.send(.updateLidSettings(settings.lid)) }
                            if settings.alerts != original?.alerts { await model.send(.updateAlerts(settings.alerts)) }
                            if settings.lowPowerFloor != original?.lowPowerFloor || settings.endFloor != original?.endFloor {
                                await model.send(.updateBatteryFloors(lowPower: settings.lowPowerFloor, end: settings.endFloor))
                            }
                        }
                        dismiss()
                    }
                }
            }
        }
    }
}

/// The monochrome owl, same drawing as the Mac's menu bar icon.
struct OwlShape: Shape {
    var awake: Bool

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 18
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + (18 - y) * s) }
        var path = Path()
        path.move(to: p(4, 15.5))
        path.addLine(to: p(6.5, 13.6))
        path.addCurve(to: p(11.5, 13.6), control1: p(8, 14.3), control2: p(10, 14.3))
        path.addLine(to: p(14, 15.5))
        path.addCurve(to: p(9, 1.5), control1: p(16, 9), control2: p(14, 1.5))
        path.addCurve(to: p(4, 15.5), control1: p(4, 1.5), control2: p(2, 9))
        path.closeSubpath()
        for x in [6.6, 11.4] {
            if awake {
                path.addEllipse(in: CGRect(origin: p(x - 2.2, 12.4), size: CGSize(width: 4.4 * s, height: 4.4 * s)))
            } else {
                path.move(to: p(x - 2, 10.4))
                path.addQuadCurve(to: p(x + 2, 10.4), control: p(x, 9.2))
            }
        }
        path.move(to: p(8.2, 7.6))
        path.addLine(to: p(9.8, 7.6))
        path.addLine(to: p(9, 5.9))
        path.closeSubpath()
        return path
    }
}
