import Foundation
import HexNFCRecords
import Security

/// Orchestrates a read-only eMRTD (passport) read: SELECT the LDS application,
/// run Basic Access Control (PACE is added later and tried first when present),
/// then read the data groups over secure messaging and decode them. Pure and
/// transport-agnostic — it drives an `EPassportReadable`, so the same code runs
/// live and against the simulator.
///
/// No writes, ever. No document verification (Passive Authentication) — the
/// result is presented, not certified.
public struct EPassportReader: Sendable {
    /// What the read attempts. DG1 (MRZ) is always read; the rest are optional
    /// and any individual failure degrades gracefully to "not present".
    public struct Options: Sendable {
        public var includeFaceImage: Bool // DG2
        public var includeExtendedDetails: Bool // DG11 / DG12
        /// Max plaintext bytes per READ BINARY. Kept well under 256 so the
        /// secure-messaging-wrapped response fits comfortably.
        public var maxReadChunk: Int

        public init(
            includeFaceImage: Bool = true,
            includeExtendedDetails: Bool = true,
            maxReadChunk: Int = 0xDF
        ) {
            self.includeFaceImage = includeFaceImage
            self.includeExtendedDetails = includeExtendedDetails
            self.maxReadChunk = maxReadChunk
        }
    }

    /// A coarse progress stage, so the UI can localise its own copy rather than
    /// the kit emitting English strings.
    public enum Stage: Equatable, Sendable {
        case selecting
        case authenticating
        case reading(dataGroup: Int)
        case decoding
    }

    public typealias Progress = @Sendable (Double, Stage) -> Void

    public let options: Options
    private let randomSource: @Sendable (Int) -> Data

    public init(
        options: Options = Options(),
        randomSource: @escaping @Sendable (Int) -> Data = EPassportReader.systemRandom
    ) {
        self.options = options
        self.randomSource = randomSource
    }

    // MARK: - Public entry point

    /// Read and decode the passport. Throws `TagError` on any hard failure
    /// (selection, authentication, or a DG1 that won't decode).
    public func read(
        _ tag: EPassportReadable,
        mrz: PassportMRZ,
        progress: Progress? = nil
    ) async throws -> PassportData {
        let channel = Channel(tag: tag)

        progress?(0.05, .selecting)
        try await performAccessControl(channel, mrz: mrz, progress: progress)

        // Discover which data groups exist (best-effort). Also log the full DG
        // list the document advertises — non-PII (just tag numbers), and the key
        // to seeing what else a given passport exposes beyond DG1/2/11/12.
        var present: [Int]?
        if let com = try? await readFile(channel, fid: Self.efCOM) {
            present = Self.presentDataGroups(inEFCOM: com)
            if let root = try? BERTLV.parseFirst(com), let list = root.firstDescendant(tag: 0x5C) {
                let tags = list.value.map { String(format: "%02X", $0) }.joined(separator: " ")
                NFCTrace.shared.note("EF.COM advertises DG tags: \(tags)", label: "eMRTD")
            }
        }

        var groups: [Int: Data] = [:]

        progress?(0.35, .reading(dataGroup: 1))
        groups[1] = try await readFile(channel, fid: Self.dgFID(1)) // DG1 required

        if options.includeFaceImage, present?.contains(2) ?? true {
            progress?(0.55, .reading(dataGroup: 2))
            groups[2] = try? await readFile(channel, fid: Self.dgFID(2))
        }
        if options.includeExtendedDetails {
            if present?.contains(7) ?? true {
                progress?(0.70, .reading(dataGroup: 7))
                groups[7] = try? await readFile(channel, fid: Self.dgFID(7))
            }
            if present?.contains(11) ?? true {
                progress?(0.75, .reading(dataGroup: 11))
                groups[11] = try? await readFile(channel, fid: Self.dgFID(11))
            }
            if present?.contains(12) ?? true {
                progress?(0.85, .reading(dataGroup: 12))
                groups[12] = try? await readFile(channel, fid: Self.dgFID(12))
            }
        }

        // Document Security Object (EF.SOD) — the signed list of DG hashes. Read
        // last and best-effort; it drives the integrity check only, so a missing
        // or unreadable SOD just leaves integrity unverified.
        let sodData = try? await readFile(channel, fid: Self.efSOD)

        progress?(0.95, .decoding)
        guard var data = PassportDataDecoder.decode(dataGroups: groups) else {
            throw TagError.malformedResponse(
                groups[1] ?? Data(), diagnostics: "eMRTD DG1 decode failed"
            )
        }

        if let sodData, let sod = LDSSecurityObject.parse(sodData) {
            data.integrity = Self.integrityReport(sod: sod, dataGroupFiles: groups)
            if let report = data.integrity {
                NFCTrace.shared.note(
                    "integrity: \(report.status == .verified ? "match" : "MISMATCH") "
                        +
                        "(\(report.hashAlgorithm), DG\(report.checkedDataGroups.map(String.init).joined(separator: ",")))",
                    label: "eMRTD"
                )
            }
        }
        return data
    }

