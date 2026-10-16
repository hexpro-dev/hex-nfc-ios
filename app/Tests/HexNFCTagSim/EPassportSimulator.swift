import Foundation
@testable import HexNFCKit
@testable import HexNFCRecords

/// A stateful electronic-passport (eMRTD) chip simulator — the card side of the
/// BAC handshake and 3DES secure messaging, plus a synthetic set of data groups.
/// It lets `EPassportReader` be exercised end to end (SELECT → BAC → protected
/// reads → decode) with no entitlements and no physical passport, the same way
/// `NTAG424DNASimulator` exercises EV2 auth.
///
/// The synthetic document is the ICAO Doc 9303 "Anna Eriksson" specimen, so its
/// access key is `L898902C` / `690806` / `940623`.
public final class EPassportSimulator: ChipSimulator, @unchecked Sendable {
    public let uid: Data
    public var profile: ChipProfile? {
        ChipCatalog.profile(for: .ePassport)
    }

    /// The specimen key the reader must supply to unlock this chip.
    public static let specimenMRZ = PassportMRZ(
        documentNumber: "L898902C", dateOfBirth: "690806", dateOfExpiry: "940623"
    )

    private let mrzInformation: String
    private let files: [UInt16: Data]
    private let rndICProvider: () -> Data
    private let kICProvider: () -> Data
    /// When true, EF.CardAccess advertises PACE so the reader takes the PACE
    /// path; when false there is no EF.CardAccess and the reader falls back to
    /// BAC.
    private let advertisesPACE: Bool

    // Live state.
    private var applicationSelected = false
    private var challenge: Data?
    private var selectedFile: UInt16?
    private var sm: CardSecureMessagingProtocol?

    // PACE card-side configuration + state.
    private let paceCurve: ECCurve
    private let paceOID: Data
    private let paceMapping: PACE.Mapping
    private let paceKeyBytes: Int
    private let paceNonceProvider: () -> Data
    private let paceY1: BigUInt
    private let paceY2: BigUInt
    private var paceNonce: Data?
    private var paceMapped: ECPoint?
    private var paceReaderX2: ECPoint?
    private var paceCardY2: ECPoint?
    private var paceKSenc: Data?
    private var paceKSmac: Data?

    public init(
        mrz: PassportMRZ = EPassportSimulator.specimenMRZ,
        uid: Data = Data([0x08, 0xA1, 0xB2, 0xC3]),
        advertisesPACE: Bool = false,
        paceMapping: PACE.Mapping = .generic,
        paceParameterId: Int = 13, // Brainpool P256r1
        paceKeyBytes: Int = 16, // AES-128
        rndIC: Data = Data([0x46, 0x08, 0xF9, 0x19, 0x88, 0x70, 0x22, 0x12]),
        kIC: Data = Data([0x0B, 0x4F, 0x80, 0x32, 0x3E, 0xB3, 0x19, 0x1C,
                          0xB0, 0x49, 0x70, 0xCB, 0x40, 0x52, 0x79, 0x0B])
    ) {
        self.uid = uid
        mrzInformation = mrz.mrzInformation
        self.advertisesPACE = advertisesPACE
        rndICProvider = { rndIC }
        kICProvider = { kIC }
        self.paceMapping = paceMapping
        self.paceKeyBytes = paceKeyBytes
        paceCurve = ECCurve.standardizedDomainParameter(paceParameterId) ?? .brainpoolP256r1
        let oid = Self.buildPACEOID(mapping: paceMapping, keyBytes: paceKeyBytes)
        paceOID = oid
        // Nonce s is l/8 bytes: 16 for AES-128, 32 for AES-192/256.
        let nonceLength = paceKeyBytes <= 16 ? 16 : 32
        let nonceSeed = Data([0x3F, 0x00, 0xC4, 0xD3, 0x9D, 0x15, 0x3F, 0x2B,
                              0x2A, 0x21, 0x4A, 0x07, 0x8D, 0x89, 0x9B, 0x22,
                              0x11, 0x93, 0x7C, 0x55, 0xE1, 0x08, 0x4A, 0x2D,
                              0x6B, 0xF0, 0x39, 0xC2, 0x7A, 0x8E, 0x14, 0x5C])
        paceNonceProvider = { Data(nonceSeed.prefix(nonceLength)) }
        paceY1 = BigUInt(bytes: Data([0x5B, 0x2C, 0xF7, 0x18, 0x9A, 0x3D, 0x60, 0x41]))
        paceY2 = BigUInt(bytes: Data([0xC4, 0x1E, 0x8B, 0x77, 0x02, 0xE9, 0x33, 0xA5]))
        files = Self.buildFiles(
            mrz: mrz, includeCardAccess: advertisesPACE, paceOID: oid, parameterId: paceParameterId
        )
    }

