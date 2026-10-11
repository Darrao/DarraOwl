import DarraOwlCore
import DarraOwlSystem
import DarraOwlXPC
import Foundation
import ServiceManagement

/// `DarraOwl --uninstall`, run by scripts/uninstall.sh. Ends any session,
/// lets the helper undo everything and delete its files, then removes the
/// helper and the login item. Keeps the helper when an undo is still pending,
/// since it is the one that retries.
@MainActor
enum Uninstaller {
    static func run() async -> Int32 {
        var clean = true
        let client = HelperClient()
        let registration = ServiceRegistration.helperState()

        if registration == .enabled {
            // Brightness and sound saved at a lid close: only the app can put
            // them back, so do it before the helper deletes its journal.
            if let changes = try? await client.send(.status).status?.userChanges, !changes.isEmpty {
                let lid = LidCoordinator(.init(
                    display: DisplayServicesDimmer(), keyboard: CoreBrightnessKeyboard(), audio: CoreAudioControl(),
                    processes: WorkspaceProcesses(), docker: DockerDesktopProbe(),
                    helper: AppHelperGateway(client: client) { _ in }, log: OSLogEngineLogger(category: "uninstall")
                ))
                _ = await lid.restore(changes)
                if let left = try? await client.send(.status).status?.userChanges, !left.isEmpty {
                    for entry in left.audio {
                        print("Son de \(entry.name ?? entry.deviceUID) resté coupé (appareil absent) : remets-le à \(Int(entry.volume * 100)) % toi-même.")
                    }
                }
            }
            do {
                let response = try await client.send(.prepareUninstall)
                let pending = response.status?.pendingUndo ?? []
                if pending.isEmpty {
                    print("Session terminée, réglages rétablis, fichiers du composant système supprimés.")
                } else {
                    clean = false
                    print("Restauration incomplète :")
                    pending.forEach { print("  - \($0)") }
                }
            } catch {
                // Unregistering sends SIGTERM, and the helper restores on SIGTERM.
                print("Composant système injoignable (\(error.localizedDescription)) ; il restaure à sa fermeture.")
            }
            client.invalidate()
        }

        if clean, registration != .notRegistered {
            do {
                try await ServiceRegistration.unregisterHelper()
                print("Composant système retiré.")
            } catch {
                clean = false
                print("Retrait du composant système impossible : \(error.localizedDescription)")
            }
        } else if !clean {
            print("Composant système conservé : il réessaie toutes les 10 s. Relance la désinstallation ensuite.")
        }

        if SMAppService.mainApp.status != .notRegistered {
            do {
                try await SMAppService.mainApp.unregister()
                print("Ouverture à la connexion retirée.")
            } catch {
                print("Ouverture à la connexion : \(error.localizedDescription)")
            }
        }
        return clean ? 0 : 1
    }
}
