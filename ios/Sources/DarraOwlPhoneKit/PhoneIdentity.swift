import CryptoKit
import DarraOwlShared
import Foundation

/// Signs with the key that needs Face ID. Live: a Secure Enclave P-256 key
/// created with `.biometryCurrentSet`; each signature shows the Face ID
/// prompt. Simulator and tests: a software key.
public protocol BiometricSigner: Sendable {
    /// x9.63 public key.
    var publicKey: Data { get }
    /// DER ECDSA signature over `payload`. Throws when Face ID is refused.
    func sign(_ payload: Data, reason: String) async throws -> Data
}

/// This phone's keys. Created once, kept in the Keychain.
public struct PhoneIdentity: Sendable {
    public var deviceID: UUID
    public var deviceName: String
    public var agreementKey: Curve25519.KeyAgreement.PrivateKey
    public var signingKey: Curve25519.Signing.PrivateKey
    public var biometric: any BiometricSigner

    public init(
        deviceID: UUID, deviceName: String,
        agreementKey: Curve25519.KeyAgreement.PrivateKey, signingKey: Curve25519.Signing.PrivateKey,
        biometric: any BiometricSigner
    ) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.agreementKey = agreementKey
        self.signingKey = signingKey
        self.biometric = biometric
    }

    public func pairingRequest(for invite: PairingInvite, at date: Date) -> PairingRequest {
        PairingRequest(
            macID: invite.macID, deviceID: deviceID, deviceName: deviceName,
            agreementKey: agreementKey.publicKey.rawRepresentation,
            signingKey: signingKey.publicKey.rawRepresentation,
            biometricKey: biometric.publicKey, createdAt: date, secret: invite.secret
        )
    }

    /// TLS pre-shared key shared with this Mac.
    public func linkKey(for mac: PairedMac) throws -> SymmetricKey {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: mac.agreementKey)
        let shared = try agreementKey.sharedSecretFromKeyAgreement(with: peer)
        return LinkKeys.linkKey(shared: shared, macID: mac.macID, deviceID: deviceID)
    }

    /// Signs a command. Sensitive ones also carry the Face ID signature.
    public func sign(_ kind: CommandKind, for mac: PairedMac, at date: Date, id: UUID = UUID()) async throws -> (CommandEnvelope, SignedCommand) {
        let envelope = CommandEnvelope(id: id, kind: kind, deviceID: deviceID, macID: mac.macID, issuedAt: date)
        let payload = try LinkCoding.encoder().encode(envelope)
        let signature = try signingKey.signature(for: payload)
        let bio = kind.isSensitive ? try await biometric.sign(payload, reason: kind.label) : nil
        return (envelope, SignedCommand(deviceID: deviceID, payload: payload, signature: signature, biometricSignature: bio))
    }
}

/// The Mac this phone is paired with.
public struct PairedMac: Codable, Equatable, Sendable {
    public var macID: UUID
    public var macName: String
    /// X25519 public key, raw.
    public var agreementKey: Data
    /// Last known addresses (from the invite, then from iCloud).
    public var endpoints: Endpoints?
    public var pairedAt: Date

    public init(macID: UUID, macName: String, agreementKey: Data, endpoints: Endpoints?, pairedAt: Date) {
        self.macID = macID
        self.macName = macName
        self.agreementKey = agreementKey
        self.endpoints = endpoints
        self.pairedAt = pairedAt
    }
}

/// Software P-256 key: simulator and tests only. No Face ID.
public struct SoftwareBiometricSigner: BiometricSigner {
    let key: P256.Signing.PrivateKey

    public init(key: P256.Signing.PrivateKey = P256.Signing.PrivateKey()) {
        self.key = key
    }

    public var rawKey: Data { key.rawRepresentation }
    public var publicKey: Data { key.publicKey.x963Representation }

    public func sign(_ payload: Data, reason: String) async throws -> Data {
        try key.signature(for: payload).derRepresentation
    }
}
