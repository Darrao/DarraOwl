import CoreImage
import CoreImage.CIFilterBuiltins
import DarraOwlCore
import DarraOwlShared
import SwiftUI

/// Pair an iPhone (QR code), see and remove paired iPhones, and see how the
/// phone can reach this Mac.
struct PairingView: View {
    let model: AppModel
    let remote: RemoteController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("iPhone").font(.title2)
            pairing
            Divider()
            devices
            Divider()
            reachability
        }
        .padding(20)
        .frame(width: 420)
        .onDisappear { remote.cancelInvite() }
    }

    @ViewBuilder
    private var pairing: some View {
        if let invite = remote.invite, let url = try? invite.url(), let image = Self.qr(url.absoluteString) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Scanne ce code avec l'app DarraOwl de ton iPhone.")
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 240, height: 240)
                    .frame(maxWidth: .infinity)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Valable encore \(DurationText.countdown(invite.expiresAt.timeIntervalSince(context.date))). Il ne sert qu'une fois.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Annuler") { remote.cancelInvite() }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Pour piloter ce Mac depuis ton iPhone, appaire-le une fois avec un code QR.")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Afficher le code d'appairage") { remote.showInvite() }
                    .disabled(!model.reachable)
            }
        }
    }

    private var devices: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("iPhone appairés").font(.headline)
            if remote.devices.isEmpty {
                Text("Aucun.").foregroundStyle(.secondary)
            }
            ForEach(remote.devices) { device in
                HStack {
                    VStack(alignment: .leading) {
                        Text(device.name)
                        Text(remote.connectedDevices.contains(device.id) ? "Connecté en direct" : "Appairé le \(device.pairedAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Désappairer") { remote.unpair(device) }
                }
            }
            Text("Désappairer coupe l'accès de l'iPhone immédiatement.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var reachability: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Connexion").font(.headline)
            if let port = remote.serverPort {
                Text("Serveur chiffré actif, port \(port).").font(.caption)
            } else if remote.devices.isEmpty {
                Text("Le serveur chiffré démarre après le premier appairage.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Serveur chiffré arrêté\(remote.serverProblem.map { " : \($0)" } ?? ".")").font(.caption).foregroundStyle(.orange)
            }
            Text(remote.cloudProblem ?? "iCloud disponible : l'iPhone joint le Mac par iCloud quand le réseau direct ne passe pas.")
                .font(.caption)
                .foregroundStyle(remote.cloudProblem == nil ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
            if let result = remote.lastResult {
                Text("Dernière commande : \(result.status.rawValue)\(result.message.map { ", \($0)" } ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    static func qr(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
