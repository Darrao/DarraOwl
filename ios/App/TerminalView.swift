import DarraOwlPhoneKit
import DarraOwlShared
import SwiftUI

/// The Mac's terminal, from the phone: the folder in the prompt, each
/// command with what it printed, the latest at the bottom. The folder is
/// kept on the Mac (a cd stays); `clear` and `exit` stay on the phone.
struct TerminalView: View {
    let model: PhoneModel
    /// The demonstration keeps a history of its own.
    var demo = false
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @FocusState private var focused: Bool
    @State private var showHelp = false
    /// Going up the history: the position in it, and what was typed before.
    @State private var historyIndex: Int?
    @State private var draft = ""
    /// The commands run from this phone, kept on it only, until it forgets its Mac.
    @AppStorage private var historyData: Data
    static let historyKey = "shellHistory"

    init(model: PhoneModel, demo: Bool = false) {
        self.model = model
        self.demo = demo
        _historyData = AppStorage(wrappedValue: Data(), demo ? "shellHistoryDemo" : Self.historyKey)
    }

    static let background = Color(white: 0.07)
    static let ink = Color(white: 0.92)
    static let dim = Color(white: 0.58)
    static let error = Color(red: 1, green: 0.42, blue: 0.38)
    static let font = Font.system(.callout, design: .monospaced)

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if model.shellLog.isEmpty { intro }
                        ForEach(model.shellLog, id: \.id) { run in entry(run) }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: model.shellLog) { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: focused) { if focused { proxy.scrollTo("end", anchor: .bottom) } }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
            if case let .failed(why)? = model.outcome {
                // Before the command left (Face ID, the phone's key): said here too.
                Text(why)
                    .font(.caption.monospaced())
                    .foregroundStyle(Self.error)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
            Rectangle().fill(Color(white: 0.2)).frame(height: 1)
            if focused, enabled { keyRow }
            inputLine
        }
        .background(Self.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .navigationTitle(model.state?.macName ?? "Terminal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showHelp = true } label: { Image(systemName: "info.circle") }
                    .accessibilityLabel("Commandes utiles")
            }
            ToolbarItem(placement: .topBarTrailing) { menu }
        }
        .sheet(isPresented: $showHelp) {
            CommandHelpSheet { picked in
                input = picked
                // Back in the field, to replace PROJET or COMMANDE.
                Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    focused = true
                }
            }
        }
        // A fresh terminal is ready to type in.
        .task { if model.shellLog.isEmpty, enabled, online { focused = true } }
        .onChange(of: model.shell?.id) {
            guard let shell = model.shell, shell.phase == .running else { return }
            record(shell.text)
            input = ""
        }
        // A history that changed (a new command, cleared) is walked from its start.
        .onChange(of: historyData) { historyIndex = nil }
    }

    // MARK: Screen

    private var intro: some View {
        Text("Les commandes s'exécutent sur \(model.state?.macName ?? "le Mac"), avec ton shell, dans le dossier de l'invite : cd en change, et il reste pour les suivantes. clear efface l'écran, exit ferme le terminal, ↑ et ↓ rappellent tes commandes, i en propose des toutes prêtes. Face ID à chaque commande, au plus \(DurationText.short(Policy.remoteCommandTimeout)), sans saisie.")
            .font(.caption.monospaced())
            .foregroundStyle(Self.dim)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func entry(_ run: PhoneModel.ShellRun) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(promptLine(run.directory, run.text))
                .font(Self.font)
                .textSelection(.enabled)
            switch run.phase {
            case .running:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(Self.dim)
                    Text("en cours").font(.caption.monospaced()).foregroundStyle(Self.dim)
                    Spacer()
                    if model.shell?.id == run.id {
                        // The Mac goes on; the answer still shows here when it comes.
                        Button("Ne plus attendre") { model.clearShell() }
                            .font(.caption)
                    }
                }
            case let .done(output):
                if output.truncated {
                    Text("… seule la fin s'affiche (\(Policy.remoteCommandOutputLimit / 1024) Ko)")
                        .font(.caption.monospaced()).foregroundStyle(Self.dim)
                }
                if !trimmed(output.text).isEmpty {
                    Text(trimmed(output.text))
                        .font(Self.font)
                        .foregroundStyle(Self.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if output.status != 0 {
                    Text("\(output.summary) · \(secondsText(output.seconds))")
                        .font(.caption.monospaced())
                        .foregroundStyle(output.status == nil ? Color.orange : Self.error)
                }
            case let .failed(why):
                Text(why).font(.caption.monospaced()).foregroundStyle(Self.error)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "~/Dev/api % git status", the folder dimmed.
    private func promptLine(_ folder: String, _ command: String) -> AttributedString {
        var prompt = AttributedString("\(folder) % ")
        prompt.foregroundColor = Self.dim
        var text = AttributedString(command)
        text.foregroundColor = Self.ink
        return prompt + text
    }

    private func trimmed(_ text: String) -> String {
        var t = text
        while t.hasSuffix("\n") { t.removeLast() }
        return t
    }

    /// "4 s", "1 min 05".
    private func secondsText(_ seconds: TimeInterval) -> String {
        let whole = max(1, Int(seconds.rounded()))
        guard whole >= 60 else { return "\(whole) s" }
        return "\(whole / 60) min \(String(format: "%02d", whole % 60))"
    }

    // MARK: Input

    private var enabled: Bool { model.state?.remoteCommands == true }
    private var online: Bool {
        if case .online = model.presence { return true }
        return false
    }
    private var running: Bool { model.shell?.phase == .running }

    /// Like zsh's: the last folder only ("api %"), the full one being on screen.
    private var promptFolder: String {
        let folder = model.state?.terminalDirectory ?? "~"
        guard folder != "~", folder != "/", let last = folder.split(separator: "/").last else { return folder }
        return String(last)
    }

    @ViewBuilder
    private var inputLine: some View {
        if !enabled {
            Text("Désactivé sur le Mac : DarraOwl > Réglages > Terminal.")
                .font(.caption).foregroundStyle(Self.dim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(promptFolder) %")
                    .font(Self.font)
                    .foregroundStyle(Self.dim)
                    .lineLimit(1)
                TextField("", text: $input, prompt: Text(placeholder).foregroundStyle(Self.dim.opacity(0.55)))
                    .font(Self.font)
                    .foregroundStyle(Self.ink)
                    .tint(Self.ink)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($focused)
                    // Never disabled: the keyboard stays while a command runs.
                    .onSubmit { submit() }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private var placeholder: String {
        if !online { return "Mac hors ligne" }
        if running { return "commande en cours…" }
        return "commande"
    }

    /// Return: `clear` and `exit` here, anything else on the Mac (Face ID).
    /// The keyboard stays, as in a terminal: Return would put it away.
    private func submit() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        historyIndex = nil
        if text != "exit" { Task { focused = true } }
        switch text {
        case "":
            return
        case "clear":
            record(text)
            input = ""
            model.clearShellLog()
        case "exit":
            input = ""
            dismiss()
        default:
            guard CommandKind.isWellFormedCommand(text), !running, !model.isBusy, online else { return }
            Task { await model.runShell(text) }
        }
    }

    private func record(_ text: String) {
        var history = CommandHistory(data: historyData)
        history.record(text)
        historyData = history.data
    }

    // MARK: Keys and menu

    /// Above the command line while typing: the history, the characters a
    /// phone keyboard hides, and the keyboard put away.
    private var keyRow: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    key { Image(systemName: "chevron.up") } action: { historyStep(up: true) }
                        .accessibilityLabel("Commande précédente")
                    key { Image(systemName: "chevron.down") } action: { historyStep(up: false) }
                        .accessibilityLabel("Commande suivante")
                    ForEach(["~", "/", "-", "|", ">", "&", "*", "."], id: \.self) { character in
                        key { Text(character) } action: { input += character }
                    }
                }
            }
            key { Image(systemName: "keyboard.chevron.compact.down") } action: { focused = false }
                .accessibilityLabel("Ranger le clavier")
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    private func key(@ViewBuilder _ label: () -> some View, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label()
                .font(.body.monospaced())
                .foregroundStyle(Self.ink)
                .frame(minWidth: 40, minHeight: 36)
                .background(Color(white: 0.18), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func historyStep(up: Bool) {
        let commands = CommandHistory(data: historyData).commands
        guard !commands.isEmpty else { return }
        if up {
            let next = historyIndex.map { min($0 + 1, commands.count - 1) } ?? 0
            if historyIndex == nil { draft = input }
            historyIndex = next
            input = commands[next]
        } else if let index = historyIndex {
            if index == 0 || index - 1 >= commands.count {
                historyIndex = nil
                input = draft
            } else {
                historyIndex = index - 1
                input = commands[index - 1]
            }
        }
    }

    private var menu: some View {
        let agents = (model.state?.agents ?? []).filter { $0.pid != nil }
        let history = CommandHistory(data: historyData)
        return Menu {
            if !agents.isEmpty {
                Menu {
                    ForEach(agents, id: \.pid) { agent in
                        // pwd there: the terminal's folder becomes the agent's.
                        Button(agent.project.map { "\(agent.tool) · \($0)" } ?? agent.tool) {
                            Task { await model.runShell("pwd", agent: agent) }
                        }
                    }
                } label: {
                    Label("Aller dans le dossier d'un agent", systemImage: "folder")
                }
                .disabled(running || !online || !enabled)
            }
            if !history.commands.isEmpty {
                Menu {
                    ForEach(history.commands, id: \.self) { command in
                        Button(command) {
                            input = command
                            focused = true
                        }
                    }
                    Divider()
                    Button("Effacer l'historique", role: .destructive) { historyData = Data() }
                } label: {
                    Label("Historique", systemImage: "clock.arrow.circlepath")
                }
            }
            Button { model.clearShellLog() } label: { Label("Effacer l'écran", systemImage: "eraser") }
                .disabled(model.shellLog.isEmpty)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Plus")
    }
}