    // MARK: - Integrity (data-group hashes vs the signed security object)

    /// Compare each read data-group file's hash against the value the security
    /// object lists. This is an **integrity** check (data unaltered on the chip),
    /// not an **authenticity** check — the SOD signature/CSCA chain is not
    /// verified. Returns `nil` when no read DG overlaps the security object.
    static func integrityReport(sod: LDSSecurityObject, dataGroupFiles: [Int: Data]) -> PassportIntegrityReport? {
        var checked: [Int] = []
        var mismatched: [Int] = []
        for dg in dataGroupFiles.keys.sorted() {
            guard let bytes = dataGroupFiles[dg], let expected = sod.dataGroupHashes[dg] else { continue }
            checked.append(dg)
            // The SOD hashes the entire DG EF content (outer template tag + all),
            // which is exactly what `readFile` returns.
            let actual = hash(bytes, algorithm: sod.hashAlgorithm)
            if !constantTimeEqual(actual, expected) {
                mismatched.append(dg)
            }
        }
        guard !checked.isEmpty else { return nil }
        return PassportIntegrityReport(
            status: mismatched.isEmpty ? .verified : .mismatch,
            hashAlgorithm: sod.hashAlgorithm.rawValue,
            checkedDataGroups: checked,
            mismatchedDataGroups: mismatched
        )
    }

    private static func hash(_ data: Data, algorithm: LDSSecurityObject.HashAlgorithm) -> Data {
        switch algorithm {
        case .sha1: EMRTDCrypto.sha1(data)
        case .sha224: EMRTDCrypto.sha224(data)
        case .sha256: EMRTDCrypto.sha256(data)
        case .sha384: EMRTDCrypto.sha384(data)
        case .sha512: EMRTDCrypto.sha512(data)
        }
    }

    // MARK: - Access control (PACE first, BAC fallback)

    private func performAccessControl(_ channel: Channel, mrz: PassportMRZ, progress: Progress?) async throws {
        // Modern documents advertise PACE in EF.CardAccess (read at the master
        // file, before selecting the application). If a supported PACE config is
        // present, use it; otherwise fall back to BAC. A PACE that *is* advertised
        // but then fails surfaces the error rather than risking a BAC retry on an
        // uncertain card state.
        if let info = try? await readCardAccess(channel), info.curve != nil {
            NFCTrace.shared.note("access control: PACE (domain param \(info.parameterId))", label: "eMRTD")
            progress?(0.15, .authenticating)
            try await performPACE(channel, mrz: mrz, info: info)
            try await selectApplication(channel) // now under secure messaging
            return
        }
        NFCTrace.shared.note("access control: BAC", label: "eMRTD")
        try await selectApplication(channel) // plain
        progress?(0.15, .authenticating)
        try await performBAC(channel, mrz: mrz)
    }

