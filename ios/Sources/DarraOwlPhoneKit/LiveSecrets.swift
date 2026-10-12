import CryptoKit
import DarraOwlShared
import Foundation
import LocalAuthentication
import Security

/// The Face ID key: a Secure Enclave P-256 key bound to the enrolled faces
/// (`.biometryCurrentSet`). Re-enrolling Face ID invalidates it; pair again.
public struct SecureEnclaveSigner: BiometricSigner {
    let dataRepresentation: Data
    public let publicKey: Data

    public static func create() throws -> SecureEnclaveSigner {
        // Bound to the enrolled faces: none enrolled, no key (said plainly
        // rather than as a Keychain code).
        var unavailable: NSError?
        // Face ID refused to DarraOwl in Settings reads as "not available":
        // the key is still made, and the prompt says what to do later.
        if !LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &unavailable),
           let code = unavailable?.code, code == LAError.biometryNotEnrolled.rawValue || code == LAError.passcodeNotSet.rawValue {
            throw BiometricError.notEnrolled
        }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .biometryCurrentSet], &error
        ) else {
            throw error!.takeRetainedValue() as Error
        }
        let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
        return SecureEnclaveSigner(dataRepresentation: key.dataRepresentation, publicKey: key.publicKey.x963Representation)
    }

    init(dataRepresentation: Data, publicKey: Data) {
        self.dataRepresentation = dataRepresentation
        self.publicKey = publicKey
    }

    public func sign(_ payload: Data, reason: String) async throws -> Data {
        let context = LAContext()
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
        } catch {
            throw BiometricError.refused
        }
        // Face ID passed but the key fails: it was invalidated by a change of
        // the enrolled faces.
        do {
            let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: dataRepresentation, authenticationContext: context)
            return try key.signature(for: payload).derRepresentation
        } catch {
            throw BiometricError.keyInvalidated
        }
    }
}

public struct UnreadableIdentity: Error, LocalizedError {
    public var errorDescription: String? {
        "les clés de cet iPhone sont illisibles. Désappaire-le, puis appaire-le à nouveau."
    }
}

/// Phone identity and paired Mac in the Keychain, this device only, never synced.
@MainActor
public final class KeychainPhoneStore: PhoneStore {
    static let identityService = "com.darrao.darraowl.phone.identity"
    static let macService = "com.darrao.darraowl.phone.mac"

    private let deviceName: String
    private var cached: PhoneIdentity?

    public init(deviceName: String) {
        self.deviceName = deviceName
    }

    private struct Stored: Codable {
        var deviceID: UUID
        var agreement: Data
        var signing: Data
        /// "enclave" or "software" (simulator only).
        var biometricKind: String
        var biometricData: Data
        var biometricPublicKey: Data
    }

    public func identity() throws -> PhoneIdentity {
        if let cached { return cached }
        if let data = try read(Self.identityService) {
            // Never replaced silently: new keys would unpair this iPhone from
            // the Mac without a word.
            guard let s = try? JSONDecoder().decode(Stored.self, from: data), let identity = try? make(s) else {
                throw UnreadableIdentity()
            }
            cached = identity
            return identity
        }
        let stored = try createStored()
        try write(Self.identityService, try JSONEncoder().encode(stored))
        let identity = try make(stored)
        cached = identity
        return identity
    }

    public func pairedMac() -> PairedMac? {
        guard let data = try? read(Self.macService) else { return nil }
        return try? LinkCoding.decoder().decode(PairedMac.self, from: data)
    }

    public func save(_ mac: PairedMac) throws {
        try write(Self.macService, try LinkCoding.encoder().encode(mac))
    }

    /// Forgets the Mac and this phone's keys: a later pairing starts fresh.
    public func forgetMac() throws {
        SecItemDelete(query(Self.macService) as CFDictionary)
        SecItemDelete(query(Self.identityService) as CFDictionary)
        cached = nil
    }

    // MARK: Private

    private func createStored() throws -> Stored {
        #if targetEnvironment(simulator)
        let soft = SoftwareBiometricSigner()
        let kind = "software", data = soft.rawKey, pub = soft.publicKey
        #else
        let enclave = try SecureEnclaveSigner.create()
        let kind = "enclave", data = enclave.dataRepresentation, pub = enclave.publicKey
        #endif
        return Stored(
            deviceID: UUID(),
            agreement: Curve25519.KeyAgreement.PrivateKey().rawRepresentation,
            signing: Curve25519.Signing.PrivateKey().rawRepresentation,
            biometricKind: kind, biometricData: data, biometricPublicKey: pub
        )
    }

    private func make(_ s: Stored) throws -> PhoneIdentity {
        let bio: any BiometricSigner
        switch s.biometricKind {
        case "enclave":
            bio = SecureEnclaveSigner(dataRepresentation: s.biometricData, publicKey: s.biometricPublicKey)
        default:
            #if targetEnvironment(simulator)
            bio = SoftwareBiometricSigner(key: try P256.Signing.PrivateKey(rawRepresentation: s.biometricData))
            #else
            // A software key never signs on a real phone.
            throw CocoaError(.coderInvalidValue)
            #endif
        }
        return PhoneIdentity(
            deviceID: s.deviceID, deviceName: deviceName,
            agreementKey: try .init(rawRepresentation: s.agreement),
            signingKey: try .init(rawRepresentation: s.signing),
            biometric: bio
        )
    }

    private func query(_ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "default"]
    }

    private func read(_ service: String) throws -> Data? {
        var q = query(service)
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return out as? Data
    }

    private func write(_ service: String, _ data: Data) throws {
        let q = query(service)
        if SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess { return }
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}