    // MARK: - Command dispatch

    public func handle(command: Data) -> Data {
        // Secure-messaging-wrapped commands arrive with CLA 0x0C.
        if command.first == 0x0C {
            guard let sm, let plain = try? sm.unprotectCommand(command) else {
                return Self.sw(0x6987)
            }
            let (data, status) = process(APDU.parse(plain))
            return (try? sm.protectResponse(data, status: status)) ?? Self.sw(0x6987)
        }
        let (data, status) = process(APDU.parse(command))
        return data + Self.sw(status)
    }

    private func process(_ apdu: APDU) -> (Data, UInt16) {
        switch apdu.ins {
        case 0xA4: // SELECT
            if apdu.p1 == 0x04 {
                // SELECT application by AID.
                guard apdu.data == Self.eMRTDAID else { return (Data(), 0x6A82) }
                applicationSelected = true
                return (Data(), 0x9000)
            }
            // SELECT EF by file id.
            guard let fidBytes = apdu.data, fidBytes.count == 2 else { return (Data(), 0x6A82) }
            let fid = (UInt16(fidBytes[fidBytes.startIndex]) << 8) | UInt16(fidBytes[fidBytes.startIndex + 1])
            guard files[fid] != nil else { return (Data(), 0x6A82) }
            // EF.CardAccess is readable at the master file; other EFs need the app.
            guard applicationSelected || fid == 0x011C else { return (Data(), 0x6982) }
            selectedFile = fid
            return (Data(), 0x9000)

        case 0x84: // GET CHALLENGE
            let rnd = rndICProvider()
            challenge = rnd
            return (rnd, 0x9000)

        case 0x82: // EXTERNAL AUTHENTICATE (BAC)
            return externalAuthenticate(apdu.data ?? Data())

        case 0x22: // MSE:Set AT (PACE)
            return mseSetAT(apdu.data ?? Data())

        case 0x86: // GENERAL AUTHENTICATE (PACE)
            return generalAuthenticate(apdu.data ?? Data())

        case 0xB0: // READ BINARY
            return readBinary(apdu)

        default:
            return (Data(), 0x6D00)
        }
    }

    // MARK: - BAC (card side)

    private func externalAuthenticate(_ cmdData: Data) -> (Data, UInt16) {
        guard cmdData.count == 40, let rndIC = challenge else { return (Data(), 0x6984) }
        let keys = EMRTDCrypto.bacKeys(mrzInformation: mrzInformation)
        let eIFD = Data(cmdData.prefix(32))
        let mIFD = Data(cmdData.suffix(8))

        guard let expectedMAC = try? EMRTDCrypto.retailMAC(key: keys.mac, data: eIFD),
              constantTimeEqual(expectedMAC, mIFD) else { return (Data(), 0x6300) }
        guard let s = try? EMRTDCrypto.tripleDESCBCDecrypt(key: keys.enc, iv: Self.zeroIV, data: eIFD),
              s.count == 32 else { return (Data(), 0x6300) }

        let sBytes = [UInt8](s)
        let rIFD = Data(sBytes[0 ..< 8])
        let rIC = Data(sBytes[8 ..< 16])
        let kIFD = Data(sBytes[16 ..< 32])
        guard constantTimeEqual(rIC, rndIC) else { return (Data(), 0x6300) }

        let kIC = kICProvider()
        let r = rndIC + rIFD + kIC // RND.IC ‖ RND.IFD ‖ K.IC
        guard let eIC = try? EMRTDCrypto.tripleDESCBCEncrypt(key: keys.enc, iv: Self.zeroIV, data: r),
              let mIC = try? EMRTDCrypto.retailMAC(key: keys.mac, data: eIC)
        else {
            return (Data(), 0x6300)
        }

        let seed = NTAG424Crypto.xor(kIFD, kIC)
        let ksEnc = EMRTDCrypto.deriveKey(seed: seed, counter: 1)
        let ksMac = EMRTDCrypto.deriveKey(seed: seed, counter: 2)
        let ssc = Data(rndIC.suffix(4)) + Data(rIFD.suffix(4))
        sm = TDESCardSM(ksEnc: ksEnc, ksMac: ksMac, ssc: ssc)
        return (eIC + mIC, 0x9000)
    }