    private func readCardAccess(_ channel: Channel) async throws -> PACE.Info? {
        // EF.CardAccess is a Master File file, but identification already SELECTed
        // the eMRTD application (to detect the passport), which moves the current
        // DF off the MF. Re-select the MF so the file is reachable — otherwise
        // PACE is never even attempted on real silicon and we always fall to BAC.
        // Best-effort: a card that rejects the explicit MF select is read from
        // wherever it is.
        _ = try? await channel.sendSM(Data([0x00, 0xA4, 0x00, 0x0C, 0x02, 0x3F, 0x00]))
        guard let data = try? await readFile(channel, fid: Self.efCardAccess) else { return nil }
        return PACE.parseInfo(data)
    }

    private func selectApplication(_ channel: Channel) async throws {
        // Uses secure messaging when PACE has established it, plaintext otherwise.
        let (_, sw) = try await channel.sendSM(Self.selectAIDCommand)
        guard sw == 0x9000 else {
            throw TagError.protocolError("SELECT eMRTD application failed", diagnostics: Self.swHex(sw))
        }
    }

    // MARK: - PACE (ECDH Generic / Integrated Mapping, AES-128/192/256)

    private func performPACE(_ channel: Channel, mrz: PassportMRZ, info: PACE.Info) async throws {
        guard let curve = info.curve else {
            throw TagError.protocolError("unsupported PACE domain parameters", diagnostics: "id=\(info.parameterId)")
        }
        do {
            let keyBytes = info.cipher.keyBytes
            let kpi = PACE.passwordKey(mrzInformation: mrz.mrzInformation, keyBytes: keyBytes)

            // MSE:Set AT — select PACE, the OID, and MRZ as the password (0x01).
            let mseData = PACE.encodeTLV([0x80], info.oid) + Data([0x83, 0x01, 0x01])
            var mse = Data([0x00, 0x22, 0xC1, 0xA4, UInt8(mseData.count)])
            mse.append(mseData)
            let (_, mseSW) = try await channel.sendPlain(mse)
            guard mseSW == 0x9000 else { throw PACE.Failure.step("MSE:Set AT", mseSW) }

            // Step 1: request the encrypted nonce and recover s.
            let ga1 = try await generalAuthenticate(channel, doTag: [0x7C], last: false)
            guard let encNonce = extractDO(ga1, outer: 0x7C, inner: 0x80) else {
                throw PACE.Failure.malformedResponse
            }
            let zeroIV = Data(repeating: 0, count: 16)
            let s = EMRTDCrypto.aesCBCDecrypt(key: kpi, iv: zeroIV, data: encNonce)

            // Step 2: mapping — form the mapped generator G'. Generic Mapping
            // does a fresh ECDH (G' = s·G + H); Integrated Mapping derives it
            // directly from s and a terminal nonce t (no key exchange).
            let mapped = try await mapNonce(channel, curve: curve, mapping: info.mapping, keyBytes: keyBytes, nonce: s)

            // Step 3: key agreement on the mapped generator.
            let x2 = randomScalar(curve)
            let bigX2 = curve.scalarMul(x2, mapped)
            let ga3 = try await generalAuthenticate(
                channel, body: PACE.encodeTLV([0x83], curve.encode(bigX2)), last: false
            )
            guard let y2Bytes = extractDO(ga3, outer: 0x7C, inner: 0x84),
                  let bigY2 = curve.decode(y2Bytes) else { throw PACE.Failure.malformedResponse }
            let shared = curve.scalarMul(x2, bigY2)
            let (ksEnc, ksMac) = PACE.sessionKeys(
                sharedSecretX: shared.x.serialize(byteCount: curve.byteLength), keyBytes: keyBytes
            )

            // Step 4: exchange + verify authentication tokens.
            let tIFD = PACE.authToken(macKey: ksMac, oid: info.oid, encodedPublicPoint: curve.encode(bigY2))
            let ga4 = try await generalAuthenticate(channel, body: PACE.encodeTLV([0x85], tIFD), last: true)
            guard let tIC = extractDO(ga4, outer: 0x7C, inner: 0x86) else { throw PACE.Failure.malformedResponse }
            let expectedTIC = PACE.authToken(macKey: ksMac, oid: info.oid, encodedPublicPoint: curve.encode(bigX2))
            guard constantTimeEqual(tIC, expectedTIC) else { throw PACE.Failure.tokenMismatch }

            channel.sm = AESSecureMessaging(ksEnc: ksEnc, ksMac: ksMac)
        } catch {
            throw TagError.authFailed(
                diagnostics: "PACE failed (\(error)). Likely wrong passport details"
            )
        }
    }

