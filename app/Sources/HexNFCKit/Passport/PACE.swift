import Foundation
import HexNFCRecords

/// Password Authenticated Connection Establishment (PACE) with ECDH Generic
/// Mapping and AES — the modern eMRTD access-control protocol (ICAO Doc 9303
/// Part 11 §4.4). This file holds the *pure* crypto: password/session key
/// derivation, the mapped-generator computation, and the authentication tokens.
/// The APDU orchestration (MSE:Set AT, the GENERAL AUTHENTICATE chain) lives in
/// `EPassportReader`.
///
/// Supports ECDH with both **Generic Mapping** and **Integrated Mapping**, and
/// AES-128 / AES-192 / AES-256 secure messaging (AES-CBC + AES-CMAC), over the
/// standardised eMRTD curves (Brainpool P256r1/P384r1/P512r1 and NIST
/// P-256/P-384/P-521). The mapping and cipher are selected from the protocol OID
/// carried in `EF.CardAccess`.
enum PACE {
    /// The nonce-mapping variant carried in the protocol OID's 9th component.
    enum Mapping: Equatable, Sendable {
        case generic // id-PACE-ECDH-GM  (component 0x02)
        case integrated // id-PACE-ECDH-IM  (component 0x04)

        init?(oidComponent: UInt8) {
            switch oidComponent {
            case 0x02: self = .generic
            case 0x04: self = .integrated
            default: return nil // 0x06 = CAM and DH variants are unsupported
            }
        }
    }

    /// The secure-messaging cipher, from the OID's 10th component. Only the AES
    /// variants are supported (3DES-PACE, component 0x01, is not).
    struct Cipher: Equatable, Sendable {
        /// AES key length in bytes (16 / 24 / 32).
        let keyBytes: Int

        init?(oidComponent: UInt8) {
            switch oidComponent {
            case 0x02: keyBytes = 16 // AES-128
            case 0x03: keyBytes = 24 // AES-192
            case 0x04: keyBytes = 32 // AES-256
            default: return nil
            }
        }
    }

    /// `PACEInfo` lifted from `EF.CardAccess`: the raw protocol OID bytes (reused
    /// verbatim in the authentication tokens), the standardised domain parameter
    /// id that selects the curve, and the mapping + cipher parsed from the OID.
    struct Info: Equatable, Sendable {
        let oid: Data // DER value bytes of the protocol OID
        let parameterId: Int
        let mapping: Mapping
        let cipher: Cipher
        var curve: ECCurve? {
            ECCurve.standardizedDomainParameter(parameterId)
        }
    }

    enum Failure: Error, Sendable {
        case step(String, UInt16)
        case malformedResponse
        case tokenMismatch
        case unsupportedMapping
    }

    /// id-PACE OID value-byte prefix `0.4.0.127.0.7.2.2.4`. Components 9 and 10
    /// (index 8 and 9) then select the mapping and the cipher/keylength.
    static let idPACEPrefix = Data([0x04, 0x00, 0x7F, 0x00, 0x07, 0x02, 0x02, 0x04])

    // MARK: - EF.CardAccess parsing

    /// Parse `EF.CardAccess` and return the first supported PACE `Info` (a curve,
    /// mapping and cipher we implement).
    static func parseInfo(_ cardAccess: Data) -> Info? {
        guard let set = try? BERTLV.parseFirst(cardAccess) else { return nil }
        // EF.CardAccess is a SET (0x31) of SecurityInfo SEQUENCEs (0x30).
        let sequences = set.tag == 0x31 ? set.children : [set]
        for seq in sequences where seq.tag == 0x30 {
            guard let oidNode = seq.child(tag: 0x06) else { continue }
            let oid = oidNode.value
            guard oid.count >= 10, oid.starts(with: idPACEPrefix) else { continue }
            guard let mapping = Mapping(oidComponent: oid[oid.startIndex + 8]),
                  let cipher = Cipher(oidComponent: oid[oid.startIndex + 9]) else { continue }
            let integers = seq.children.filter { $0.tag == 0x02 }
            // children: OID, version INTEGER, parameterId INTEGER (optional).
            guard integers.count >= 2 else { continue }
            let parameterId = intValue(integers[1].value)
            let info = Info(oid: oid, parameterId: parameterId, mapping: mapping, cipher: cipher)
            if info.curve != nil {
                return info
            }
        }
        return nil
    }