    // MARK: - PACE (card side, ECDH Generic Mapping, AES-128)

    private func mseSetAT(_ cmdData: Data) -> (Data, UInt16) {
        // Accept the PACE OID + MRZ password reference and reset PACE state.
        paceNonce = nil
        paceMapped = nil
        paceReaderX2 = nil
        paceCardY2 = nil
        paceKSenc = nil
        paceKSmac = nil
        return (Data(), 0x9000)
    }

    private func generalAuthenticate(_ cmdData: Data) -> (Data, UInt16) {
        guard let dad = try? BERTLV.parseFirst(cmdData), dad.tag == 0x7C else { return (Data(), 0x6A80) }
        let kpi = PACE.passwordKey(mrzInformation: mrzInformation, keyBytes: paceKeyBytes)
        let zeroIV = Data(repeating: 0, count: 16)

        if let mapData = dad.child(tag: 0x81)?.value {
            // Step 2: map the nonce. Generic Mapping exchanges ephemeral keys;
            // Integrated Mapping receives the terminal nonce t and returns nothing.
            guard let s = paceNonce else { return (Data(), 0x6985) }
            switch paceMapping {
            case .generic:
                guard let bigX1 = paceCurve.decode(mapData) else { return (Data(), 0x6985) }
                let bigY1 = paceCurve.scalarMul(paceY1, paceCurve.g)
                let sharedH = paceCurve.scalarMul(paceY1, bigX1)
                paceMapped = PACE.mappedGenerator(curve: paceCurve, nonce: s, sharedH: sharedH)
                return (Self.tlv(0x7C, Self.tlv(0x82, paceCurve.encode(bigY1))), 0x9000)

            case .integrated:
                guard let mapped = try? PACE.integratedMappedGenerator(
                    curve: paceCurve, nonce: s, terminalNonce: mapData
                ) else { return (Data(), 0x6985) }
                paceMapped = mapped
                return (Self.tlv(0x7C, Self.tlv(0x82, Data())), 0x9000) // 0x82 empty for IM
            }
        }
        if let x2 = dad.child(tag: 0x83)?.value {
            // Step 3: key agreement on the mapped generator.
            guard let bigX2 = paceCurve.decode(x2), let mapped = paceMapped else { return (Data(), 0x6985) }
            paceReaderX2 = bigX2
            let bigY2 = paceCurve.scalarMul(paceY2, mapped)
            paceCardY2 = bigY2
            let shared = paceCurve.scalarMul(paceY2, bigX2)
            let (enc, mac) = PACE.sessionKeys(
                sharedSecretX: shared.x.serialize(byteCount: paceCurve.byteLength), keyBytes: paceKeyBytes
            )
            paceKSenc = enc
            paceKSmac = mac
            return (Self.tlv(0x7C, Self.tlv(0x84, paceCurve.encode(bigY2))), 0x9000)
        }
        if let tIFD = dad.child(tag: 0x85)?.value {
            // Step 4: verify the reader's token, return ours, establish AES SM.
            guard let mac = paceKSmac, let enc = paceKSenc,
                  let cardY2 = paceCardY2, let readerX2 = paceReaderX2 else { return (Data(), 0x6985) }
            let expected = PACE.authToken(macKey: mac, oid: paceOID, encodedPublicPoint: paceCurve.encode(cardY2))
            guard constantTimeEqual(tIFD, expected) else { return (Data(), 0x6300) }
            let tIC = PACE.authToken(macKey: mac, oid: paceOID, encodedPublicPoint: paceCurve.encode(readerX2))
            sm = AESCardSM(ksEnc: enc, ksMac: mac)
            return (Self.tlv(0x7C, Self.tlv(0x86, tIC)), 0x9000)
        }
        // Step 1: return the encrypted nonce.
        let s = paceNonceProvider()
        paceNonce = s
        let enc = EMRTDCrypto.aesCBCEncrypt(key: kpi, iv: zeroIV, data: s)
        return (Self.tlv(0x7C, Self.tlv(0x80, enc)), 0x9000)
    }

