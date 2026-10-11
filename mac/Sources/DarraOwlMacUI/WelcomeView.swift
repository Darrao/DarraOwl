import AppKit
import DarraOwlCore
import DarraOwlSystem
import SwiftUI

/// First-launch tour, also reachable from Settings. Each step shows its
/// live state, so it doubles as a checklist.
struct WelcomeView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var tailscaleIP: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(nsImage: OwlIcon.image(awake: true)).resizable().frame(width: 36, height: 36)
                VStack(alignment: .leading) {
                    Text("Bienvenue dans DarraOwl").font(.title2)
                    Text("Quelques réglages, une seule fois.").foregroundStyle(.secondary)
                }
            }
            step(1, "Composant système", done: model.registration == .enabled && model.reachable,
                 detail: "Il désactive la veille pendant une session et la rétablit à l'heure de fin, même si l'app est fermée. Active DarraOwl dans Réglages Système > Général > Ouverture, sous Autoriser en arrière-plan.") {
                if model.registration == .enabled {
                    EmptyView()
                } else if model.registration == .requiresApproval {
                    Button("Ouvrir Réglages Système") { model.openApprovalSettings() }
                } else {
                    Button("Installer") { model.installHelper() }
                }
            }
            step(2, "Ouverture à la connexion", done: model.loginItemEnabled,
                 detail: "DarraOwl démarre avec ta session, pour que l'iPhone le trouve toujours.") {
                if !model.loginItemEnabled { Button("Activer") { model.setLoginItem(true) } }
            }
            step(3, "Même compte iCloud que l'iPhone", done: model.remote.cloudProblem == nil,
                 detail: model.remote.cloudProblem ?? "Le Mac publie son état dans ta base iCloud privée. Rien ne passe par un serveur tiers.") {
                EmptyView()
            }
            step(4, "Appairer ton iPhone", done: !model.remote.devices.isEmpty,
                 detail: "Installe DarraOwl sur l'iPhone, puis scanne le code affiché par le Mac.") {
                Button("Afficher le code") {
                    NSApp.activate()
                    openWindow(id: "pairing")
                }
            }
            step(5, "Accès en temps réel à distance (facultatif)", done: tailscaleIP != nil,
                 detail: tailscaleIP.map { "Tailscale actif sur ce Mac (\($0)). L'iPhone le joint en direct, même hors de ton réseau, si Tailscale tourne aussi dessus." }
                    ?? "Sans rien installer, l'iPhone joint le Mac par iCloud, avec quelques secondes de délai. Avec Tailscale sur le Mac et l'iPhone, même compte, la connexion reste directe et instantanée partout.") {
                if tailscaleIP == nil {
                    Link("Installer Tailscale", destination: URL(string: "https://tailscale.com/download")!)
                }
            }
            HStack {
                Spacer()
                Button("Terminé") { dismissWindow(id: "welcome") }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .task {
            while !Task.isCancelled {
                tailscaleIP = EndpointPicker.endpoints(from: NetworkInfo.interfaces(), port: 0).tailscale
                await model.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func step<Action: View>(_ n: Int, _ title: String, done: Bool, detail: String, @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(n).circle")
                .font(.title2)
                .foregroundStyle(done ? Color.primary : Color.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                action()
            }
        }
    }
}