    /// PACE Step 2 (Map Nonce): perform the mapping GENERAL AUTHENTICATE and
    /// return the mapped generator `G'` the key agreement will run on.
    private func mapNonce(
        _ channel: Channel,
        curve: ECCurve,
        mapping: PACE.Mapping,
        keyBytes: Int,
        nonce s: Data
    ) async throws -> ECPoint {
        switch mapping {
        case .generic:
            // Generic Mapping: a fresh ephemeral ECDH, then G' = s·G + H where
            // H = x1·Y1 is the shared point.
            let x1 = randomScalar(curve)
            let bigX1 = curve.scalarMul(x1, curve.g)
            let ga = try await generalAuthenticate(
                channel, body: PACE.encodeTLV([0x81], curve.encode(bigX1)), last: false
            )
            guard let y1Bytes = extractDO(ga, outer: 0x7C, inner: 0x82),
                  let bigY1 = curve.decode(y1Bytes) else { throw PACE.Failure.malformedResponse }
            let sharedH = curve.scalarMul(x1, bigY1)
            return PACE.mappedGenerator(curve: curve, nonce: s, sharedH: sharedH)

        case .integrated:
            // Integrated Mapping: the terminal sends a fresh nonce t (k/8 bytes =
            // the AES key length); the chip's 0x82 response is empty. Both sides
            // map (s, t) to the generator with the same public function.
            let t = randomSource(keyBytes)
            _ = try await generalAuthenticate(channel, body: PACE.encodeTLV([0x81], t), last: false)
            return try PACE.integratedMappedGenerator(curve: curve, nonce: s, terminalNonce: t)
        }
    }

    /// Send a GENERAL AUTHENTICATE command carrying a `7C { body }` dynamic
    /// authentication data object. Non-last steps use command chaining (CLA 0x10).
    private func generalAuthenticate(
        _ channel: Channel,
        body: Data = Data(),
        doTag: [UInt8] = [0x7C],
        last: Bool
    ) async throws -> Data {
        let dad = PACE.encodeTLV(doTag, body)
        var cmd = Data([last ? 0x00 : 0x10, 0x86, 0x00, 0x00, UInt8(dad.count)])
        cmd.append(dad)
        cmd.append(0x00) // Le
        let (data, sw) = try await channel.sendPlain(cmd)
        guard sw == 0x9000 else { throw PACE.Failure.step("GENERAL AUTHENTICATE", sw) }
        return data
    }

    /// Extract a context-tagged element (`inner`) nested inside an outer
    /// constructed object (`outer`, the `0x7C` dynamic authentication data).
    private func extractDO(_ data: Data, outer: UInt64, inner: UInt64) -> Data? {
        guard let root = try? BERTLV.parseFirst(data), root.tag == outer else { return nil }
        return root.child(tag: inner)?.value
    }

    private func randomScalar(_ curve: ECCurve) -> BigUInt {
        let value = BigUInt(bytes: randomSource(curve.byteLength)).mod(curve.n)
        return value.isZero ? BigUInt(1) : value
    }

