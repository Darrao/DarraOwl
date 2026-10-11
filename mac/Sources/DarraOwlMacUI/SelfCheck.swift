import DarraOwlCore
import DarraOwlShared
import DarraOwlSystem
import Foundation

/// `DarraOwl --self-check`: reads every live adapter the lid-close actions
/// use and prints what it found. Reads only: nothing is written, muted,
/// darkened or paused.
@MainActor
enum SelfCheck {
    static func run() async -> Int32 {
        var ok = true
        func line(_ label: String, _ value: String, good: Bool = true) {
            print("\(good ? "ok " : "-- ") \(label) : \(value)")
            if !good { ok = false }
        }

        let display = DisplayServicesDimmer()
        if let why = display.refusal() {
            line("Écran", why, good: false)
        } else {
            do {
                let b = try display.readBrightness()
                line("Écran", "luminosité \(Int(b * 100)) %, \(display.isAsleep() ? "en veille" : "allumé")")
            } catch {
                line("Écran", error.localizedDescription, good: false)
            }
        }

        let keyboard = CoreBrightnessKeyboard()
        if let why = keyboard.refusal() {
            line("Clavier", why, good: false)
        } else {
            do {
                if let b = try keyboard.readBrightness() {
                    line("Clavier", "rétroéclairage \(Int(b * 100)) %")
                } else {
                    line("Clavier", "pas de rétroéclairage intégré")
                }
            } catch {
                line("Clavier", error.localizedDescription, good: false)
            }
        }

        do {
            let out = try CoreAudioControl().readDefaultOutput()
            line("Son", "\(out.name ?? out.deviceUID), volume \(Int(out.volume * 100)) %\(out.muted ? ", coupé" : "")")
        } catch {
            line("Son", error.localizedDescription, good: false)
        }

        let lid = IOPSPowerSource.lidClosed()
        line("Capot", lid.map { $0 ? "fermé" : "ouvert" } ?? "illisible", good: lid != nil)

        let processes = WorkspaceProcesses()
        let apps = processes.runningApps()
        let table = processes.processTable()
        line("Process", "\(table.count) lus, boot \(SysctlProcessControl.bootSession.prefix(8))…", good: !table.isEmpty && !SysctlProcessControl.bootSession.isEmpty)
        for id in LidSettings.defaultPausedApps {
            if let app = apps.first(where: { $0.bundleID == id }) {
                let tree = ProcessTree.descendants(of: app.pid, parents: table.mapValues(\.ppid))
                line("À mettre en pause", "\(app.name), \(tree.count) process")
            } else {
                line("À mettre en pause", "\(id) non ouvert")
            }
        }

        if apps.contains(where: { $0.bundleID == PausePolicy.dockerBundleID }) {
            do {
                let idle = try await DockerDesktopProbe().isIdle()
                line("Docker", idle ? "aucun conteneur, serait mis en pause" : "conteneurs en marche, laissé tel quel")
            } catch {
                line("Docker", "sonde en échec, laissé tel quel (\(error.localizedDescription))")
            }
        } else {
            line("Docker", "Docker Desktop non ouvert")
        }
        return ok ? 0 : 1
    }
}
