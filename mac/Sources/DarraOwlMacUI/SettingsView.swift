import DarraOwlShared
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var lowPowerFloor = Policy.defaultLowPowerFloor
    @State private var endFloor = Policy.defaultEndFloor
    @State private var capHours = Int(Policy.defaultMaxSessionDuration / 3600)
    @State private var loaded = false

    var body: some View {
        Form {
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
                    Button("Enregistrer") {
                        model.updateSettings(PowerSettings(lowPowerFloor: lowPowerFloor, endFloor: endFloor, maxSessionDuration: TimeInterval(capHours * 3600)))
                    }
                    .disabled(!model.reachable || !changed)
                }
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
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .onAppear(perform: load)
        .onChange(of: model.status?.settings) { _, _ in load() }
    }

    private var changed: Bool {
        guard let s = model.status?.settings else { return false }
        return s.lowPowerFloor != lowPowerFloor || s.endFloor != endFloor || Int(s.maxSessionDuration / 3600) != capHours
    }

    private func load() {
        guard let s = model.status?.settings else { return }
        lowPowerFloor = s.lowPowerFloor
        endFloor = s.endFloor
        capHours = Int(s.maxSessionDuration / 3600)
    }
}
