import CryptoKit
import DarraOwlShared
import Foundation

/// A phone allowed to talk to this Mac. Public keys only; stored in the Keychain.
public struct PairedDevice: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var agreementKey: Data
    public var signingKey: Data
    public var biometricKey: Data
    public var pairedAt: Date

    public init(id: UUID, name: String, agreementKey: Data, signingKey: Data, biometricKey: Data, pairedAt: Date) {
        self.id = id
        self.name = name
        self.agreementKey = agreementKey
        self.signingKey = signingKey
        self.biometricKey = biometricKey
        self.pairedAt = pairedAt
    }
}

/// Ids of commands already seen, kept until well after they expire, and the
/// latest results (safety rule 6: each command runs at most once and its
/// result is recorded).
public struct CommandLedger: Codable, Equatable, Sendable {
    public static let keepSeenFor: TimeInterval = 3600
    public static let maxResults = 100

    public var seen: [UUID: Date] = [:]
    public var results: [CommandResult] = []

    public init() {}

    public func contains(_ id: UUID) -> Bool { seen[id] != nil }

    public mutating func markSeen(_ id: UUID, expiresAt: Date) {
        seen[id] = expiresAt
    }

    /// A replay's "duplicate" answer never replaces what really happened.
    public mutating func record(_ result: CommandResult) {
        if result.status == .duplicate, results.contains(where: { $0.commandID == result.commandID }) { return }
        results.removeAll { $0.commandID == result.commandID }
        results.append(result)
        if results.count > Self.maxResults { results.removeFirst(results.count - Self.maxResults) }
    }

    public mutating func prune(now: Date) {
        seen = seen.filter { now.timeIntervalSince($0.value) < Self.keepSeenFor }
    }
}

/// Checks a signed command before anything runs: known device, valid
/// signatures (Face ID one for sensitive commands), addressed to this Mac,
/// not seen before, not expired, arguments within policy.
public enum CommandAuthority {
    /// Allowed difference between the phone's and the Mac's clocks.
    public static let clockSkew: TimeInterval = 5

    public enum Verdict: Equatable, Sendable {
        case accept(CommandEnvelope)
        case reject(CommandResult)
    }

    public static func verify(
        _ signed: SignedCommand, macID: UUID, devices: [UUID: PairedDevice], ledger: CommandLedger, now: Date
    ) -> Verdict {
        guard let envelope = try? LinkCoding.decoder().decode(CommandEnvelope.self, from: signed.payload) else {
            return .reject(CommandResult(commandID: UUID(), status: .rejected, message: "Commande illisible.", at: now))
        }
        func reject(_ status: CommandResult.Status, _ message: String) -> Verdict {
            .reject(CommandResult(commandID: envelope.id, status: status, message: message, at: now))
        }

        guard let device = devices[signed.deviceID], envelope.deviceID == signed.deviceID else {
            return reject(.unauthorized, "Appareil non appairé.")
        }
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: device.signingKey),
              key.isValidSignature(signed.signature, for: signed.payload)
        else { return reject(.unauthorized, "Signature invalide.") }
        guard envelope.macID == macID else {
            return reject(.unauthorized, "Commande destinée à un autre Mac.")
        }
        if envelope.kind.isSensitive {
            guard let bio = signed.biometricSignature,
                  let bioKey = try? P256.Signing.PublicKey(x963Representation: device.biometricKey),
                  let signature = try? P256.Signing.ECDSASignature(derRepresentation: bio),
                  bioKey.isValidSignature(signature, for: signed.payload)
            else { return reject(.unauthorized, "Face ID requis pour cette commande.") }
        }
        guard !ledger.contains(envelope.id) else {
            return reject(.duplicate, "Commande déjà reçue.")
        }
        guard envelope.expiresAt.timeIntervalSince(envelope.issuedAt) <= Policy.commandLifetime + 0.5,
              envelope.issuedAt <= now.addingTimeInterval(clockSkew),
              now <= envelope.expiresAt.addingTimeInterval(clockSkew)
        else { return reject(.expired, "Commande expirée.") }
        do {
            try envelope.kind.validateArguments()
        } catch {
            return reject(.rejected, "Paramètres refusés.")
        }
        return .accept(envelope)
    }
}