    private func performBAC(_ channel: Channel, mrz: PassportMRZ) async throws {
        // GET CHALLENGE → RND.IC.
        let (challenge, chSW) = try await channel.sendPlain(Data([0x00, 0x84, 0x00, 0x00, 0x08]))
        guard chSW == 0x9000, challenge.count == 8 else {
            throw TagError.protocolError("GET CHALLENGE failed", diagnostics: Self.swHex(chSW))
        }

        let rndIFD = randomSource(8)
        let kIFD = randomSource(16)
        let (cmdData, kEnc, kMac) = try BAC.buildExternalAuthenticate(
            mrzInformation: mrz.mrzInformation, rndIC: challenge, rndIFD: rndIFD, kIFD: kIFD
        )

        var extAuth = Data([0x00, 0x82, 0x00, 0x00, UInt8(cmdData.count)])
        extAuth.append(cmdData)
        extAuth.append(0x28) // Le = 40 (E.IC ‖ M.IC)

        let (authData, authSW) = try await channel.sendPlain(extAuth)
        guard authSW == 0x9000 else {
            // A wrong MRZ manifests here as a non-9000 status.
            throw TagError.authFailed(
                diagnostics: "BAC EXTERNAL AUTHENTICATE SW=\(Self.swHex(authSW)). Likely wrong passport details"
            )
        }

        do {
            let session = try BAC.completeMutualAuthentication(
                responseData: authData,
                rndIC: challenge, rndIFD: rndIFD, kIFD: kIFD, kEnc: kEnc, kMac: kMac
            )
            channel.sm = TDESSecureMessaging(
                ksEnc: session.ksEnc, ksMac: session.ksMac, ssc: session.ssc
            )
        } catch {
            throw TagError.authFailed(
                diagnostics: "BAC session establishment failed: \(error)"
            )
        }
    }

    // MARK: - File reading (secure messaging)

    /// Select an EF by file id and read its whole contents. Reads the first four
    /// bytes to learn the TLV length, then pulls the remainder in chunks.
    private func readFile(_ channel: Channel, fid: UInt16) async throws -> Data {
        let (_, selSW) = try await channel.sendSM(
            Data([0x00, 0xA4, 0x02, 0x0C, 0x02, UInt8(fid >> 8), UInt8(fid & 0xFF)])
        )
        guard selSW == 0x9000 else {
            throw TagError.protocolError("SELECT EF \(Self.hex16(fid)) failed", diagnostics: Self.swHex(selSW))
        }

        let head = try await readBinary(channel, offset: 0, length: 4)
        guard let (headerLen, contentLen) = Self.derLengthPrefix(head) else {
            throw TagError.malformedResponse(head, diagnostics: "EF \(Self.hex16(fid)) length header")
        }
        let total = headerLen + contentLen

        var data = Data(head.prefix(total))
        var offset = data.count
        while offset < total {
            let chunk = min(options.maxReadChunk, total - offset)
            let part = try await readBinary(channel, offset: offset, length: chunk)
            if part.isEmpty {
                break
            }
            data.append(part)
            offset += part.count
        }
        return data.prefix(total)
    }

    private func readBinary(_ channel: Channel, offset: Int, length: Int) async throws -> Data {
        // Short offset addressing (READ BINARY, INS B0) covers files up to
        // 32 767 bytes — enough for DG1/DG11/DG12 and typical DG2 face images.
        // Larger files need the odd-INS extended-offset form; that is a
        // follow-up, and until then an over-large DG2 simply fails its (optional)
        // read and the face image is omitted rather than the whole scan failing.
        guard offset < 0x8000 else {
            throw TagError.protocolError(
                "file exceeds short-offset addressing (offset \(offset))",
                diagnostics: "extended READ BINARY not yet implemented"
            )
        }
        let p1 = UInt8((offset >> 8) & 0x7F)
        let p2 = UInt8(offset & 0xFF)
        let le = UInt8(length & 0xFF) // 256 would encode as 0x00; chunks stay < 256
        let (data, sw) = try await channel.sendSM(Data([0x00, 0xB0, p1, p2, le]))
        guard sw == 0x9000 else {
            throw TagError.protocolError("READ BINARY failed", diagnostics: Self.swHex(sw))
        }
        return data
    }

    // MARK: - Constants & helpers

    /// SELECT by DF name of the eMRTD LDS1 application, AID `A0000002471001`.
    static let selectAIDCommand = Data([
        0x00, 0xA4, 0x04, 0x0C, 0x07, 0xA0, 0x00, 0x00, 0x02, 0x47, 0x10, 0x01,
    ])