    private static func intValue(_ data: Data) -> Int {
        var v = 0
        for byte in data {
            v = (v << 8) | Int(byte)
        }
        return v
    }

    // MARK: - Key derivation (Doc 9303 Part 11 §9.7.1)

    /// KDF(K, c): `H(K ‖ counter)` truncated to the key size. SHA-1 for 16-byte
    /// (AES-128 / 3DES) keys; SHA-256 for larger.
    static func kdf(_ key: Data, counter: UInt32, keyBytes: Int = 16) -> Data {
        var input = key
        input.append(contentsOf: [
            UInt8((counter >> 24) & 0xFF), UInt8((counter >> 16) & 0xFF),
            UInt8((counter >> 8) & 0xFF), UInt8(counter & 0xFF),
        ])
        let hash = keyBytes <= 16 ? EMRTDCrypto.sha1(input) : EMRTDCrypto.sha256(input)
        return Data(hash.prefix(keyBytes))
    }

    /// The MRZ-derived PACE password key `K_π = KDF(SHA-1(MRZ_information), 3)`,
    /// sized to the cipher (16/24/32 bytes; ≥24 switches the KDF to SHA-256).
    static func passwordKey(mrzInformation: String, keyBytes: Int = 16) -> Data {
        let pi = EMRTDCrypto.sha1(Data(mrzInformation.utf8))
        return kdf(pi, counter: 3, keyBytes: keyBytes)
    }

    /// Session keys derived from the shared secret's x-coordinate, sized to the
    /// cipher (16/24/32 bytes each).
    static func sessionKeys(sharedSecretX: Data, keyBytes: Int = 16) -> (enc: Data, mac: Data) {
        (kdf(sharedSecretX, counter: 1, keyBytes: keyBytes),
         kdf(sharedSecretX, counter: 2, keyBytes: keyBytes))
    }

    // MARK: - Generic Mapping

    /// Mapped base point `G' = s·G + H`, where `s` is the decrypted nonce and
    /// `H` is the first ECDH shared point.
    static func mappedGenerator(curve: ECCurve, nonce s: Data, sharedH: ECPoint) -> ECPoint {
        let sG = curve.scalarMul(BigUInt(bytes: s), curve.g)
        return curve.add(sG, sharedH)
    }

    // MARK: - Integrated Mapping

    /// Mapped base point for **Integrated Mapping**: `G' = f_G(R_p(s, t))`, where
    /// the pseudo-random function `R_p` expands `(s, t)` to a field element and
    /// the point-encoding `f_G` maps it onto the curve (ICAO Doc 9303 Part 11
    /// §4.4.3.3.2). Implemented in `PACE+IntegratedMapping.swift`.
    static func integratedMappedGenerator(curve: ECCurve, nonce s: Data, terminalNonce t: Data) throws -> ECPoint {
        try integratedMapping(curve: curve, nonce: s, terminalNonce: t)
    }

    // MARK: - Authentication token

    /// PACE authentication token `T = CMAC₈(K.mac, 7F49{ 06 OID, 86 point })`,
    /// where CMAC₈ is the **first 8 bytes** of the AES-CMAC (ICAO Doc 9303 Part 11
    /// §9.8) — not the NXP odd-byte truncation. Each side MACs the *other* side's
    /// mapped-curve ephemeral public key. The MAC key is 16/24/32 bytes.
    static func authToken(macKey: Data, oid: Data, encodedPublicPoint: Data) -> Data {
        let body = encodeTLV([0x06], oid) + encodeTLV([0x86], encodedPublicPoint)
        let publicKeyDO = encodeTLV([0x7F, 0x49], body)
        return EMRTDCrypto.macTruncate8(EMRTDCrypto.aesCMAC(key: macKey, data: publicKeyDO))
    }

    static func encodeTLV(_ tag: [UInt8], _ value: Data) -> Data {
        Data(tag) + berLength(value.count) + value
    }
}
