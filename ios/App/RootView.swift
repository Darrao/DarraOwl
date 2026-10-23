import AVFoundation
import DarraOwlPhoneKit
import DarraOwlShared
import SwiftUI
import VisionKit

struct RootView: View {
    @Bindable var runtime: PhoneRuntime

    var body: some View {
        Group {
            if runtime.model.mac == nil {
                OnboardingView(model: runtime.model) { runtime.enterDemo() }
            } else {
                MacView(model: runtime.model, demo: runtime.isDemo) { runtime.leaveDemo() }
            }
        }
        .confirmationDialog(linkTitle, isPresented: Binding(get: { runtime.pendingLink != nil }, set: { if !$0 { runtime.pendingLink = nil } }),
                            titleVisibility: .visible, presenting: runtime.pendingLink) { url in
            Button("Appairer") { Task { await runtime.pairConfirmed(url) } }
            Button("Annuler", role: .cancel) { runtime.pendingLink = nil }
        } message: { _ in
            Text(linkMessage)
        }
        .alert("Lien d'appairage refusé", isPresented: Binding(get: { runtime.linkError != nil }, set: { if !$0 { runtime.linkError = nil } })) {
            Button("OK", role: .cancel) { runtime.linkError = nil }
        } message: {
            Text(runtime.linkError ?? "")
        }
    }

    private var linkTitle: String {
        guard let url = runtime.pendingLink, let invite = try? PairingInvite(url: url) else { return "Appairer avec ce Mac ?" }
        return "Appairer avec « \(invite.macName) » ?"
    }

    private var linkMessage: String {
        let current = runtime.isDemo ? nil : runtime.model.mac?.macName
        let replace = current.map { " Il remplacera « \($0) »." } ?? ""
        return "Ce lien a été ouvert depuis une autre app. Ne l'accepte que si tu viens d'afficher ce code sur ton Mac.\(replace)"
    }
}

// MARK: Onboarding

struct OnboardingView: View {
    let model: PhoneModel
    let showDemo: () -> Void
    @State private var scanning = false
    /// "Coller le lien du code" found nothing to pair with.
    @State private var pasteProblem: String?

