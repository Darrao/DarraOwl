import AppKit
import DarraOwlCore
import DarraOwlShared
import DarraOwlSystem
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var lowPowerFloor = Policy.defaultLowPowerFloor
    @State private var endFloor = Policy.defaultEndFloor
    @State private var capHours = Int(Policy.defaultMaxSessionDuration / 3600)
    @State private var lid = LidSettings()
    @State private var claudeState = ClaudeHookConfig.State.absent
    @State private var linkState = CommandLineLink.State.absent
    @State private var setupProblem: String?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section("Capot fermé, pendant une session") {
                Toggle("Éteindre l'écran et le clavier", isOn: $lid.darkenDisplay)
                ForEach([model.displayRefusal, model.keyboardRefusal].compactMap { $0 }, id: \.self) { why in
                    Text(why).font(.caption).foregroundStyle(.orange)
                }
                Toggle("Couper le son", isOn: $lid.mute)
                Toggle("Activer le mode économie d'énergie", isOn: $lid.lowPower)
                Toggle("Mettre Docker Desktop en pause si aucun conteneur ne tourne", isOn: $lid.pauseDocker)
                pausedApps
                Text("Tout est rétabli à l'ouverture du capot. Les apps d'appel et de visio ne sont jamais mises en pause.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Batterie") {
                Stepper("Mode économie d'énergie sous \(lowPowerFloor) %", value: $lowPowerFloor, in: (endFloor + Policy.floorGap)...Policy.maxLowPowerFloor, step: 5)
                Stepper("Fin de session sous \(endFloor) %", value: $endFloor, in: Policy.endFloorRange, step: 5)
                    .onChange(of: endFloor) { _, new in
                        if lowPowerFloor < new + Policy.floorGap { lowPowerFloor = new + Policy.floorGap }
                    }
                Text("Sur secteur, ces seuils ne s'appliquent pas. Une température critique arrête toujours la session.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Session") {
                Stepper("Durée maximale : \(capHours) h", value: $capHours, in: Int(Policy.minimumMaxSessionDuration / 3600)...Int(Policy.absoluteMaxSessionDuration / 3600))
            }
            Section {
                HStack {
                    Spacer()
                    Button("Enregistrer") { model.updateSettings(edited) }
                        .disabled(!model.reachable || !changed)
                }
            }
            Section("Claude Code") {
                Text("Pour être prévenu sur l'iPhone quand Claude a fini ou attend ta validation. DarraOwl ajoute deux réglages (« hooks ») dans ~/.claude/settings.json : Claude Code lui envoie alors le nom de l'événement et du dossier, jamais le contenu.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(claudeStateText)
                    Spacer()
                    switch claudeState {
                    case .absent:
                        Button("Activer") { setup { try ClaudeCodeSetup.install() } }
                            .disabled(!ClaudeCodeSetup.claudeInstalled)
                    case .outdated:
                        Button("Mettre à jour") { setup { try ClaudeCodeSetup.install() } }
                        Button("Désactiver") { setup { try ClaudeCodeSetup.remove() } }
                    case .installed:
                        Button("Désactiver") { setup { try ClaudeCodeSetup.remove() } }
                    }
                }
                Text("Ton fichier est d'abord copié dans settings.json.darraowl-backup. Les sessions de Claude déjà ouvertes en tiennent compte à leur prochain lancement. Les notifications partent quand personne n'est devant le Mac : capot fermé ou une minute sans activité.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.remote.hookServer?.isListening != true {
                    Text("Le récepteur local (127.0.0.1:\(HookServer.port)) ne tourne pas.").font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Terminal") {
                Text("La commande darraowl garde le Mac éveillé tant qu'une commande tourne, au plus la durée maximale : darraowl run 3h -- claude. Aussi : darraowl status, darraowl stop.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack {
                    Text(linkStateText)
                    Spacer()
                    switch linkState {
                    case .absent, .elsewhere:
                        Button("Installer la commande") { setup { try CommandLineLink.install() } }
                    case .installed:
                        Button("Retirer") { setup { try CommandLineLink.remove() } }
                    case .foreign, .unavailable:
                        EmptyView()
                    }
                }
                if linkState == .installed {
                    Text("Si le Terminal ne trouve pas darraowl, ajoute ~/.local/bin à ton PATH.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let setupProblem {
                Text(setupProblem).font(.caption).foregroundStyle(.red)
            }
            Section("Système") {
                Toggle("Ouvrir DarraOwl à la connexion", isOn: Binding(
                    get: { model.loginItemEnabled },
                    set: { model.setLoginItem($0) }
                ))
                LabeledContent("Composant système", value: model.registration.label)
                if model.registration == .requiresApproval {
                    Button("Ouvrir Réglages Système") { model.openApprovalSettings() }
                }
                LabeledContent("Version", value: model.appBuild)
                Button("Revoir la bienvenue") {
                    NSApp.activate()
                    openWindow(id: "welcome")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear {
            load()
            refreshSetup()
        }
        .onChange(of: model.status?.settings) { _, _ in load() }
    }

    // MARK: Paused apps

    private var pausedApps: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Apps mises en pause")
            ForEach(lid.pausedApps, id: \.self) { id in
                HStack {
                    Text(Self.displayName(id))
                    Spacer()
                    Button("Retirer") { lid.pausedApps.removeAll { $0 == id } }
                        .controlSize(.small)
                }
            }
            Menu("Ajouter une app ouverte") {
                ForEach(addableApps, id: \.bundleID) { app in
                    Button(app.name) { lid.pausedApps.append(app.bundleID) }
                }
            }
            .disabled(addableApps.isEmpty || lid.pausedApps.count >= LidSettings.maxPausedApps)
            .fixedSize()
        }
    }

    private struct AppChoice {
        let bundleID: String
        let name: String
    }

    /// Dock apps now open that may be paused and are not listed yet.
    private var addableApps: [AppChoice] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> AppChoice? in
                guard let id = app.bundleIdentifier, PausePolicy.isWellFormedBundleID(id),
                      !PausePolicy.isProtected(id), !lid.pausedApps.contains(id) else { return nil }
                return AppChoice(bundleID: id, name: app.localizedName ?? id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func displayName(_ bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }

    // MARK: Claude Code and Terminal

    private var claudeStateText: String {
        if !ClaudeCodeSetup.claudeInstalled { return "Claude Code n'est pas installé" }
        switch claudeState {
        case .absent: return "Désactivé"
        case .installed: return "Activé"
        case .outdated: return "À mettre à jour"
        }
    }

    private var linkStateText: String {
        switch linkState {
        case .installed: "Installée dans ~/.local/bin"
        case .absent: "Non installée"
        case .elsewhere: "Pointe vers une autre copie de DarraOwl"
        case .foreign: "~/.local/bin/darraowl existe déjà et n'est pas à DarraOwl : rien n'est modifié."
        case .unavailable: "Indisponible dans cette version de développement"
        }
    }

    private func setup(_ change: () throws -> Void) {
        do {
            try change()
            setupProblem = nil
        } catch {
            setupProblem = error.localizedDescription
        }
        refreshSetup()
    }

    private func refreshSetup() {
        claudeState = ClaudeCodeSetup.state()
        linkState = CommandLineLink.state()
    }

    // MARK: State

    private var edited: PowerSettings {
        PowerSettings(lowPowerFloor: lowPowerFloor, endFloor: endFloor, maxSessionDuration: TimeInterval(capHours * 3600), lid: lid,
                      alerts: model.status?.settings.alerts ?? AlertSettings())
    }

    private var changed: Bool {
        guard let s = model.status?.settings else { return false }
        return s != edited
    }

    private func load() {
        guard let s = model.status?.settings else { return }
        lowPowerFloor = s.lowPowerFloor
        endFloor = s.endFloor
        capHours = Int(s.maxSessionDuration / 3600)
        lid = s.lid
    }
}