    // MARK: - READ BINARY

    private func readBinary(_ apdu: APDU) -> (Data, UInt16) {
        guard let fid = selectedFile, let file = files[fid] else { return (Data(), 0x6986) }
        let offset = (Int(apdu.p1 & 0x7F) << 8) | Int(apdu.p2)
        guard offset <= file.count else { return (Data(), 0x6B00) }
        let requested = apdu.le.map { $0 == 0 ? 256 : Int($0) } ?? 256
        let end = min(offset + requested, file.count)
        return (file.subdata(in: offset ..< end), 0x9000)
    }

    // MARK: - ChipSimulator (non-eMRTD surface is unsupported)

    public func readMemory(range: Range<Int>) throws -> Data {
        throw TagError.capabilityUnsupported(.memoryRead)
    }

    public func writeMemory(at offset: Int, bytes: Data) throws {
        throw TagError.capabilityUnsupported(.memoryWrite)
    }

    public func readNDEF() throws -> Data {
        throw TagError.capabilityUnsupported(.ndefRead)
    }

    public func writeNDEF(_ message: Data) throws {
        throw TagError.capabilityUnsupported(.ndefWrite)
    }

    public func authenticate(password: Data) throws -> Data {
        throw TagError.capabilityUnsupported(.passwordAuth)
    }

    public func setPassword(_ password: Data, pack: Data) throws {
        throw TagError.capabilityUnsupported(.passwordAuth)
    }

    public func permanentLock() throws {
        throw TagError.capabilityUnsupported(.permanentLock)
    }

    // MARK: - Fixtures

    static let eMRTDAID = Data([0xA0, 0x00, 0x00, 0x02, 0x47, 0x10, 0x01])
    static let zeroIV = Data(repeating: 0, count: 8)

    static func sw(_ code: UInt16) -> Data {
        Data([UInt8(code >> 8), UInt8(code & 0xFF)])
    }

    /// Build the id-PACE protocol OID value bytes for a mapping + AES key length.
    static func buildPACEOID(mapping: PACE.Mapping, keyBytes: Int) -> Data {
        let mappingByte: UInt8 = mapping == .generic ? 0x02 : 0x04
        let cipherByte: UInt8 = keyBytes == 16 ? 0x02 : (keyBytes == 24 ? 0x03 : 0x04)
        return Data([0x04, 0x00, 0x7F, 0x00, 0x07, 0x02, 0x02, 0x04, mappingByte, cipherByte])
    }

