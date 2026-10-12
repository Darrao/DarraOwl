import CryptoKit
import Foundation

/// The QR code the Mac shows. Contains no secret that outlives the next
/// five minutes: the one-time secret only proves the phone saw the code.
public struct PairingInvite: Codable, Equatable, Sendable {
    public static let scheme = "darraowl"
    public static let lifetime: TimeInterval = 5 * 60

    public var version: Int
    public var macID: UUID
    public var macName: String
    /// Mac's X25519 public key, raw representation.
    public var macAgreementKey: Data
    /// 32 random bytes, shown once.
    public var secret: Data
    public var expiresAt: Date
    public var endpoints: Endpoints?

    public init(macID: UUID, macName: String, macAgreementKey: Data, secret: Data, expiresAt: Date, endpoints: Endpoints?) {
        self.version = 1
        self.macID = macID
        self.macName = macName
        self.macAgreementKey = macAgreementKey
        self.secret = secret
        self.expiresAt = expiresAt
        self.endpoints = endpoints
    }

    /// `darraowl://pair?d=<base64url JSON>`
    public func url() throws -> URL {
        let data = try LinkCoding.encoder().encode(self)
        var c = URLComponents()
        c.scheme = Self.scheme
        c.host = "pair"
        c.queryItems = [URLQueryItem(name: "d", value: data.base64URLEncoded())]
        guard let url = c.url else { throw PairingError.malformedInvite }
        return url
    }

    public init(url: URL) throws(PairingError) {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme == Self.scheme, c.host == "pair",
              let value = c.queryItems?.first(where: { $0.name == "d" })?.value,
              let data = Data(base64URLEncoded: value),
              let invite = try? LinkCoding.decoder().decode(PairingInvite.self, from: data),
              invite.version == 1, invite.secret.count == 32, invite.macAgreementKey.count == 32
        else { throw .malformedInvite }
        self = invite
    }

    /// Why this invite cannot come from a DarraOwl Mac, or nil. A link can
    /// reach the phone from anywhere: its validity must be the normal five
    /// minutes and its addresses private ones, so a crafted link cannot
    /// point the phone at a server on the internet.
    public func implausibility(now: Date) -> String? {
        if expiresAt > now.addingTimeInterval(Self.lifetime + Self.clockTolerance) {
            return "Ce code n'a pas une durée de validité normale."
        }
        if macName.count > 100 { return "Ce code n'est pas un code DarraOwl." }
        if let endpoints, !endpoints.isPlausible { return "Ce code contient des adresses qui ne sont pas celles d'un Mac proche." }
        return nil
    }

    /// Difference allowed between the Mac's and the phone's clocks.
    public static let clockTolerance: TimeInterval = 120
}

/// The phone's answer: its public keys, bound to the invite by an HMAC keyed
/// with the one-time secret.
public struct PairingRequest: Codable, Equatable, Sendable {
    public var macID: UUID
    public var deviceID: UUID
    public var deviceName: String
    /// X25519, raw.
    public var agreementKey: Data
    /// Ed25519, raw. Signs every command.
    public var signingKey: Data
    /// P-256 in the Secure Enclave, x9.63. Signs sensitive commands, needs Face ID.
    public var biometricKey: Data
    public var createdAt: Date
    /// HMAC-SHA256 with the invite secret over every field above.
    public var proof: Data

    public init(macID: UUID, deviceID: UUID, deviceName: String, agreementKey: Data, signingKey: Data, biometricKey: Data, createdAt: Date, secret: Data) {
        self.macID = macID
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.agreementKey = agreementKey
        self.signingKey = signingKey
        self.biometricKey = biometricKey
        self.createdAt = createdAt
        self.proof = Data()
        self.proof = Self.proof(for: self, secret: secret)
    }

    static func proof(for r: PairingRequest, secret: Data) -> Data {
        var message = Data()
        for part in [r.macID.uuidString, r.deviceID.uuidString, r.deviceName] {
            message.append(Data(part.utf8))
            message.append(0)
        }
        for key in [r.agreementKey, r.signingKey, r.biometricKey] {
            message.append(contentsOf: withUnsafeBytes(of: UInt32(key.count).bigEndian, Array.init))
            message.append(key)
        }
        message.append(Data(ISO8601DateFormatter().string(from: r.createdAt).utf8))
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: secret)))
    }

    public func hasValidProof(secret: Data) -> Bool {
        let expected = Self.proof(for: self, secret: secret)
        return expected.count == proof.count && zip(expected, proof).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// The Mac's answer to a pairing request.
public struct PairingResponse: Codable, Equatable, Sendable {
    public var accepted: Bool
    public var macID: UUID
    public var macName: String
    public var message: String?
    /// Where the paired-devices listener is: the invite only has the
    /// pairing listener's port. Optional: older Macs do not send it.
    public var endpoints: Endpoints?

    public init(accepted: Bool, macID: UUID, macName: String, message: String?, endpoints: Endpoints? = nil) {
        self.accepted = accepted
        self.macID = macID
        self.macName = macName
        self.message = message
        self.endpoints = endpoints
    }
}

public enum PairingError: Error, Equatable, Sendable {
    case malformedInvite
    case expired
    case badProof
    case badKey
}

/// Key derivation shared by both sides. The link key is the TLS pre-shared
/// key of the direct connection for one paired device.
public enum LinkKeys {
    /// TLS PSK for a paired device: HKDF-SHA256 over X25519(mac, device).
    public static func linkKey(shared: SharedSecret, macID: UUID, deviceID: UUID) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data((macID.uuidString + deviceID.uuidString).utf8),
            sharedInfo: Data("darraowl-link-v1".utf8),
            outputByteCount: 32
        )
    }

    /// TLS PSK of the pairing connection, from the one-time secret.
    public static func pairingKey(secret: Data, macID: UUID) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: Data(macID.uuidString.utf8),
            info: Data("darraowl-pairing-v1".utf8),
            outputByteCount: 32
        )
    }

    /// TLS PSK identity of the pairing connection.
    public static func pairingIdentity(secret: Data) -> String {
        "pair-" + Data(SHA256.hash(data: secret)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        self.init(base64Encoded: b)
    }
}
