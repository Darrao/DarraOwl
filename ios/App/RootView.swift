import DarraOwlPhoneKit
import DarraOwlShared
import SwiftUI
import VisionKit

struct RootView: View {
    let runtime: PhoneRuntime

    var body: some View {
        if runtime.model.mac == nil {
            OnboardingView(model: runtime.model) { runtime.enterDemo() }
        } else {
            MacView(model: runtime.model, demo: runtime.isDemo) { runtime.leaveDemo() }
        }
    }
}

// MARK: Onboarding

struct OnboardingView: View {
    let model: PhoneModel
    let showDemo: () -> Void
    @State private var scanning = false

    private var canScan: Bool { DataScannerViewController.isSupported || DemoMode.isOn }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                VStack(alignment: .leading, spacing: 12) {
                    OwlShape(awake: true).stroke(lineWidth: 2.4).frame(width: 52, height: 52)
                    Text("DarraOwl").font(.largeTitle.bold())
                    Text("Garde ton Mac éveillé capot fermé, le temps qu'il faut, et suis-le d'ici.")
                        .font(.title3).foregroundStyle(.secondary)
                }
                .padding(.top, 40)

                VStack(alignment: .leading, spacing: 18) {
                    SectionTitle("Avant de commencer")
                    step(1, "Même compte iCloud que le Mac",
                         model.cloudProblem ?? "iCloud est disponible sur cet iPhone.", ok: model.cloudProblem == nil)
                    step(2, "DarraOwl sur le Mac",
                         "Clique sur la chouette dans la barre des menus, puis iPhone…, puis Afficher le code d'appairage.", ok: nil)
                    step(3, "Notifications",
                         "Après l'appairage, autorise-les : fin de session, batterie, chaleur, Claude.", ok: nil)
                }