    /// Build the synthetic EF.COM + data groups for a given MRZ.
    private static func buildFiles(
        mrz: PassportMRZ, includeCardAccess: Bool, paceOID: Data, parameterId: Int
    ) -> [UInt16: Data] {
        // DG1: the specimen TD3 MRZ (2×44), consistent with the access key.
        let line1 = "P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<"
        let line2 = "L898902C<3UTO6908061F9406236ZE184226B<<<<<14"
        let dg1 = tlv(0x61, tlv(0x5F1F, Data((line1 + line2).utf8)))

        // DG2: a CBEFF-ish wrapper around a tiny fake JPEG so the image extractor
        // has a marker to find (real face images are large; this only proves the
        // path).
        let fakeJPEG = Data([0xFF, 0xD8, 0xFF, 0xE0] + [UInt8](repeating: 0x42, count: 24) + [0xFF, 0xD9])
        let faceRecord = Data([0x46, 0x41, 0x43, 0x00]) + fakeJPEG // "FAC\0" + image
        let dg2 = tlv(0x75, tlv(0x5F2E, faceRecord))

        // DG7: displayed signature — a small fake JPEG in a 0x5F43 element.
        let signatureJPEG = Data([0xFF, 0xD8, 0xFF, 0xE0] + [UInt8](repeating: 0x53, count: 16) + [0xFF, 0xD9])
        let dg7 = tlv(0x67, Data([0x02, 0x01, 0x01]) + tlv(0x5F43, signatureJPEG))

        // DG11: additional personal detail.
        let dg11 = tlv(0x6B, tlv(0x5F0E, Data("ERIKSSON<<ANNA<MARIA".utf8))
            + tlv(0x5F11, Data("UTOPIA CITY".utf8)))

        // DG12: additional document detail.
        let dg12 = tlv(0x6C, tlv(0x5F19, Data("UTOPIA PASSPORT OFFICE".utf8))
            + tlv(0x5F26, Data("20200101".utf8)))

        // EF.COM: LDS/unicode versions + present-DG tag list.
        let com = tlv(0x60,
                      tlv(0x5F01, Data("0107".utf8))
                          + tlv(0x5F36, Data("040000".utf8))
                          + tlv(0x5C, Data([0x61, 0x75, 0x67, 0x6B, 0x6C])))

        // EF.SOD: the signed security object listing each DG's SHA-256 hash.
        let sod = buildSOD(dataGroupFiles: [1: dg1, 2: dg2, 7: dg7, 11: dg11, 12: dg12])

        var files: [UInt16: Data] = [
            0x011E: com, 0x0101: dg1, 0x0102: dg2, 0x0107: dg7, 0x010B: dg11, 0x010C: dg12,
            0x011D: sod,
        ]

        if includeCardAccess {
            // EF.CardAccess: SET { SEQUENCE { OID(id-PACE-…), INTEGER version=2,
            // INTEGER parameterId } } — mapping/cipher/curve per the sim's config.
            let oid = tlv(0x06, paceOID)
            let seq = tlv(0x30, oid + tlv(0x02, Data([0x02])) + tlv(0x02, Data([UInt8(parameterId)])))
            files[0x011C] = tlv(0x31, seq)
        }

        return files
    }

    /// Build a minimal but structurally-valid EF.SOD: a CMS `SignedData` whose
    /// eContent is an `LDSSecurityObject` listing each data group's SHA-256 hash.
    /// The signature / certificates / signerInfos are intentionally empty — the
    /// reader does an integrity (hash) check only, never signature verification.
    public static func buildSOD(dataGroupFiles: [Int: Data]) -> Data {
        // AlgorithmIdentifier for SHA-256 (OID 2.16.840.1.101.3.4.2.1).
        let sha256OID = Data([0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01])
        let hashAlgorithm = tlv(0x30, sha256OID)

        // dataGroupHashValues ::= SEQUENCE OF { dgNumber INTEGER, dgHash OCTET }.
        var entries = Data()
        for (dg, file) in dataGroupFiles.sorted(by: { $0.key < $1.key }) {
            let hash = EMRTDCrypto.sha256(file)
            entries += tlv(0x30, tlv(0x02, Data([UInt8(dg)])) + tlv(0x04, hash))
        }
        let hashValues = tlv(0x30, entries)

        // LDSSecurityObject ::= { version INTEGER, hashAlgorithm, dataGroupHashValues }.
        let lds = tlv(0x30, tlv(0x02, Data([0x00])) + hashAlgorithm + hashValues)

        // encapContentInfo: id-icao-mrtd-security-ldsSecurityObject + [0] eContent.
        let icaoOID = Data([0x06, 0x06, 0x67, 0x81, 0x08, 0x01, 0x01, 0x01])
        let encap = tlv(0x30, icaoOID + tlv(0xA0, tlv(0x04, lds)))

        // SignedData: version, digestAlgorithms SET, encapContentInfo, empty signerInfos.
        let signedData = tlv(0x30,
                             tlv(0x02, Data([0x03])) // version v3
                                 + tlv(0x31, hashAlgorithm) // digestAlgorithms
                                 + encap
                                 + tlv(0x31, Data())) // signerInfos (empty — not verified)

        // ContentInfo: id-signedData + [0] SignedData, all wrapped in tag 0x77.
        let signedDataOID = Data([0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x02])
        let contentInfo = tlv(0x30, signedDataOID + tlv(0xA0, signedData))
        return tlv(0x77, contentInfo)
    }

    /// Encode a TLV with a (possibly multi-byte) tag and BER length.
    private static func tlv(_ tag: UInt64, _ value: Data) -> Data {
        var tagBytes: [UInt8] = []
        var t = tag
        while t > 0 {
            tagBytes.insert(UInt8(t & 0xFF), at: 0)
            t >>= 8
        }
        if tagBytes.isEmpty {
            tagBytes = [0]
        }
        return Data(tagBytes) + berLength(value.count) + value
    }
}