    private var canScan: Bool { DataScannerViewController.isSupported || DemoMode.isOn }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                VStack(alignment: .leading, spacing: 12) {
                    BlinkingOwl(awake: true, lineWidth: 2.4).frame(width: 52, height: 52)
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
                        Button {
                            pasteProblem = nil
                            scanning = true
                        } label: {
                            Label("Scanner le code d'appairage", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                    }
                    Button {
                        if let s = UIPasteboard.general.string, let url = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)) {
                            pasteProblem = nil
                            Task { await model.pair(url: url) }
                        } else {
                            pasteProblem = "Aucun lien DarraOwl dans le presse-papiers : copie d'abord le lien affiché par le Mac."
                        }
                    } label: {
                        Text("Coller le lien du code").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    if model.isPairing {
                        HStack {
                            ProgressView()
                            Text("Appairage en cours…")
                            Spacer()
                            Button("Annuler") { model.cancelPairing() }
                        }
                        .foregroundStyle(.secondary)
                    }
                    if let error = pasteProblem ?? model.pairingError {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                    if let notice = model.unpairNotice {
                        Label(notice, systemImage: "info.circle").foregroundStyle(.secondary)
                    }
                }

                Text("Le code ne sert qu'une fois et expire au bout de 5 minutes. Les clés restent dans le trousseau de cet iPhone. Aucun serveur du développeur : seulement ton Mac, cet iPhone et ton iCloud.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Pas encore de Mac prêt ? Voir une démonstration", action: showDemo)
                    .font(.footnote)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        // Any pairing that starts (a link confirmed too) shows its own outcome.
        .onChange(of: model.isPairing) { _, pairing in
            if pairing { pasteProblem = nil }
        }
        .sheet(isPresented: $scanning) {
            ScannerSheet(close: { scanning = false }) { url in
                scanning = false
                Task { await model.pair(url: url) }
            }
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

/// The scanner, or why the camera cannot be used, always with a way out.
struct ScannerSheet: View {
    let close: () -> Void
    let onFound: (URL) -> Void
    @State private var access = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        NavigationStack {
            Group {
                switch access {
                case .authorized:
                    QRScanner(onFound: onFound).ignoresSafeArea()
                case .notDetermined:
                    ProgressView()
                        .task { access = await AVCaptureDevice.requestAccess(for: .video) ? .authorized : .denied }
                default:
                    VStack(alignment: .leading, spacing: 16) {
                        Text("La caméra n'est pas autorisée pour DarraOwl.").font(.headline)
                        Text("Autorise-la dans Réglages, ou ferme et utilise « Coller le lien du code ».")
                            .foregroundStyle(.secondary)
                        Button("Ouvrir Réglages") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                        .buttonStyle(.glass)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fermer", action: close) }
            }
        }
    }
}

/// VisionKit scanner limited to QR codes; returns the first darraowl:// link.
/// Shown once the camera is allowed.
struct QRScanner: UIViewControllerRepresentable {
    let onFound: (URL) -> Void

    func makeUIViewController(context: Context) -> ScannerHost {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return ScannerHost(scanner: scanner)
    }

    func updateUIViewController(_ vc: ScannerHost, context: Context) {}

    /// Holds the scanner and starts it once on screen: started before, it
    /// can fail and is not retried.
    final class ScannerHost: UIViewController {
        let scanner: DataScannerViewController

        init(scanner: DataScannerViewController) {
            self.scanner = scanner
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidLoad() {
            super.viewDidLoad()
            addChild(scanner)
            scanner.view.frame = view.bounds
            scanner.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(scanner.view)
            scanner.didMove(toParent: self)
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            try? scanner.startScanning()
        }
    }

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
    @State private var agentToStop: MacState.Agent?
    @State private var commandText = ""
    /// The agent whose project folder the command runs in; nil for the home folder.
    @State private var commandAgentPID: Int32?
    @FocusState private var commandFocused: Bool
    @State private var showCommandHelp = false
    /// The commands run from this phone, kept on it only.
    @AppStorage("shellHistory") private var historyData = Data()

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
                        if let requests = state.agentRequests, !requests.isEmpty { requestsBlock(requests) }
                        if !state.agents.isEmpty { agentsBlock(state) }
                        if state.remoteCommands != nil { terminalBlock(state) }
                        if state.presence != nil { controlsBlock(state) }
                        macBlock(state)
                        // Docker open but idle: only worth a block when it can be paused.
                        if !state.containers.isEmpty || state.dockerPaused || (state.dockerRunning == true && state.session != nil) { dockerBlock(state) }
                    }
                    if let outcome = model.outcome { outcomeLine(outcome) }
                    // A link to another Mac, confirmed from here.
                    if model.isPairing {
                        HStack {
                            ProgressView()
                            Text("Appairage en cours…")
                            Spacer()
                            Button("Annuler") { model.cancelPairing() }
                        }
                        .foregroundStyle(.secondary)
                    }
                    if let error = model.pairingError {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                    footerActions
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
            .refreshable { await model.tick() }
            // Swiping down puts the keyboard away.
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Réglages")
                        .disabled(model.state == nil || !online || model.isBusy)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    if commandFocused {
                        Button { showCommandHelp = true } label: { Image(systemName: "info.circle") }
                            .accessibilityLabel("Commandes utiles")
                        Spacer()
                        Button("Fermer") { commandFocused = false }
                        Button("Lancer") { runCommand() }
                            .fontWeight(.semibold)
                            .disabled(!canRunCommand)
                    }
                }
            }
            .sheet(isPresented: $showCommandHelp) {
                CommandHelpSheet { picked in
                    commandText = picked
                    // Back in the field, to replace PROJET or COMMANDE.
                    Task {
                        try? await Task.sleep(for: .milliseconds(450))
                        commandFocused = true
                    }
                }
            }
            .onChange(of: model.shell?.id) {
                guard let shell = model.shell, shell.phase == .running else { return }
                var history = CommandHistory(data: historyData)
                history.record(shell.text)
                historyData = history.data
                commandText = ""
            }
            .onChange(of: model.mac == nil) { _, unpaired in
                if unpaired { historyData = Data() }
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
            BlinkingOwl(awake: model.state?.session != nil, lineWidth: 2.2).frame(width: 40, height: 40)
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
                    if let watching = session.whileWatchingLine {
                        Text(watching).font(.body.weight(.medium))
                        Text("Au plus tard à \(DurationText.clock(session.endsAt))\(keepText(session))").foregroundStyle(.secondary)
                    } else {
                        Text("Fin à \(DurationText.clock(session.endsAt))").foregroundStyle(.secondary)
                    }
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

    private func keepText(_ s: Session) -> String {
        guard let keep = s.keepUntil, keep > Date() else { return "" }
        return ", et au moins jusqu'à \(DurationText.clock(keep))"
    }

    private func progress(_ s: Session, at date: Date) -> Double {
        let total = s.endsAt.timeIntervalSince(s.startedAt)
        guard total > 0 else { return 1 }
        return min(1, max(0, date.timeIntervalSince(s.startedAt) / total))
    }

    // MARK: Claude's requests

    /// Claude asks for a permission while nobody is at the Mac: what it
    /// wants to do, and yes or no (Face ID to accept). Back at the Mac, or
    /// after an hour, the question goes to the terminal instead.
    private func requestsBlock(_ requests: [MacState.AgentRequest]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Claude demande ton accord")
            ForEach(requests) { request in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "hand.raised").foregroundStyle(.orange)
                        Text(request.project.map { "\(request.tool) · \($0)" } ?? request.tool).font(.body.weight(.medium))
                        Spacer()
                        Text(request.at.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                    if !request.detail.isEmpty {
                        Text(request.detail)
                            .font(.callout.monospaced())
                            .lineLimit(6)
                            .textSelection(.enabled)
                    }
                    HStack {
                        Button("Refuser", role: .destructive) {
                            Task { await model.send(.answerAgentRequest(id: request.id, allow: false)) }
                        }
                        .buttonStyle(.glass)
                        Spacer()
                        Button("Accepter") {
                            Task { await model.send(.answerAgentRequest(id: request.id, allow: true)) }
                        }
                        .buttonStyle(.glassProminent)
                        .accessibilityHint("Demande Face ID")
                    }
                    .disabled(model.isBusy || !online)
                }
            }
        }
    }

    // MARK: Agents

    private func agentsBlock(_ s: MacState) -> some View {
        let watched = Set(s.session?.watching.map(\.pid) ?? [])
        return VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Agents")
            ForEach(Array(s.agents.enumerated()), id: \.offset) { _, agent in
                HStack(alignment: .center) {
                    Image(systemName: "terminal").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.project.map { "\(agent.tool) · \($0)" } ?? agent.tool).font(.body.weight(.medium))
                        if agent.waitingForApproval {
                            Text("attend ta validation").font(.caption.weight(.medium)).foregroundStyle(.orange)
                        } else {
                            Text("depuis \(agent.since.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if let pid = agent.pid {
                        if watched.contains(pid) {
                            Text("suivi").font(.subheadline).foregroundStyle(.secondary)
                        } else {
                            Button("Suivre") { Task { await model.send(.watchAgent(pid: pid)) } }
                                .buttonStyle(.glass)
                                .disabled(model.isBusy || !online)
                                .accessibilityHint("Garde le Mac éveillé tant que cet agent tourne")
                        }
                        Menu {
                            Button("Arrêter l'agent", systemImage: "stop.fill", role: .destructive) { agentToStop = agent }
                        } label: {
                            Image(systemName: "ellipsis").frame(width: 32, height: 32).contentShape(Rectangle())
                        }
                        .disabled(model.isBusy || !online)
                        .accessibilityLabel("Plus d'actions pour \(agent.tool)")
                    }
                }
            }
            if watched.isEmpty, s.agents.contains(where: { $0.pid != nil }) {
                Text("Suivre : le Mac reste éveillé tant que l'agent tourne, au plus \(DurationText.short(s.settings.maxSessionDuration)).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .confirmationDialog(
            "Arrêter \(agentToStop?.tool ?? "l'agent") ?", isPresented: Binding(get: { agentToStop != nil }, set: { if !$0 { agentToStop = nil } }),
            titleVisibility: .visible, presenting: agentToStop
        ) { agent in
            Button("Arrêter", role: .destructive) {
                if let pid = agent.pid { Task { await model.send(.stopAgent(pid: pid)) } }
            }
            Button("Annuler", role: .cancel) {}
        } message: { _ in
            Text("Un Ctrl-C dans son terminal, puis l'arrêt s'il tourne encore 3 s après : l'agent se ferme. Demande Face ID.")
        }
    }

    // MARK: Terminal

    /// A command typed here runs on the Mac, with the Mac's option on: what
    /// `!` does in a terminal, out of an agent's hands.
    private func terminalBlock(_ s: MacState) -> some View {
        let agents = s.agents.filter { $0.pid != nil }
        let running = model.shell?.phase == .running
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                SectionTitle("Terminal")
                Spacer()
                if s.remoteCommands == true {
                    historyMenu
                    Button { showCommandHelp = true } label: { Image(systemName: "info.circle") }
                        .accessibilityLabel("Commandes utiles")
                }
            }
            if s.remoteCommands == true {
                VStack(alignment: .leading, spacing: 0) {
                    Menu {
                        Picker("Dossier", selection: $commandAgentPID) {
                            Text("Dossier personnel").tag(Int32?.none)
                            ForEach(agents, id: \.pid) { agent in
                                Text(agent.project.map { "\(agent.tool) · \($0)" } ?? agent.tool).tag(agent.pid)
                            }
                        }
                    } label: {
                        Label(folderTitle(agents), systemImage: "folder")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    Divider()
                    HStack(alignment: .top, spacing: 8) {
                        Text("$").font(.body.monospaced()).foregroundStyle(.secondary)
                        TextField("Commande", text: $commandText, axis: .vertical)
                            .font(.body.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .lineLimit(1...6)
                            .focused($commandFocused)
                    }
                    .padding(12)
                }
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
                HStack(spacing: 10) {
                    Button("Lancer") { runCommand() }
                        .buttonStyle(.glassProminent)
                        .disabled(!canRunCommand)
                        .accessibilityHint("Demande Face ID")
                    if !commandText.isEmpty, !running {
                        Button("Effacer") { commandText = "" }.buttonStyle(.glass)
                    }
                    Spacer()
                    if running, let shell = model.shell {
                        ProgressView()
                        Text("en cours depuis \(shell.since.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let shell = model.shell { shellResult(shell) }
                Text("Avec ton shell, dans le dossier choisi, sans saisie, au plus \(DurationText.short(Policy.remoteCommandTimeout)). Demande Face ID. Le bouton i propose des commandes toutes prêtes.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Désactivé sur le Mac. Pour lancer des commandes d'ici : DarraOwl > Réglages > Terminal, sur le Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(!online)
    }

    private var canRunCommand: Bool {
        CommandKind.isWellFormedCommand(commandText) && model.shell?.phase != .running && !model.isBusy && online
    }

    /// Face ID, then the command runs on the Mac; the keyboard goes so the
    /// answer can be seen.
    private func runCommand() {
        guard canRunCommand else { return }
        commandFocused = false
        let agent = commandAgentPID.flatMap { pid in model.state?.agents.first { $0.pid == pid } }
        let text = commandText
        Task { await model.runShell(text, agent: agent) }
    }

    private func folderTitle(_ agents: [MacState.Agent]) -> String {
        guard let pid = commandAgentPID, let agent = agents.first(where: { $0.pid == pid }) else { return "Dossier personnel" }
        return agent.project.map { "\(agent.tool) · \($0)" } ?? agent.tool
    }

    /// The last commands, to run again or change.
    private var historyMenu: some View {
        let history = CommandHistory(data: historyData)
        return Menu {
            ForEach(history.commands, id: \.self) { command in
                Button(command) {
                    commandText = command
                    commandFocused = true
                }
            }
            if !history.commands.isEmpty {
                Divider()
                Button("Effacer l'historique", role: .destructive) { historyData = Data() }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .accessibilityLabel("Historique des commandes")
        .disabled(history.commands.isEmpty)
    }

    @ViewBuilder
    private func shellResult(_ shell: PhoneModel.ShellRun) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text("$ \(shell.text)").font(.callout.monospaced()).lineLimit(3).textSelection(.enabled)
                Spacer()
                Text(shell.agent.map { $0.project ?? $0.tool } ?? "~").font(.caption).foregroundStyle(.secondary)
            }
            switch shell.phase {
            case .running:
                // The Mac goes on with the command; only the wait ends here.
                Button("Ne plus attendre") { model.clearShell() }.buttonStyle(.glass)
            case let .done(output):
                HStack(spacing: 8) {
                    Image(systemName: output.status == 0 ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(output.status == 0 ? Color.secondary : Color.orange)
                    Text("\(output.summary) · \(secondsText(output.seconds))").font(.subheadline).foregroundStyle(.secondary)
                }
                if output.text.isEmpty {
                    Text("Rien affiché.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        Text(output.text)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 280)
                    .padding(10)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                }
                if output.truncated {
                    Text("Seule la fin est affichée (\(Policy.remoteCommandOutputLimit / 1024) Ko).").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Copier") { UIPasteboard.general.string = output.text }
                        .buttonStyle(.glass)
                        .disabled(output.text.isEmpty)
                    Spacer()
                    Button("Fermer") { model.clearShell() }.buttonStyle(.glass)
                }
            case let .failed(why):
                Label(why, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                Button("Fermer") { model.clearShell() }.buttonStyle(.glass)
            }
        }
    }

    /// "4 s", "1 min 05".
    private func secondsText(_ seconds: TimeInterval) -> String {
        let whole = max(1, Int(seconds.rounded()))
        guard whole >= 60 else { return "\(whole) s" }
        return "\(whole / 60) min \(String(format: "%02d", whole % 60))"
    }

    // MARK: Controls

    static let presenceDurations: [Int] = [60, 120, 240, 480]

    private func controlsBlock(_ s: MacState) -> some View {
        let presence = s.presence ?? MacState.Presence(active: false, until: nil)
        let appsPaused = s.pausedApps.count - (s.dockerPaused ? 1 : 0) > 0
        return VStack(alignment: .leading, spacing: 14) {
            SectionTitle("Contrôles")
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Toujours actif").font(.body.weight(.medium))
                    Text(presenceText(presence)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if presence.active {
                    Button("Arrêter") { Task { await model.send(.stopPresence) } }.buttonStyle(.glass)
                } else {
                    Menu("Activer") {
                        Button("Sans limite") { Task { await model.send(.startPresence(minutes: nil)) } }
                        ForEach(Self.presenceDurations, id: \.self) { m in
                            Button(DurationText.short(TimeInterval(m * 60))) { Task { await model.send(.startPresence(minutes: m)) } }
                        }
                    }
                    .buttonStyle(.glass)
                }
            }
            if let whileClosed = presence.whileClosed {
                Toggle(isOn: Binding(
                    get: { whileClosed },
                    set: { on in Task { await model.send(.setPresenceWhileClosed(on)) } }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Aussi capot fermé")
                        Text("Pendant une session, si le Mac ne se verrouille pas quand l'écran s'éteint.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                controlButton("Éteindre l'écran", symbol: "display") { await model.send(.displayOff) }
                controlButton("Verrouiller", symbol: "lock.fill") { await model.send(.lockScreen) }
                if let muted = s.muted {
                    controlButton(muted ? "Remettre le son" : "Couper le son", symbol: muted ? "speaker.wave.2.fill" : "speaker.slash.fill") {
                        await model.send(.setMuted(!muted))
                    }
                }
                if appsPaused {
                    controlButton("Relancer les apps", symbol: "play.fill") { await model.send(.resumeApps) }
                } else if s.session != nil {
                    controlButton("Pause des apps", symbol: "pause.fill") { await model.send(.pauseApps) }
                }
            }
            Text("Toujours actif : le Mac ne se met pas en veille et ton statut Teams reste « Disponible », capot ouvert. Pause des apps : celles choisies dans les réglages du Mac, pendant une session.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(model.isBusy || !online)
    }

    private func presenceText(_ p: MacState.Presence) -> String {
        guard p.active else { return "désactivé" }
        return p.until.map { "jusqu'à \(DurationText.clock($0))" } ?? "sans limite"
    }

    private func controlButton(_ title: String, symbol: String, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.title3)
                Text(title).font(.subheadline).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
        }
        .buttonStyle(.glass)
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
            .disabled(!online || model.isBusy)
            Text("Arrête la session, rétablit tout, puis met le Mac en veille. Demande Face ID.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Désappairer cet iPhone", role: .destructive) { confirmUnpair = true }
                .font(.footnote)
                .padding(.top, 12)
                .confirmationDialog("Désappairer cet iPhone ?", isPresented: $confirmUnpair, titleVisibility: .visible) {
                    Button("Désappairer", role: .destructive) {
                        // In the demonstration there is nothing to unpair: back to the start.
                        if demo { leaveDemo() } else { Task { await model.unpair() } }
                    }
                } message: {
                    // A Mac that does not list its phones is older: it is not told.
                    Text(model.state?.pairedDevices == nil
                         ? "Sur le Mac, retire aussi cet iPhone dans DarraOwl > iPhone…."
                         : "Le Mac est prévenu et oublie cet iPhone s'il est joignable dans la minute. S'il est en veille ou éteint, retire aussi cet iPhone dans DarraOwl > iPhone… sur le Mac.")
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

/// Ready-made commands: one tap puts it in the field, to read or change
/// before it runs.
struct CommandHelpSheet: View {
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(ShellHelp.sections) { section in
                    Section(section.title) {
                        ForEach(section.items) { item in
                            Button {
                                onPick(item.command)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title).foregroundStyle(.primary)
                                    Text(item.command).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    if let note = item.note {
                                        Text(note).font(.caption).foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
                Section {
                    Text(ShellHelp.footer).font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Commandes utiles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
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
                    Toggle("Mac verrouillé (Teams t'affiche Absent)", isOn: $settings.alerts.macLocked)
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
                        var changes: [CommandKind] = []
                        if settings.lid != original?.lid { changes.append(.updateLidSettings(settings.lid)) }
                        if settings.alerts != original?.alerts { changes.append(.updateAlerts(settings.alerts)) }
                        if settings.lowPowerFloor != original?.lowPowerFloor || settings.endFloor != original?.endFloor {
                            changes.append(.updateBatteryFloors(lowPower: settings.lowPowerFloor, end: settings.endFloor))
                        }
                        Task {
                            // One after the other; the first failure stops the rest and stays on screen.
                            for change in changes {
                                await model.send(change)
                                if case .failed? = model.outcome { break }
                            }
                        }
                        dismiss()
                    }
                    .disabled(model.isBusy)
                }
            }
        }
    }
}

