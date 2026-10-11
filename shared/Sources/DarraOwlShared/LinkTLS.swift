import CryptoKit
import Foundation
import Network
import Security

/// TLS 1.2 with pre-shared keys, the scheme of Apple's peer-to-peer sample:
/// no certificate, and a peer without one of the keys fails the handshake
/// before any byte of ours is read. The Mac lists every paired device's key;
/// a phone lists its own, with its device id as identity.
public enum LinkTLS {
    public static func options(keys: [(identity: String, key: SymmetricKey)]) -> NWProtocolTLS.Options {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        for (identity, key) in keys {
            let keyData = key.withUnsafeBytes { DispatchData(bytes: $0) }
            let idData = Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
            sec_protocol_options_add_pre_shared_key(sec, keyData as __DispatchData, idData as __DispatchData)
        }
        sec_protocol_options_append_tls_ciphersuite(sec, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv12)
        return tls
    }

    public static func parameters(keys: [(identity: String, key: SymmetricKey)]) -> NWParameters {
        let params = NWParameters(tls: options(keys: keys), tcp: NWProtocolTCP.Options())
        params.includePeerToPeer = true
        return params
    }
}