/// Card-side secure messaging: unwrap a protected command, wrap a response —
/// the mirror image of the reader's `SecureMessaging`. BAC uses the 3DES
/// variant; PACE uses the AES variant.
private protocol CardSecureMessagingProtocol: AnyObject {
    func unprotectCommand(_ apduBytes: Data) throws -> Data
    func protectResponse(_ responseData: Data, status: UInt16) throws -> Data
}

/// The card side of BAC 3DES secure messaging. The send-sequence counter
/// advances in lockstep with the reader (increment before every received
/// command and every sent response).
private final class TDESCardSM: CardSecureMessagingProtocol {
    private let ksEnc: Data
    private let ksMac: Data
    private var ssc: Data
    private let zeroIV = Data(repeating: 0, count: 8)

    init(ksEnc: Data, ksMac: Data, ssc: Data) {
        self.ksEnc = ksEnc
        self.ksMac = ksMac
        self.ssc = ssc
    }

    func unprotectCommand(_ apduBytes: Data) throws -> Data {
        incrementSSC()
        let apdu = APDU.parse(apduBytes)
        guard let body = apdu.data else { throw SecureMessagingError.malformedResponse }
        let objects = try BERTLV.parse(body)
        guard let do8e = objects.first(where: { $0.tag == 0x8E }) else {
            throw SecureMessagingError.missingMAC
        }

        let maskedHeader = Data([apdu.cla, apdu.ins, apdu.p1, apdu.p2])
        let paddedHeader = EMRTDCrypto.iso9797Method2Pad(maskedHeader, blockSize: 8)
        let do8eLen = do8e.tagBytes.count + berLength(do8e.value.count).count + do8e.value.count
        let macCovered = body.prefix(body.count - do8eLen)
        let expected = try EMRTDCrypto.retailMAC(key: ksMac, data: ssc + paddedHeader + macCovered)
        guard constantTimeEqual(expected, do8e.value) else { throw SecureMessagingError.macMismatch }

        var data = Data()
        if let do87 = objects.first(where: { $0.tag == 0x87 }), do87.value.count > 1 {
            let dec = try EMRTDCrypto.tripleDESCBCDecrypt(key: ksEnc, iv: zeroIV, data: Data(do87.value.dropFirst()))
            data = stripISO9797Method2(dec)
        }
        let le = objects.first(where: { $0.tag == 0x97 })?.value.first

        var plain = Data([apdu.cla & ~0x0C, apdu.ins, apdu.p1, apdu.p2])
        if !data.isEmpty {
            plain.append(UInt8(data.count))
            plain.append(data)
            if let le {
                plain.append(le)
            }
        } else if let le {
            plain.append(le)
        }
        return plain
    }

    func protectResponse(_ responseData: Data, status: UInt16) throws -> Data {
        incrementSSC()
        var do87 = Data()
        if !responseData.isEmpty {
            let padded = EMRTDCrypto.iso9797Method2Pad(responseData, blockSize: 8)
            let enc = try EMRTDCrypto.tripleDESCBCEncrypt(key: ksEnc, iv: zeroIV, data: padded)
            do87.append(0x87)
            do87.append(berLength(enc.count + 1))
            do87.append(0x01)
            do87.append(enc)
        }
        let do99 = Data([0x99, 0x02, UInt8(status >> 8), UInt8(status & 0xFF)])
        let cc = try EMRTDCrypto.retailMAC(key: ksMac, data: ssc + do87 + do99)
        let do8e = Data([0x8E, 0x08]) + cc
        return do87 + do99 + do8e + Data([UInt8(status >> 8), UInt8(status & 0xFF)])
    }

    private func incrementSSC() {
        var carry: UInt16 = 1
        for i in stride(from: ssc.count - 1, through: 0, by: -1) {
            let sum = UInt16(ssc[ssc.startIndex + i]) + carry
            ssc[ssc.startIndex + i] = UInt8(sum & 0xFF)
            carry = sum >> 8
            if carry == 0 {
                break
            }
        }
    }
}