                VStack(spacing: 12) {
                    if canScan {
                        Button { scanning = true } label: {
                            Label("Scanner le code d'appairage", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                    }
                    Button {
                        if let s = UIPasteboard.general.string, let url = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)) {
                            Task { await model.pair(url: url) }
                        }
                    } label: {
                        Text("Coller le lien du code").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    if model.isPairing {
                        HStack { ProgressView(); Text("Appairage en cours…") }.foregroundStyle(.secondary)
                    }
                    if let error = model.pairingError {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                }

                Text("Le code ne sert qu'une fois et expire au bout de 5 minutes. Les clés restent dans le trousseau de cet iPhone, rien ne passe par un serveur tiers.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Pas encore de Mac prêt ? Voir une démonstration", action: showDemo)
                    .font(.footnote)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .sheet(isPresented: $scanning) {
            QRScanner { url in
                scanning = false
                Task { await model.pair(url: url) }
            }
            .ignoresSafeArea()
        }
    }

    private func step(_ n: Int, _ title: String, _ detail: String, ok: Bool?) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1)
                if ok == true {
                    Image(systemName: "checkmark").font(.caption.bold())
                } else {
                    Text("\(n)").font(.footnote.weight(.semibold))
                }
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.subheadline).foregroundStyle(ok == false ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
    var demo = false
    var leaveDemo: () -> Void = {}
    @State private var showSettings = false
    @State private var confirmStop = false
    @State private var confirmUnpair = false
    @State private var customHours = 3

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    if demo, !DemoMode.isOn {
                        HStack {
                            Label("Démonstration : aucun Mac n'est piloté.", systemImage: "eye")
                                .font(.footnote).foregroundStyle(.secondary)
                            Spacer()
                            Button("Quitter", action: leaveDemo).font(.footnote.weight(.semibold))
                        }
                        .padding(.top, 8)
                    }
                    header
                    sessionBlock
                    if let state = model.state {
                        if !state.agents.isEmpty { agentsBlock(state) }
                        macBlock(state)
                        if !state.containers.isEmpty || state.dockerPaused { dockerBlock(state) }
                    }
                    if let outcome = model.outcome { outcomeLine(outcome) }
                    footerActions
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
            .refreshable { await model.tick() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Réglages")
                        .disabled(model.state == nil || !online)
                }
            }
            .sheet(isPresented: $showSettings) {
                if let state = model.state { SettingsSheet(model: model, settings: state.settings) }
            }
        }
    }

    private var online: Bool {
        if case .online = model.presence { return true }
        return false
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            OwlShape(awake: model.state?.session != nil).stroke(lineWidth: 2.2).frame(width: 40, height: 40)
            Text(model.mac?.macName ?? "Mac").font(.largeTitle.bold()).lineLimit(1).minimumScaleFactor(0.7)
            HStack(spacing: 8) {
                Circle().fill(presenceColor).frame(width: 8, height: 8)
                Text(presenceText).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
    }

    private var presenceColor: Color {
        switch model.presence {
        case .online: .green
        case .asleep: .indigo
        case .lastSeen, .unknown: .gray
        }
    }

    private var presenceText: String {
        switch model.presence {
        case let .online(path): "En ligne, par \(path.label)"
        case let .asleep(since): "En veille depuis \(since.formatted(date: .omitted, time: .shortened))"
        case let .lastSeen(date): "Vu pour la dernière fois à \(date.formatted(date: .omitted, time: .shortened))"
        case .unknown: model.cloudProblem ?? "Recherche du Mac…"
        }
    }

    // MARK: Session

    @ViewBuilder
    private var sessionBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle("Session")
            if let session = model.state?.session {
                VStack(alignment: .leading, spacing: 6) {
                    Text(timerInterval: Date()...max(Date(), session.endsAt), countsDown: true)
                        .font(.system(size: 64, weight: .thin).monospacedDigit())
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text("Fin à \(DurationText.clock(session.endsAt))").foregroundStyle(.secondary)
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        ProgressView(value: progress(session, at: context.date))
                            .tint(.primary)
                    }
                    .padding(.top, 6)
                }
                HStack(spacing: 12) {
                    ForEach([30, 60], id: \.self) { m in
                        Button("+\(DurationText.short(TimeInterval(m * 60)))") {
                            Task { await model.send(.extendSession(minutes: m)) }
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                    }
                }
                .disabled(model.isBusy || !online)
                Button(role: .destructive) { confirmStop = true } label: {
                    Text("Arrêter la session").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .disabled(model.isBusy || !online)
                .confirmationDialog("Le Mac retrouvera sa veille normale.", isPresented: $confirmStop, titleVisibility: .visible) {
                    Button("Arrêter la session", role: .destructive) { Task { await model.send(.stopSession) } }
                    Button("Annuler", role: .cancel) {}
                }
            } else {
                Text(online ? "Le Mac dort normalement." : "Le Mac doit être en ligne pour démarrer une session.")
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(Policy.quickDurations, id: \.self) { d in
                        Button {
                            Task { await model.send(.startSession(minutes: Int(d / 60))) }
                        } label: {
                            Text(DurationText.short(d)).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                    }
                }
                HStack {
                    Stepper("Autre durée : \(customHours) h", value: $customHours, in: 1...12)
                    Button("Démarrer") { Task { await model.send(.startSession(minutes: customHours * 60)) } }
                        .buttonStyle(.glassProminent)
                }
                .disabled(model.isBusy || !online)
            }
        }
        .disabled(model.isBusy || !online)
    }

    private func progress(_ s: Session, at date: Date) -> Double {
        let total = s.endsAt.timeIntervalSince(s.startedAt)
        guard total > 0 else { return 1 }
        return min(1, max(0, date.timeIntervalSince(s.startedAt) / total))
    }

    // MARK: Agents

    private func agentsBlock(_ s: MacState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Agents")
            ForEach(Array(s.agents.enumerated()), id: \.offset) { _, agent in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "terminal").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.project.map { "\(agent.tool) · \($0)" } ?? agent.tool).font(.body.weight(.medium))
                        Text("depuis \(agent.since.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if agent.waitingForApproval {
                        Text("attend ta validation").font(.caption.weight(.medium)).foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    // MARK: Mac

    private func macBlock(_ s: MacState) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle("Mac").padding(.bottom, 6)
            if let p = s.powerSnapshot {
                InfoRow("Batterie", batteryText(p), symbol: p.onExternalPower ? "battery.100.bolt" : "battery.75")
                if let m = p.minutesToEmpty { InfoRow("Autonomie estimée", DurationText.short(TimeInterval(m * 60)), symbol: "clock") }
                InfoRow("Température", p.thermal.label, symbol: "thermometer.medium")
                if let lid = p.lidClosed { InfoRow("Capot", lid ? "fermé" : "ouvert", symbol: "laptopcomputer") }
            }
            if s.lowPowerActive { InfoRow("Économie d'énergie", "activée", symbol: "leaf") }
            InfoRow("Réseau", networkText(s.network), symbol: s.network?.kind == .hotspot ? "personalhotspot" : "wifi")
            if let bytes = s.network?.sessionBytes { InfoRow("Data de la session", ByteText.short(bytes), symbol: "arrow.up.arrow.down") }
            if !s.pausedApps.isEmpty { InfoRow("En pause", s.pausedApps.joined(separator: ", "), symbol: "pause.circle") }
        }
    }

    private func dockerBlock(_ s: MacState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Docker")
            if s.dockerPaused {
                Button("Relancer Docker Desktop") { Task { await model.send(.resumeDocker) } }.buttonStyle(.glass)
            } else if s.session != nil, s.containers.isEmpty {
                Button("Mettre Docker Desktop en pause") { Task { await model.send(.pauseDocker) } }.buttonStyle(.glass)
            }
            ForEach(s.containers) { c in
                HStack {
                    Image(systemName: "shippingbox").foregroundStyle(.secondary)
                    Text(c.name)
                    Spacer()
                    Button("Arrêter", role: .destructive) { Task { await model.send(.stopContainer(id: c.id)) } }
                        .buttonStyle(.borderless)
                }
            }
        }
        .disabled(model.isBusy || !online)
    }

    // MARK: Footer

    private var footerActions: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button(role: .destructive) { Task { await model.send(.sleepNow) } } label: {
                Label("Mettre le Mac en veille", systemImage: "moon.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .disabled(!online)
            Text("Arrête la session, rétablit tout, puis met le Mac en veille. Demande Face ID.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Désappairer cet iPhone", role: .destructive) { confirmUnpair = true }
                .font(.footnote)
                .padding(.top, 12)
                .confirmationDialog("Désappairer cet iPhone ?", isPresented: $confirmUnpair, titleVisibility: .visible) {
                    Button("Désappairer", role: .destructive) { model.unpair() }
                } message: {
                    Text("Sur le Mac, retire aussi cet iPhone dans DarraOwl > iPhone… pour couper son accès.")
                }
        }
    }

    @ViewBuilder
    private func outcomeLine(_ o: PhoneModel.Outcome) -> some View {
        switch o {
        case let .sending(label): HStack { ProgressView(); Text("\(label)…") }.foregroundStyle(.secondary)
        case let .done(text): Label(text, systemImage: "checkmark.circle").foregroundStyle(.secondary)
        case let .failed(text): Label(text, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
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
        let kind: String
        switch n?.kind {
        case .wifi?: kind = "Wi-Fi"
        case .hotspot?: kind = "Partage de connexion"
        case .ethernet?: kind = "Ethernet"
        case .other?: kind = "Autre"
        case .none?, nil: kind = "Aucun"
        }
        return n?.name.map { "\(kind) · \($0)" } ?? kind
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).tracking(0.8)
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    let symbol: String
    init(_ label: String, _ value: String, symbol: String) {
        self.label = label
        self.value = value
        self.symbol = symbol
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: symbol).frame(width: 22).foregroundStyle(.secondary)
                Text(label)
                Spacer()
                Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
            .padding(.vertical, 11)
            Divider().padding(.leading, 34)
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

