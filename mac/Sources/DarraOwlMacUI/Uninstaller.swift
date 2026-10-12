import AppKit
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
        // The menu bar app left running would publish to iCloud again and
        // keep answering the phone: it quits first (its own quit ends the
        // session and puts the sound back, a few seconds at most).
        guard await quitRunningApp() else { return 1 }
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
                    // The panel is off with the lid closed: its brightness
                    // can only be put back once it is open again.
                    if left.displayBrightness != nil || left.keyboardBrightness != nil {
                        print("La luminosité enregistrée ne peut être remise qu'avec le capot ouvert : ouvre-le, puis relance la désinstallation.")
                        client.invalidate()
                        return 1
                    }
                    for entry in left.audio {
                        print("Son de \(entry.name ?? entry.deviceUID) resté coupé (appareil absent) : remets-le à \(Int(entry.volume * 100)) % toi-même.")
                    }
                }
            }
            do {
                let response = try await client.send(.prepareUninstall)
                let pending = response.status?.pendingUndo ?? []
                if let refusal = response.error {
                    // Another account is at the screen, or a refusal of the helper's own.
                    clean = false
                    print("Désinstallation refusée par le composant système : \(refusal)")
                } else if pending.isEmpty {
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

        if clean {
            // Pairing keys and this Mac's iCloud records go too.
            let store = KeychainPairingStore()
            if let identity = try? store.identity() {
                await CloudKitMailbox(macID: identity.macID).removeEverything()
                print("Données iCloud de DarraOwl supprimées.")
            }
            store.removeAll()
            print("Clés d'appairage supprimées du trousseau.")
        }

        // DarraOwl stays installed: its hooks, link and login item stay too.
        guard clean else { return 1 }

        // Our hooks in Claude Code's settings, the hook token, the darraowl link.
        // Without the token (Keychain silent) the state is unknown: remove() only
        // rewrites the file when one of our entries is in it.
        if (try? ClaudeCodeSetup.state()) != .absent {
            do {
                if try ClaudeCodeSetup.remove() {
                    print("Hooks de DarraOwl retirés de \(ClaudeCodeSetup.file.path). Ta version d'avant DarraOwl reste dans \(ClaudeCodeSetup.backup.lastPathComponent).")
                }
            } catch {
                // Not a reason to keep DarraOwl installed: said, with what to do.
                print("Hooks de Claude Code non retirés (\(error.localizedDescription)). Dans \(ClaudeCodeSetup.file.path), retire les deux entrées \"http://127.0.0.1:\(String(HookServer.port))/hooks/claude\".")
            }
        }
        HookToken.remove()
        if CommandLineLink.state() != .absent, CommandLineLink.state() != .foreign {
            do {
                try CommandLineLink.remove()
                print("Commande darraowl retirée de ~/.local/bin.")
            } catch {
                print("Commande darraowl : \(error.localizedDescription)")
            }
        }

        if SMAppService.mainApp.status != .notRegistered {
            do {
                try await SMAppService.mainApp.unregister()
                print("Ouverture à la connexion retirée.")
            } catch {
                print("Ouverture à la connexion : \(error.localizedDescription)")
            }
        }
        // A reinstall starts afresh: opened at login again, no presence
        // switched back on by itself.
        for key in [AppModel.firstLaunchKey, AppModel.presenceIndefiniteKey, AppModel.presenceWhileClosedKey, AppModel.lidClosedKey, FirstLaunch.key] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        return 0
    }

    /// Asks the running menu bar app to quit and waits for it, 10 s at
    /// most. False when it is still there: nothing is removed then.
    private static func quitRunningApp() async -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: HelperConstants.appIdentifier)
            .filter { $0.processIdentifier != me }
        guard !others.isEmpty else { return true }
        others.forEach { $0.terminate() }
        for _ in 0..<40 where others.contains(where: { !$0.isTerminated }) {
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard others.allSatisfy(\.isTerminated) else {
            print("DarraOwl ne s'est pas fermé : quitte-le depuis la barre des menus, puis relance la désinstallation.")
            return false
        }
        print("DarraOwl fermé.")
        return true
    }
}
