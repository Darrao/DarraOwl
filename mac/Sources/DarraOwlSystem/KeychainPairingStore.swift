import CryptoKit
import DarraOwlCore
import Foundation
import Security

public struct KeychainError: Error, LocalizedError, Sendable {
    public let status: OSStatus
    public let what: String
    public var errorDescription: String? {
        "\(what) : \(SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)")"
    }
}

/// The Mac identity (id + X25519 private key) and the paired devices, as
/// generic passwords in the data protection Keychain, readable only by this
/// app and only on this Mac (`ThisDeviceOnly`, never synced).
@MainActor
public final class KeychainPairingStore: PairingStore {
    static let identityService = "com.darrao.darraowl.identity"
    static let deviceService = "com.darrao.darraowl.device"

    private var cachedIdentity: MacIdentity?

    public init() {}

    private struct StoredIdentity: Codable {
        var macID: UUID
        var privateKey: Data
    }

    public func identity() throws -> MacIdentity {
        if let cachedIdentity { return cachedIdentity }
        if let data = try read(service: Self.identityService, account: "mac"),
           let stored = try? JSONDecoder().decode(StoredIdentity.self, from: data),
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: stored.privateKey) {
            let identity = MacIdentity(macID: stored.macID, agreementKey: key)
            cachedIdentity = identity
            return identity
        }
        let identity = MacIdentity(macID: UUID(), agreementKey: Curve25519.KeyAgreement.PrivateKey())
        let data = try JSONEncoder().encode(StoredIdentity(macID: identity.macID, privateKey: identity.agreementKey.rawRepresentation))
        try write(service: Self.identityService, account: "mac", data: data)
        cachedIdentity = identity
        return identity
    }

    public func devices() throws -> [PairedDevice] {
        var query = base(service: Self.deviceService)
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainError(status: status, what: "lecture des appareils") }
        let items = (result as? [Data]) ?? []
        return items.compactMap { try? JSONDecoder().decode(PairedDevice.self, from: $0) }.sorted { $0.pairedAt < $1.pairedAt }
    }

    public func add(_ device: PairedDevice) throws {
        try write(service: Self.deviceService, account: device.id.uuidString, data: try JSONEncoder().encode(device))
    }

    public func remove(deviceID: UUID) throws {
        var query = base(service: Self.deviceService)
        query[kSecAttrAccount as String] = deviceID.uuidString
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status, what: "suppression de l'appareil")
        }
    }

    /// Removes every DarraOwl item: identity and devices (uninstall).
    public func removeAll() {
        SecItemDelete(base(service: Self.deviceService) as CFDictionary)
        SecItemDelete(base(service: Self.identityService) as CFDictionary)
        cachedIdentity = nil
    }

    // MARK: Private

    private func base(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private func read(service: String, account: String) throws -> Data? {
        var query = base(service: service)
        query[kSecAttrAccount as String] = account
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status, what: "lecture du trousseau") }
        return result as? Data
    }

    private func write(service: String, account: String, data: Data) throws {
        var query = base(service: service)
        query[kSecAttrAccount as String] = account
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update, what: "écriture dans le trousseau") }
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let add = SecItemAdd(query as CFDictionary, nil)
        guard add == errSecSuccess else { throw KeychainError(status: add, what: "écriture dans le trousseau") }
    }
}
