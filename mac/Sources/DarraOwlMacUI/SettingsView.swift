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
    /// settings.json exists but cannot be read: nothing is offered.
    @State private var claudeReadProblem: String?
    /// The hook token cannot be read yet (Keychain locked or silent): only
    /// removing, which needs no token, is offered. Retried every few seconds.
    @State private var claudeKeychainSilent = false
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
                Text("Tout est rétabli à l'ouverture du capot. Les apps de visio ne sont jamais mises en pause. Pendant un appel (micro utilisé), le son n'est pas coupé et aucune app n'est mise en pause. Avec un écran externe, rien n'est changé.")
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
            Section("Toujours actif") {
                Toggle("Rester disponible capot fermé", isOn: Binding(
                    get: { model.presenceWhileClosed },
                    set: { model.setPresenceWhileClosed($0) }
                ))
                Text("Avec « Toujours actif », pendant une session : capot fermé, une activité est déclarée toutes les 4 minutes pour que Teams te garde « Disponible ». L'écran se rallume un instant sous le capot, luminosité à zéro, puis s'éteint. Ne marche que si le Mac ne se verrouille pas quand l'écran s'éteint (Réglages Système > Écran verrouillé).")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                HStack {
                    Spacer()
                    Button("Enregistrer") { model.updateSettings(edited) }
                        .disabled(!model.reachable || !changed)
                }
            }
            Section("Claude Code") {
                Text("Pour être prévenu sur l'iPhone quand Claude a fini ou attend ta validation. DarraOwl ajoute deux réglages (« hooks ») au fichier de configuration de Claude Code, sur ce Mac : ~/.claude/settings.json, dans un dossier caché de ton dossier personnel. DarraOwl ne lit de ce que Claude Code lui envoie que le nom de l'événement, son type et le nom du dossier.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let claudeReadProblem {
                    Text("settings.json est illisible, rien n'est modifié : \(claudeReadProblem)").font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Text(claudeStateText)
                    Spacer()
                    if claudeReadProblem == nil, claudeKeychainSilent {
                        if claudeState != .absent {
                            Button("Désactiver") { setup { try ClaudeCodeSetup.remove() } }
                        }
                    } else if claudeReadProblem == nil {
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
                }
                if FileManager.default.fileExists(atPath: ClaudeCodeSetup.file.path) {
                    Button("Afficher le fichier dans le Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([ClaudeCodeSetup.file])
                    }
                    .buttonStyle(.link)
                }
                Text("Ton fichier est d'abord copié dans settings.json.darraowl-backup. Les sessions de Claude déjà ouvertes en tiennent compte à leur prochain lancement. Les notifications partent quand personne n'est devant le Mac : capot fermé ou une minute sans activité.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !model.remote.hookListening {
                    Text("Le récepteur local (127.0.0.1:\(String(HookServer.port))) ne tourne pas.").font(.caption).foregroundStyle(.orange)
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
            Section("Mises à jour") {
                Toggle("Vérifier et installer automatiquement", isOn: Binding(
                    get: { model.updater.automatic },
                    set: { model.updater.automatic = $0 }
                ))
                HStack {
                    Text(updateText).foregroundStyle(.secondary)
                    Spacer()
                    if case .ready = model.updater.phase {
                        Button("Installer") { model.updater.installNow() }
                            .disabled(model.session != nil)
                    } else {
                        Button("Vérifier maintenant") { Task { await model.updater.checkAndDownload() } }
                            .disabled(isUpdating)
                    }
                }
                Text("Une fois par jour, DarraOwl regarde sur GitHub s'il existe une nouvelle version. Elle n'est installée que si elle est signée par le développeur de DarraOwl, et jamais pendant une session.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
        .task(id: claudeKeychainSilent) {
            while claudeKeychainSilent, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                refreshSetup()
            }
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

    private var updateText: String {
        switch model.updater.phase {
        case .idle: "Version \(model.updater.currentVersion)"
        case .checking: "Recherche…"
        case .upToDate: "À jour (\(model.updater.currentVersion))"
        case let .downloading(v): "Téléchargement de la version \(v)…"
        case let .ready(v): model.session == nil ? "Version \(v) prête" : "Version \(v) prête, installée après la session"
        case let .installing(v): "Installation de la version \(v)…"
        case let .failed(why): "Mise à jour impossible : \(why)"
        }
    }

    private var isUpdating: Bool {
        switch model.updater.phase {
        case .checking, .downloading, .installing: true
        default: false
        }
    }

    private var claudeStateText: String {
        if !ClaudeCodeSetup.claudeInstalled { return "Claude Code n'est pas installé" }
        if claudeKeychainSilent {
            return claudeState == .absent ? "Trousseau indisponible pour l'instant" : "Présents (trousseau indisponible pour l'instant)"
        }
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
        do {
            claudeState = try ClaudeCodeSetup.state()
            claudeReadProblem = nil
            claudeKeychainSilent = false
        } catch ClaudeCodeSetup.SetupError.keychain {
            // Whether our hooks are in the file is still known without the token.
            claudeKeychainSilent = true
            do {
                let data = try ClaudeCodeSetup.read()
                claudeState = data.map { ClaudeHookConfig.hasOurs($0, port: HookServer.port) } == true ? .outdated : .absent
                claudeReadProblem = nil
            } catch {
                claudeReadProblem = error.localizedDescription
            }
        } catch {
            claudeReadProblem = error.localizedDescription
            claudeKeychainSilent = false
        }
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