/// The card side of PACE AES-128 secure messaging (16-byte SSC, per-message IV
/// `E(KSenc, SSC)`, AES-CMAC checksum).
private final class AESCardSM: CardSecureMessagingProtocol {
    private let ksEnc: Data
    private let ksMac: Data
    private var ssc: Data

    init(ksEnc: Data, ksMac: Data) {
        self.ksEnc = ksEnc
        self.ksMac = ksMac
        ssc = Data(repeating: 0, count: 16)
    }

    private var iv: Data {
        EMRTDCrypto.aesEncryptBlock(key: ksEnc, ssc)
    }

    func unprotectCommand(_ apduBytes: Data) throws -> Data {
        incrementSSC()
        let apdu = APDU.parse(apduBytes)
        guard let body = apdu.data else { throw SecureMessagingError.malformedResponse }
        let objects = try BERTLV.parse(body)
        guard let do8e = objects.first(where: { $0.tag == 0x8E }) else { throw SecureMessagingError.missingMAC }
        let maskedHeader = Data([apdu.cla, apdu.ins, apdu.p1, apdu.p2])
        let paddedHeader = EMRTDCrypto.iso9797Method2Pad(maskedHeader, blockSize: 16)
        let do8eLen = do8e.tagBytes.count + berLength(do8e.value.count).count + do8e.value.count
        let macCovered = body.prefix(body.count - do8eLen)
        // Pad before CMAC (ICAO §9.8.6) so the sim matches real silicon: the
        // padded input is block-aligned, so CMAC uses subkey K1, not K2.
        let expected = EMRTDCrypto.macTruncate8(EMRTDCrypto.aesCMAC(
            key: ksMac,
            data: EMRTDCrypto.iso9797Method2Pad(ssc + paddedHeader + macCovered, blockSize: 16)
        ))
        guard constantTimeEqual(expected, do8e.value) else { throw SecureMessagingError.macMismatch }

        var data = Data()
        if let do87 = objects.first(where: { $0.tag == 0x87 }), do87.value.count > 1 {
            let dec = EMRTDCrypto.aesCBCDecrypt(key: ksEnc, iv: iv, data: Data(do87.value.dropFirst()))
            data = stripISO9797Method2(dec)
        }
        let le = objects.first(where: { $0.tag == 0x97 })?.value.first

        var plain = Data([apdu.cla & ~0x0C, apdu.ins, apdu.p1, apdu.p2])
        if !data.isEmpty {
            plain.append(UInt8(data.count))
            plain.append(data)
            if let le {
                plain.append(le)
            }
        } else if let le {
            plain.append(le)
        }
        return plain
    }

    func protectResponse(_ responseData: Data, status: UInt16) throws -> Data {
        incrementSSC()
        var do87 = Data()
        if !responseData.isEmpty {
            let padded = EMRTDCrypto.iso9797Method2Pad(responseData, blockSize: 16)
            let enc = EMRTDCrypto.aesCBCEncrypt(key: ksEnc, iv: iv, data: padded)
            do87.append(0x87)
            do87.append(berLength(enc.count + 1))
            do87.append(0x01)
            do87.append(enc)
        }
        let do99 = Data([0x99, 0x02, UInt8(status >> 8), UInt8(status & 0xFF)])
        let cc = EMRTDCrypto.macTruncate8(EMRTDCrypto.aesCMAC(
            key: ksMac,
            data: EMRTDCrypto.iso9797Method2Pad(ssc + do87 + do99, blockSize: 16)
        ))
        let do8e = Data([0x8E, 0x08]) + cc
        return do87 + do99 + do8e + Data([UInt8(status >> 8), UInt8(status & 0xFF)])
    }

    private func incrementSSC() {
        var carry: UInt16 = 1
        for i in stride(from: ssc.count - 1, through: 0, by: -1) {
            let sum = UInt16(ssc[ssc.startIndex + i]) + carry
            ssc[ssc.startIndex + i] = UInt8(sum & 0xFF)
            carry = sum >> 8
            if carry == 0 {
                break
            }
        }
    }
}

// MARK: - Bridge to the reader seam

extension SimulatedConnectedTag: EPassportReadable {
    /// Route passport APDUs straight into the simulator's command handler.
    public func sendAPDU(_ command: Data) async throws -> Data {
        simulator.handle(command: command)
    }
}