    static let efCOM: UInt16 = 0x011E
    static let efCardAccess: UInt16 = 0x011C
    static let efSOD: UInt16 = 0x011D
    /// File identifier of EF.DG*n*. ICAO Doc 9303 Part 10 §3.6.2 assigns
    /// EF.DG1 through EF.DG16 the contiguous range `0x0101`-`0x0110`, so the
    /// mapping is arithmetic rather than a table. It used to be a dictionary,
    /// which made every call site a force unwrap of a key the reader could see
    /// was present; a total function removes the unwrap instead of justifying
    /// it five times.
    static func dgFID(_ group: Int) -> UInt16 {
        0x0100 | UInt16(group)
    }

    /// Map the DG tags listed in EF.COM's `0x5C` tag-list to DG numbers.
    static func presentDataGroups(inEFCOM bytes: Data) -> [Int]? {
        guard
            let root = try? BERTLV.parseFirst(bytes),
            let list = root.firstDescendant(tag: 0x5C)
        else { return nil }
        let map: [UInt8: Int] = [0x61: 1, 0x75: 2, 0x67: 7, 0x6B: 11, 0x6C: 12]
        return list.value.compactMap { map[$0] }
    }

    /// Parse the leading TLV tag+length of a file to learn its total size.
    static func derLengthPrefix(_ data: Data) -> (headerLen: Int, contentLen: Int)? {
        let b = [UInt8](data)
        guard !b.isEmpty else { return nil }
        var i = 0
        // Tag (possibly multi-byte).
        let firstTag = b[i]
        i += 1
        if (firstTag & 0x1F) == 0x1F {
            while i < b.count, (b[i] & 0x80) != 0 {
                i += 1
            }
            guard i < b.count else { return nil }
            i += 1
        }
        guard i < b.count else { return nil }
        // Length.
        let l0 = b[i]
        i += 1
        var contentLen: Int
        if l0 & 0x80 == 0 {
            contentLen = Int(l0)
        } else {
            let n = Int(l0 & 0x7F)
            guard n > 0, i + n <= b.count else { return nil }
            contentLen = 0
            for _ in 0 ..< n {
                contentLen = (contentLen << 8) | Int(b[i])
                i += 1
            }
        }
        return (headerLen: i, contentLen: contentLen)
    }

    static func swHex(_ sw: UInt16) -> String {
        String(format: "SW=%04X", sw)
    }

    static func hex16(_ v: UInt16) -> String {
        String(format: "%04X", v)
    }

    /// Cryptographically secure randoms for the BAC nonces. Injectable so the
    /// simulator tests are deterministic.
    public static let systemRandom: @Sendable (Int) -> Data = { count in
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            for i in 0 ..< count {
                bytes[i] = UInt8.random(in: 0 ... 255)
            }
        }
        return Data(bytes)
    }
}

/// Command channel over an `EPassportReadable`: sends plaintext before secure
/// messaging is established, and wraps/unwraps once it is.
private final class Channel {
    let tag: EPassportReadable
    var sm: SecureMessaging?

    init(tag: EPassportReadable) {
        self.tag = tag
    }

    func sendPlain(_ apdu: Data) async throws -> (data: Data, sw: UInt16) {
        try await Self.split(tag.sendAPDU(apdu))
    }

    func sendSM(_ apdu: Data) async throws -> (data: Data, sw: UInt16) {
        guard let sm else { return try await sendPlain(apdu) }
        let protected = try sm.protect(apdu)
        let response = try await tag.sendAPDU(protected)
        return try Self.split(sm.unprotect(response))
    }

    static func split(_ response: Data) -> (data: Data, sw: UInt16) {
        guard response.count >= 2 else { return (response, 0) }
        let sw = (UInt16(response[response.endIndex - 2]) << 8) | UInt16(response[response.endIndex - 1])
        return (Data(response.dropLast(2)), sw)
    }
}
