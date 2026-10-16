import Foundation
@testable import HexNFCKit
@testable import HexNFCRecords

/// NXP NTAG424 DNA simulator.
///
/// Implements:
///   - **ISO 7816 NDEF Tag App** path (CLA `0x00`) — SELECT by AID,
///     SELECT by file ID, READ BINARY, UPDATE BINARY. The simplest way to
///     drive NDEF round-trips against a Type-4 chip.
///   - **DESFire-style command set** (CLA `0x90`) — AuthenticateEV2First
///     (`0x71` / `0xAF`), GetCardUID (`0x51`), GetKeyVersion (`0x64`),
///     GetVersion (`0x60`), GetFileSettings (`0x5F`), ChangeFileSettings
///     (`0x5C`), ChangeKey (`0xC4`), ReadData (`0xAD`), WriteData (`0x8D`).
///
/// Datasheet: NXP NT4H2421Gx rev 3.2.
/// Crypto layer: see `NTAG424Crypto`.
public final class NTAG424DNASimulator: ChipSimulator, @unchecked Sendable {
    public let uid: Data
    public let profile: ChipProfile? = ChipCatalog.profile(for: .ntag424DNA)

    /// Five AES-128 keys, slot 0..4. Slot 0 is the application master key.
    /// Factory default is all zeros per datasheet §9.
    public private(set) var keys: [Data]

    /// Key version per slot, as `GetKeyVersion` (`0x64`) reports it.
    ///
    /// Held rather than returned as a constant `0x00`, because the production
    /// driver writes a version byte with every ChangeKey (`0x01` when it
    /// programmes a user key, `0x00` when it resets one) and now reads it back
    /// to order its candidate list. With a constant here, CI could not tell a
    /// tag this app had personalised from one at delivery, which is the one
    /// distinction the recovery path turns on.
    ///
    /// Delivery value is `0x00` for every slot (NT4H2421Gx rev 3.2 §9).
    public private(set) var keyVersions: [UInt8]

    /// Live session state, populated by a successful AuthenticateEV2First.
    public private(set) var session: SessionState?

    /// Test-only nonce provider — defaults to a deterministic sequence so
    /// auth round-trips reproduce the same RndB across runs. Override for
    /// unique-per-test behaviour.
    public var nonceProvider: () -> Data = NTAG424DNASimulator.defaultNonceProvider()

    public private(set) var ndefFile: Data
    public private(set) var ccFile: Data
    public private(set) var proprietaryFile: Data = .init(repeating: 0x00, count: 32)

    /// Per-file settings — drives ReadData / WriteData CommMode enforcement.
    public private(set) var fileSettings: [FileID: FileSettings]

    /// Selected file for the ISO 7816 NDEF Tag App path.
    public private(set) var selectedFile: SelectedFile = .none

    /// `0x71` puts the simulator into "awaiting second auth frame" state;
    /// the next `0xAF` carries the encrypted `RndA || RndB'` payload.
    private var pendingAuth: PendingAuth?

    // MARK: - Types

    public enum SelectedFile { case none, app, cc, ndef, proprietary }

    public enum FileID: UInt16, Hashable, Sendable { case cc = 0xE103, ndef = 0xE104, proprietary = 0xE105 }

    public struct FileSettings: Hashable, Sendable {
        public var fileType: UInt8 // 0x00 standard, 0x05 cyclic
        public var commMode: CommMode // .plain / .mac / .full
        public var accessRights: UInt16 // 4 nibbles: RW | Change | R | W
        public var fileSize: Int
        public var sunEnabled: Bool
        public init(fileType: UInt8, commMode: CommMode, accessRights: UInt16, fileSize: Int,
                    sunEnabled: Bool = false)
        {
            self.fileType = fileType
            self.commMode = commMode
            self.accessRights = accessRights
            self.fileSize = fileSize
            self.sunEnabled = sunEnabled
        }
    }

    public enum CommMode: UInt8, Hashable, Sendable { case plain = 0, mac = 1, full = 3 }

    public struct SessionState: Hashable, Sendable {
        public let keyNumber: UInt8
        public let encKey: Data // SesAuthENCKey
        public let macKey: Data // SesAuthMACKey
        public let ti: Data // 4-byte Transaction Identifier
        public var cmdCtr: UInt16 // monotonic per command
        public let randA: Data // captured for SUN/IV derivation
        public let randB: Data
    }

    private struct PendingAuth {
        let keyNo: UInt8
        let randB: Data
    }

    // MARK: - Init

    public init(
        uid: Data = NTAG424DNASimulator.defaultUID,
        ndefMessage: Data? = nil,
        keys: [Data] = NTAG424DNASimulator.defaultKeys
    ) {
        precondition(uid.count == 7, "NTAG424 UID is 7 bytes")
        precondition(keys.count == 5, "NTAG424 has 5 AES key slots")
        for key in keys {
            precondition(key.count == 16, "AES-128 keys are 16 bytes each")
        }
        self.uid = uid
        self.keys = keys
        keyVersions = [UInt8](repeating: 0x00, count: keys.count)

        // CC file (NDEF Tag App), 15 bytes:
        //   CCLEN=0x000F, Mapping=0x20, MLe=0x0040, MLc=0x0040,
        //   TLV: 0x04 0x06 0xE104 0x0100 0x0000
        ccFile = Data([
            0x00, 0x0F,
            0x20,
            0x00, 0x40,
            0x00, 0x40,
            0x04, 0x06,
            0xE1, 0x04,
            0x01, 0x00,
            0x00, 0x00,
        ])

        if let message = ndefMessage {
            ndefFile = Self.wrapWithLength(message)
        } else {
            ndefFile = Data([0x00, 0x00])
        }

        // Factory defaults: Read/Write/ReadWrite free (0xE), but the **Change**
        // access stays key 0 (0x0) — the NDEF file reads back `E0 EE` on real
        // silicon (confirmed on hardware). NOT `0xEEEE`: a free Change nibble
        // makes the file accept only a *plain* ChangeFileSettings, so modelling it
        // as free hid a real re-protect bug. Plain comm-mode; canonical file sizes.
        fileSettings = [
            .cc: FileSettings(fileType: 0x00, commMode: .plain, accessRights: 0xE0EE, fileSize: 32),
            .ndef: FileSettings(fileType: 0x00, commMode: .plain, accessRights: 0xE0EE, fileSize: 256),
            .proprietary: FileSettings(fileType: 0x00, commMode: .plain, accessRights: 0xE0EE, fileSize: 128),
        ]
    }

    // MARK: - APDU dispatch

    public func handle(command: Data) -> Data {
        guard command.count >= 4 else { return Self.swError }
        let cla = command[command.startIndex]
        let ins = command[command.startIndex + 1]
        let p1 = command[command.startIndex + 2]
        let p2 = command[command.startIndex + 3]

        switch cla {
        case 0x00:
            // ISO 7816 NDEF Tag App pathway.
            switch ins {
            case 0xA4: return handleSelect(p1: p1, p2: p2, command: command)
            case 0xB0: return handleReadBinary(p1: p1, p2: p2, command: command)
            case 0xD6: return handleUpdateBinary(p1: p1, p2: p2, command: command)
            default: return Self.swError
            }

        case 0x90:
            // DESFire-style pathway.
            //
            // ⚠️ Native file commands are refused at PICC level until the NDEF
            // application has been ISO-SELECTed — live-observed 2026-07-01,
            // when `90 F5` GetFileSettings answered `91 9D` PERMISSION_DENIED
            // and the harness step failed on silicon while passing here.
            //
            // The harness was fixed then; this simulator was not, so it kept
            // answering every native command in any state. Production survives
            // only because `NTAG424ProtectionDriver` calls `selectNDEFApp()`
            // first — delete or reorder that one line and CI stays green while
            // real tags answer `91 9D`, `readProtectionState` throws, and its
            // `try?` callers turn that into "unprotected". That is precisely
            // the shape of the SLIX2 bug: a permissive simulator validating
            // logic the silicon rejects.
            //
            // **Scoped to what was actually observed.** The live capture was of
            // a *file* command (`90 F5`), so only the file commands are gated
            // here: GetFileSettings, ChangeFileSettings, ReadData, WriteData.
            // GetVersion, GetCardUID, GetKeyVersion, the EV2 handshake and
            // ChangeKey stay reachable before selection — not because they are
            // known to be PICC-level, but because we have no evidence they are
            // gated, and a simulator that invents a refusal is the same fiction
            // as one that invents an answer. Widen this only with a trace.
            let fileLevelCommands: Set<UInt8> = [0xF5, 0x5F, 0xAD, 0x8D]
            guard !fileLevelCommands.contains(ins) || selectedFile != .none else {
                return Self.swPermissionDenied
            }
            switch ins {
            case 0x71: return handleAuthenticateEV2First(command: command)
            case 0xAF: return handleAuthenticateContinue(command: command)
            case 0x51: return handleGetCardUID()
            case 0x64: return handleGetKeyVersion(command: command)
            case 0x60: return handleGetVersion()
            case 0xF5: return handleGetFileSettings(command: command)
            case 0x5F: return handleChangeFileSettings(command: command)
            case 0xC4: return handleChangeKey(command: command)
            case 0xAD: return handleReadData(command: command)
            case 0x8D: return handleWriteData(command: command)
            default: return Self.swDESFireError
            }

        default:
            return Self.swError
        }
    }

    // MARK: - ISO 7816 path (NDEF Tag App)

    private func handleSelect(p1: UInt8, p2: UInt8, command: Data) -> Data {
        guard command.count >= 5 else { return Self.swError }
        let lc = Int(command[command.startIndex + 4])
        guard command.count >= 5 + lc else { return Self.swError }
        let data = command.subdata(in: (command.startIndex + 5) ..< (command.startIndex + 5 + lc))

        if p1 == 0x04 {
            if data == Self.ndefAppAID {
                selectedFile = .app
                // **A SELECT ends the EV2 session. Measured 2026-09-20.**
                //
                // This used to leave the session alone, on the argument that
                // modelling the reset broke
                // `test_writeFlow_protected424_withKey_rewritesInOneTap`, which
                // was called hardware-validated. It was not: no capture in this
                // repo ever recorded that flow, and the claim is the one the
                // 2026-09-07 audit could not find a source for.
                //
                // The capture that settles it (bench-results-2026-09.md, T4-1,
                // UID 04:89:37:CA:9C:17:90) sends one plain GetFileSettings
                // inside a live session and the identical frame again after a
                // SELECT, in one activation: `91 7E` then `91 00`. A live
                // session refuses that frame, so the session was gone.
                //
                // What this breaks in CI is the defect, not the model: the
                // shipping write route for a protected 424 authenticates,
                // re-SELECTs while probing protection, and then writes inside a
                // session the chip has already discarded.
                session = nil
                return Self.swOK
            }
            return Self.swFileNotFound
        }
        if p1 == 0x00, p2 == 0x0C, data.count == 2 {
            let fileID = (UInt16(data[data.startIndex]) << 8) | UInt16(data[data.startIndex + 1])
            switch fileID {
            case 0xE103: selectedFile = .cc
                return Self.swOK

            case 0xE104: selectedFile = .ndef
                return Self.swOK

            case 0xE105: selectedFile = .proprietary
                return Self.swOK

            default: return Self.swFileNotFound
            }
        }
        return Self.swError
    }

    private func handleReadBinary(p1: UInt8, p2: UInt8, command: Data) -> Data {
        let offset = (Int(p1) << 8) | Int(p2)
        let le = command.last.map { $0 == 0x00 ? 256 : Int($0) } ?? 0
        let source: Data
        switch selectedFile {
        case .cc:
            guard readAllowed(.cc) else { return Self.swSecurity }
            source = ccFile

        case .ndef:
            guard readAllowed(.ndef) else { return Self.swSecurity }
            source = ndefFile

        case .proprietary:
            guard readAllowed(.proprietary) else { return Self.swSecurity }
            source = proprietaryFile

        default: return Self.swError
        }
        guard offset <= source.count else { return Self.swError }
        let end = min(source.count, offset + le)
        let bytes = source.subdata(in: (source.startIndex + offset) ..< (source.startIndex + end))
        return bytes + Self.swOK
    }

    private func handleUpdateBinary(p1: UInt8, p2: UInt8, command: Data) -> Data {
        guard selectedFile == .ndef else { return Self.swError }
        // A key-gated NDEF file refuses the plain ISO write path (the route an
        // unauthenticated reader / iOS's high-level writeNDEF would take).
        guard writeAllowed(.ndef) else { return Self.swSecurity }
        let offset = (Int(p1) << 8) | Int(p2)
        guard command.count >= 5 else { return Self.swError }
        let lc = Int(command[command.startIndex + 4])
        guard command.count >= 5 + lc else { return Self.swError }
        let payload = command.subdata(in: (command.startIndex + 5) ..< (command.startIndex + 5 + lc))

        if offset + payload.count > ndefFile.count {
            ndefFile.append(contentsOf: [UInt8](repeating: 0x00, count: offset + payload.count - ndefFile.count))
        }
        ndefFile.replaceSubrange(
            (ndefFile.startIndex + offset) ..< (ndefFile.startIndex + offset + payload.count),
            with: payload
        )
        return Self.swOK
    }

    // MARK: - DESFire path: AuthenticateEV2First

    private func handleAuthenticateEV2First(command: Data) -> Data {
        // Wire format: 90 71 00 00 02 KeyNo LenCap=00 Le=00
        guard command.count >= 7 else { return Self.swDESFireError }
        let keyNo = command[command.startIndex + 5]
        guard Int(keyNo) < keys.count else { return Self.swPermissionDenied }

        let key = keys[Int(keyNo)]
        let randB = nonceProvider()
        let encRandB = NTAG424Crypto.aesCBCEncrypt(
            key: key, iv: Data(repeating: 0x00, count: 16), data: randB
        )
        pendingAuth = PendingAuth(keyNo: keyNo, randB: randB)
        return encRandB + Self.swAdditionalFrame
    }

    private func handleAuthenticateContinue(command: Data) -> Data {
        guard let pending = pendingAuth else { return Self.swDESFireError }
        defer { pendingAuth = nil }

        // Wire format: 90 AF 00 00 20 <32 bytes ciphertext> Le=00
        guard command.count >= 6 + 32 else { return Self.swDESFireError }
        let lc = Int(command[command.startIndex + 4])
        guard lc == 32 else { return Self.swDESFireError }
        let ciphertext = command.subdata(in: (command.startIndex + 5) ..< (command.startIndex + 5 + 32))

        let key = keys[Int(pending.keyNo)]
        let plain = NTAG424Crypto.aesCBCDecrypt(
            key: key, iv: Data(repeating: 0x00, count: 16), data: ciphertext
        )
        let randA = plain.subdata(in: 0 ..< 16)
        let randBPrime = plain.subdata(in: 16 ..< 32)
        let expectedRandBPrime = NTAG424Crypto.rotateLeftByOne(pending.randB)
        guard randBPrime == expectedRandBPrime else { return Self.swPermissionDenied }

        // Derive session keys.
        let encKey = NTAG424Crypto.deriveENCKey(appKey: key, randA: randA, randB: pending.randB)
        let macKey = NTAG424Crypto.deriveMACKey(appKey: key, randA: randA, randB: pending.randB)
        let ti = Data((0 ..< 4).map { _ in UInt8.random(in: 0 ... 255) })

        session = SessionState(
            keyNumber: pending.keyNo,
            encKey: encKey,
            macKey: macKey,
            ti: ti,
            cmdCtr: 0,
            randA: randA,
            randB: pending.randB
        )

        // Build response payload: TI (4) || RndA' (16) || PDcap2 (6) || PCDcap2 (6) = 32 bytes.
        var responsePlain = Data()
        responsePlain.append(ti)
        responsePlain.append(NTAG424Crypto.rotateLeftByOne(randA))
        responsePlain.append(Data(repeating: 0x00, count: 6)) // PDcap2 (chip capabilities)
        responsePlain.append(Data(repeating: 0x00, count: 6)) // PCDcap2 (reader capabilities echo)

        let responseCipher = NTAG424Crypto.aesCBCEncrypt(
            key: key, iv: Data(repeating: 0x00, count: 16), data: responsePlain
        )
        return responseCipher + Self.swOK91
    }

    // MARK: - DESFire path: GetCardUID

    private func handleGetCardUID() -> Data {
        // Real chips wrap with the session MAC; for now we return the UID
        // plus 9100 plain. Adding MAC wrapping is a one-line change once
        // we settle on the CmdCtr layout.
        guard session != nil else { return Self.swAuthRequired }
        return uid + Self.swOK91
    }

    // MARK: - DESFire path: GetKeyVersion

    private func handleGetKeyVersion(command: Data) -> Data {
        // 90 64 00 00 01 KeyNo 00 — returns 1 byte version + 91 00.
        guard command.count >= 7 else { return Self.swDESFireError }
        let keyNo = command[command.startIndex + 5]
        guard Int(keyNo) < keys.count else { return Self.swPermissionDenied }
        return Data([keyVersions[Int(keyNo)]]) + Self.swOK91
    }

    // MARK: - DESFire path: GetVersion (three-frame chained)

    /// Implemented as a single 28-byte response with 91 00 — real chips
    /// chain over three frames with 91AF terminators. The kit side
    /// reassembles either form transparently.
    private func handleGetVersion() -> Data {
        var data = Data()
        // Hardware information (7 bytes).
        data.append(contentsOf: [0x04, 0x04, 0x02, 0x30, 0x00, 0x11, 0x05])
        // Software information (7 bytes).
        data.append(contentsOf: [0x04, 0x04, 0x02, 0x30, 0x00, 0x11, 0x05])
        // UID + batch + date (14 bytes).
        data.append(uid)
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x01]) // batch (5)
        data.append(contentsOf: [0x00, 0x00]) // production CW + year
        return data + Self.swOK91
    }

    // MARK: - DESFire path: GetFileSettings / ChangeFileSettings

    private func handleGetFileSettings(command: Data) -> Data {
        guard command.count >= 6 else { return Self.swDESFireError }
        // **A plain GetFileSettings inside a live EV2 session is refused
        // `91 7E`. Measured 2026-09-20**, same capture as `handleSelect`: the
        // command must carry its MAC inside a session, so a plain one is the
        // wrong length. `NTAG424ProtectionDriver` has asserted this in a comment
        // since the secure NDEF I/O landed, and caches the file's comm mode
        // before authenticating rather than re-reading it in-session for exactly
        // this reason. It is modelled here now that a tag has said it, and it is
        // safe to model alongside the SELECT reset above: after a re-SELECT the
        // session is gone, so the read-backs that follow one are plain reads on
        // an unauthenticated chip, which is what the same capture shows
        // answering `91 00`.
        guard session == nil else { return Self.swLengthError }
        let fileNo = command[command.startIndex + 5]
        guard let id = fileIDFromNumber(fileNo), let settings = fileSettings[id] else {
            return Self.swFileNotFoundDESFire
        }
        var response = Data()
        response.append(settings.fileType)
        response.append(settings.commMode.rawValue | (settings.sunEnabled ? 0x40 : 0x00))
        // AccessRights on the wire: (ReadWrite|Change) byte first, then (Read|Write)
        // — big-endian for the RW|Change|R|W word, matching real silicon.
        response.append(UInt8((settings.accessRights >> 8) & 0xFF))
        response.append(UInt8(settings.accessRights & 0xFF))
        // File size as 3-byte little-endian.
        response.append(UInt8(settings.fileSize & 0xFF))
        response.append(UInt8((settings.fileSize >> 8) & 0xFF))
        response.append(UInt8((settings.fileSize >> 16) & 0xFF))
        return response + Self.swOK91
    }

    /// Full secure-messaging form (AN12196 §6.5): `90 5C 00 00 Lc FileNo
    /// EncCmdData(16) MACt(8) Le`. EncCmdData decrypts (under IVc) to
    /// `FileOption(1) || AccessRights(2 LE) || 0x80 padding`. Verifies the
    /// command MAC before touching state, matching what the production driver
    /// emits — so a malformed wrapping can't "pass the simulator".
    private func handleChangeFileSettings(command: Data) -> Data {
        if let plain = handlePlainChangeFileSettings(command: command) {
            return plain
        }
        guard var session else { return Self.swAuthRequired }
        guard command.count >= 5 + 1 + 16 + 8 else { return Self.swDESFireError }
        let fileNo = command[command.startIndex + 5]
        guard let id = fileIDFromNumber(fileNo) else { return Self.swFileNotFoundDESFire }
        let enc = command.subdata(in: (command.startIndex + 6) ..< (command.startIndex + 6 + 16))
        let receivedMAC = command.subdata(in: (command.startIndex + 22) ..< (command.startIndex + 22 + 8))

        let expectedMAC = NTAG424Crypto.commandMAC(
            sesAuthMACKey: session.macKey, cmdINS: 0x5F, cmdCtr: session.cmdCtr,
            ti: session.ti, cmdHeader: Data([fileNo]), encCmdData: enc
        )
        guard receivedMAC == expectedMAC else { return Self.swDESFireError }

        let iv = NTAG424Crypto.commandIV(sesAuthENCKey: session.encKey, ti: session.ti, cmdCtr: session.cmdCtr)
        let plain = NTAG424Crypto.aesCBCDecrypt(key: session.encKey, iv: iv, data: enc)
        guard plain.count >= 3 else { return Self.swDESFireError }

        var settings = fileSettings[id] ?? FileSettings(
            fileType: 0x00, commMode: .plain, accessRights: 0xEEEE, fileSize: 256
        )
        let commByte = plain[plain.startIndex]
        settings.commMode = CommMode(rawValue: commByte & 0x03) ?? .plain
        settings.sunEnabled = (commByte & 0x40) != 0
        // CmdData AccessRights are (ReadWrite|Change) then (Read|Write) — big-endian.
        let arHigh = plain[plain.startIndex + 1] // (ReadWrite | Change)
        let arLow = plain[plain.startIndex + 2] // (Read | Write)
        settings.accessRights = (UInt16(arHigh) << 8) | UInt16(arLow)
        fileSettings[id] = settings

        session.cmdCtr = session.cmdCtr &+ 1
        self.session = session
        return Self.swOK91
    }

    /// The **plain** form: `90 5F 00 00 04 FileNo FileOption AR(2) 00`, no MAC,
    /// no session.
    ///
    /// Accepted only while the target file's Change nibble is free (`0xE`),
    /// which is the one state that *requires* this form: a free-Change file
    /// refuses the Full-mode ChangeFileSettings with `91 9E`. The production
    /// driver has emitted this frame since the over-freed-Change recovery
    /// landed; nothing here could run it, so the recovery had no test.
    ///
    /// Returns `nil` when the frame is not the plain form, so the caller falls
    /// through to the secure one.
    private func handlePlainChangeFileSettings(command: Data) -> Data? {
        guard command.count >= 5 else { return nil }
        let lc = Int(command[command.startIndex + 4])
        guard lc == 4, command.count >= 5 + 4 else { return nil }
        let fileNo = command[command.startIndex + 5]
        guard let id = fileIDFromNumber(fileNo) else { return Self.swFileNotFoundDESFire }
        guard var settings = fileSettings[id] else { return Self.swFileNotFoundDESFire }
        guard ((settings.accessRights >> 8) & 0x0F) == 0x0E else {
            // Change is gated by a key, so the plain form is not the one the
            // chip wants. `91 9E` PARAMETER_ERROR is what the production driver
            // names for the mirror-image mistake (a Full-mode CFS on a
            // free-Change file), and the same code is used here rather than an
            // invented one.
            return Data([0x91, 0x9E])
        }
        let commByte = command[command.startIndex + 6]
        let arHigh = command[command.startIndex + 7] // (ReadWrite | Change)
        let arLow = command[command.startIndex + 8] // (Read | Write)
        settings.commMode = CommMode(rawValue: commByte & 0x03) ?? .plain
        settings.sunEnabled = (commByte & 0x40) != 0
        settings.accessRights = (UInt16(arHigh) << 8) | UInt16(arLow)
        fileSettings[id] = settings
        return Self.swOK91
    }

    // MARK: - Access-rights enforcement

    //
    // Access rights are 4 nibbles `RW | Change | R | W` (free = `0xE`, never =
    // `0xF`). A command is permitted if the relevant nibble is free, or a live
    // session's key matches it. This is what makes a key-gated NDEF file actually
    // refuse unauthenticated writes/reads — the behaviour the protection tests
    // assert.

    private func accessSatisfied(_ nibble: UInt16) -> Bool {
        switch nibble {
        case 0x0E: true // free
        case 0x0F: false // denied (no key)
        default: session.map { UInt16($0.keyNumber) == nibble } ?? false
        }
    }

    private func writeAllowed(_ id: FileID) -> Bool {
        guard let ar = fileSettings[id]?.accessRights else { return true }
        return accessSatisfied(ar & 0x0F) || accessSatisfied((ar >> 12) & 0x0F)
    }

    private func readAllowed(_ id: FileID) -> Bool {
        guard let ar = fileSettings[id]?.accessRights else { return true }
        return accessSatisfied((ar >> 4) & 0x0F) || accessSatisfied((ar >> 12) & 0x0F)
    }

    // MARK: - DESFire path: ChangeKey (full AN12196 §6.16 cryptogram)

    /// Bit-perfect ChangeKey per AN12196 §6.16. Wire layout:
    ///
    /// ```
    /// 90 C4 00 00 29 KeyNo EncCryptogram(32) MACt(8) 00
    /// ```
    ///
    /// Where EncCryptogram is `AES-CBC-Enc(SesAuthENCKey, IVc, plaintext)`
    /// with two layouts depending on whether the target key is the
    /// currently-authenticated one. The MAC covers
    /// `0xC4 || CmdCtr_LE || TI || KeyNo || EncCryptogram`.
    private func handleChangeKey(command: Data) -> Data {
        guard var session else { return Self.swAuthRequired }
        // 5 byte APDU header + 1 KeyNo + 32 EncCryptogram + 8 MACt + 1 Le.
        guard command.count >= 5 + 1 + 32 + 8 + 1 else { return Self.swDESFireError }
        let keyNo = command[command.startIndex + 5] & 0x0F
        guard Int(keyNo) < keys.count else { return Self.swPermissionDenied }
        let encCryptogram = command.subdata(
            in: (command.startIndex + 6) ..< (command.startIndex + 6 + 32)
        )
        let receivedMAC = command.subdata(
            in: (command.startIndex + 6 + 32) ..< (command.startIndex + 6 + 32 + 8)
        )

        // Verify command MAC before touching state.
        let expectedMAC = NTAG424Crypto.commandMAC(
            sesAuthMACKey: session.macKey,
            cmdINS: 0xC4,
            cmdCtr: session.cmdCtr,
            ti: session.ti,
            cmdHeader: Data([keyNo]),
            encCmdData: encCryptogram
        )
        guard receivedMAC == expectedMAC else { return Self.swDESFireError }

        // Decrypt the cryptogram under IVc.
        let iv = NTAG424Crypto.commandIV(
            sesAuthENCKey: session.encKey,
            ti: session.ti,
            cmdCtr: session.cmdCtr
        )
        let plaintext = NTAG424Crypto.aesCBCDecrypt(
            key: session.encKey, iv: iv, data: encCryptogram
        )
        guard plaintext.count == 32 else { return Self.swDESFireError }

        // The version byte sits at plaintext[16] in both layouts, and the chip
        // stores it: `GetKeyVersion` reports it back afterwards. Applied only
        // once the key itself is accepted, so a rejected cryptogram cannot move
        // the version.
        let newKeyVersion = plaintext[plaintext.startIndex + 16]

        if keyNo == session.keyNumber {
            // Case 2 (AN12196 Table 27): same key — no XOR, no CRC.
            //   plaintext = NewKey(16) || NewKeyVer(1) || 0x80 || 0x00 × 14
            let newKey = plaintext.subdata(in: 0 ..< 16)
            keys[Int(keyNo)] = newKey
        } else {
            // Case 1 (AN12196 Table 26): different key.
            //   plaintext = (NewKey XOR OldKey)(16) || NewKeyVer(1) || CRC32_LE(NewKey)(4) || 0x80 || 0x00 × 10
            let xored = plaintext.subdata(in: 0 ..< 16)
            let crcReceived = plaintext.subdata(in: 17 ..< 21)
            let oldKey = keys[Int(keyNo)]
            let newKey = NTAG424Crypto.xor(xored, oldKey)
            let crcExpected = NTAG424Crypto.crc32Jam(newKey)
            guard crcReceived == crcExpected else { return Self.swDESFireError }
            keys[Int(keyNo)] = newKey
        }
        keyVersions[Int(keyNo)] = newKeyVersion

        // ChangeKey has no response MAC per the AN12196 worked example —
        // just SW 9100. Increment CmdCtr so subsequent commands stay in
        // lockstep.
        session.cmdCtr = session.cmdCtr &+ 1
        self.session = session
        return Self.swOK91
    }

    // MARK: - DESFire path: ReadData / WriteData (commMode-aware)

    //
    // Routes on the target file's `commMode`:
    //   - `.plain` — preserved legacy behaviour, returns whole file + 9100.
    //   - `.full` — AN12196 §6.7 / §6.8 wrapped form:
    //       request : CmdHeader(7)            || MACt(8)
    //       response: EncResponseData(N×16)   || MACt(8) || 9100
    //     CmdHeader = FileNo(1) || Offset(3 LE) || Length(3 LE).
    //     Read responses encrypt the data under `IVr`; Write requests
    //     decrypt CmdData under `IVc`. Both MACs use SesAuthMACKey.
    //   - `.mac` — request unencrypted but MAC'd; response same. Not yet
    //     implemented — falls through to plain.

    private func handleReadData(command: Data) -> Data {
        // Plain ReadData: 90 AD 00 00 07 FileNo Offset(3 LE) Length(3 LE) 00.
        guard command.count >= 5 + 7 else { return Self.swDESFireError }
        let fileNo = command[command.startIndex + 5]
        guard let id = fileIDFromNumber(fileNo) else { return Self.swFileNotFoundDESFire }
        let settings = fileSettings[id] ?? FileSettings(
            fileType: 0x00, commMode: .plain, accessRights: 0xEEEE, fileSize: 256
        )
        if settings.commMode == .full {
            return handleReadDataFull(command: command, fileID: id)
        }
        guard readAllowed(id) else { return Self.swAuthRequired }
        let offset = readUInt24LE(command, at: 6)
        let rawLength = readUInt24LE(command, at: 9)
        let source = fileFor(id)
        guard offset <= source.count else { return Self.swDESFireError }
        let length = rawLength == 0 ? source.count - offset : rawLength
        let end = min(source.count, offset + length)
        let data = source.subdata(in: (source.startIndex + offset) ..< (source.startIndex + end))
        advanceSessionCounter()
        return data + Self.swOK91
    }

    private func handleWriteData(command: Data) -> Data {
        // Plain WriteData: 90 8D 00 00 Lc FileNo Offset(3 LE) Length(3 LE) Data 00.
        guard command.count >= 5 + 7 else { return Self.swDESFireError }
        let fileNo = command[command.startIndex + 5]
        guard let id = fileIDFromNumber(fileNo) else { return Self.swFileNotFoundDESFire }
        let settings = fileSettings[id] ?? FileSettings(
            fileType: 0x00, commMode: .plain, accessRights: 0xEEEE, fileSize: 256
        )
        if settings.commMode == .full {
            return handleWriteDataFull(command: command, fileID: id)
        }
        guard writeAllowed(id) else { return Self.swAuthRequired }
        let offset = readUInt24LE(command, at: 6)
        let length = readUInt24LE(command, at: 9)
        guard command.count >= 5 + 7 + length else { return Self.swDESFireError }
        let payload = command.subdata(in: (command.startIndex + 12) ..< (command.startIndex + 12 + length))
        var file = fileFor(id)
        if offset + payload.count > file.count {
            file.append(contentsOf: [UInt8](repeating: 0x00, count: offset + payload.count - file.count))
        }
        file.replaceSubrange((file.startIndex + offset) ..< (file.startIndex + offset + payload.count), with: payload)
        setFile(id, data: file)
        advanceSessionCounter()
        return Self.swOK91
    }

    /// Plain in-session commands still advance the command counter, matching the
    /// real chip (AN12196 §8.2.3) so a later MAC'd command stays in sync.
    private func advanceSessionCounter() {
        if var s = session {
            s.cmdCtr = s.cmdCtr &+ 1
            session = s
        }
    }

    private func handleReadDataFull(command: Data, fileID: FileID) -> Data {
        guard var session else { return Self.swAuthRequired }
        // Wire format: 90 AD 00 00 0F CmdHeader(7) MACt(8) Le=00
        guard command.count >= 5 + 7 + 8 + 1 else { return Self.swDESFireError }
        let cmdHeader = command.subdata(
            in: (command.startIndex + 5) ..< (command.startIndex + 5 + 7)
        )
        let receivedMAC = command.subdata(
            in: (command.startIndex + 5 + 7) ..< (command.startIndex + 5 + 7 + 8)
        )
        let offset = readUInt24LE(cmdHeader, at: 1)
        let length = readUInt24LE(cmdHeader, at: 4)

        // Verify request MAC. ReadData has no CmdData in Full mode.
        let expectedMAC = NTAG424Crypto.commandMAC(
            sesAuthMACKey: session.macKey,
            cmdINS: 0xAD,
            cmdCtr: session.cmdCtr,
            ti: session.ti,
            cmdHeader: cmdHeader,
            encCmdData: Data()
        )
        guard receivedMAC == expectedMAC else { return Self.swDESFireError }

        let source = fileFor(fileID)
        guard offset + length <= source.count else { return Self.swDESFireError }
        let plaintext = source.subdata(
            in: (source.startIndex + offset) ..< (source.startIndex + offset + length)
        )

        // Pad + encrypt with IVr; build response MAC over EncResponseData.
        let padded = NTAG424Crypto.iso9797Pad(plaintext)
        let iv = NTAG424Crypto.responseIV(
            sesAuthENCKey: session.encKey, ti: session.ti, cmdCtr: session.cmdCtr
        )
        let encrypted = NTAG424Crypto.aesCBCEncrypt(
            key: session.encKey, iv: iv, data: padded
        )
        let mac = NTAG424Crypto.responseMAC(
            sesAuthMACKey: session.macKey,
            cmdCtr: session.cmdCtr,
            ti: session.ti,
            encResponseData: encrypted
        )

        session.cmdCtr = session.cmdCtr &+ 1
        self.session = session
        return encrypted + mac + Self.swOK91
    }

    private func handleWriteDataFull(command: Data, fileID: FileID) -> Data {
        guard var session else { return Self.swAuthRequired }
        // Wire format: 90 8D 00 00 Lc CmdHeader(7) EncData(N×16) MACt(8) Le
        guard command.count >= 5 + 7 + 16 + 8 + 1 else { return Self.swDESFireError }
        let lc = Int(command[command.startIndex + 4])
        guard command.count >= 5 + lc + 1 else { return Self.swDESFireError }
        let cmdHeader = command.subdata(
            in: (command.startIndex + 5) ..< (command.startIndex + 5 + 7)
        )
        // Remaining after the 7-byte header = EncData (multiple of 16) + 8-byte MAC.
        let remaining = lc - 7
        guard remaining >= 8 else { return Self.swDESFireError }
        let encDataLen = remaining - 8
        guard encDataLen > 0, encDataLen % 16 == 0 else { return Self.swDESFireError }
        let encData = command.subdata(
            in: (command.startIndex + 12) ..< (command.startIndex + 12 + encDataLen)
        )
        let receivedMAC = command.subdata(
            in: (command.startIndex + 12 + encDataLen) ..< (command.startIndex + 12 + encDataLen + 8)
        )

        let expectedMAC = NTAG424Crypto.commandMAC(
            sesAuthMACKey: session.macKey,
            cmdINS: 0x8D,
            cmdCtr: session.cmdCtr,
            ti: session.ti,
            cmdHeader: cmdHeader,
            encCmdData: encData
        )
        guard receivedMAC == expectedMAC else { return Self.swDESFireError }

        let iv = NTAG424Crypto.commandIV(
            sesAuthENCKey: session.encKey, ti: session.ti, cmdCtr: session.cmdCtr
        )
        let padded = NTAG424Crypto.aesCBCDecrypt(
            key: session.encKey, iv: iv, data: encData
        )
        let offset = readUInt24LE(cmdHeader, at: 1)
        let length = readUInt24LE(cmdHeader, at: 4)
        guard let plaintext = NTAG424Crypto.stripIso9797(padded, plaintextLength: length) else {
            return Self.swDESFireError
        }

        var file = fileFor(fileID)
        if offset + plaintext.count > file.count {
            file.append(contentsOf: [UInt8](repeating: 0x00, count: offset + plaintext.count - file.count))
        }
        file.replaceSubrange(
            (file.startIndex + offset) ..< (file.startIndex + offset + plaintext.count),
            with: plaintext
        )
        setFile(fileID, data: file)

        // WriteData response: just SW + MAC over empty data, per AN12196 Table 18.
        let mac = NTAG424Crypto.responseMAC(
            sesAuthMACKey: session.macKey,
            cmdCtr: session.cmdCtr,
            ti: session.ti,
            encResponseData: Data()
        )
        session.cmdCtr = session.cmdCtr &+ 1
        self.session = session
        return mac + Self.swOK91
    }

    /// Read a 3-byte little-endian integer from `data[start..<start+3]`.
    private func readUInt24LE(_ data: Data, at offset: Int) -> Int {
        Int(data[data.startIndex + offset])
            | (Int(data[data.startIndex + offset + 1]) << 8)
            | (Int(data[data.startIndex + offset + 2]) << 16)
    }

    private func fileFor(_ id: FileID) -> Data {
        switch id {
        case .cc: ccFile
        case .ndef: ndefFile
        case .proprietary: proprietaryFile
        }
    }

    private func setFile(_ id: FileID, data: Data) {
        switch id {
        case .cc: ccFile = data
        case .ndef: ndefFile = data
        case .proprietary: proprietaryFile = data
        }
    }

    private func fileIDFromNumber(_ fileNo: UInt8) -> FileID? {
        // DESFire file numbers map 0x01 → CC, 0x02 → NDEF, 0x03 → Proprietary.
        switch fileNo {
        case 0x01: .cc
        case 0x02: .ndef
        case 0x03: .proprietary
        default: nil
        }
    }

    // MARK: - Higher-level convenience (ChipSimulator extras)

    public func readMemory(range: Range<Int>) throws -> Data {
        let source = ndefFile
        guard range.lowerBound >= 0, range.upperBound <= source.count else {
            throw TagError.protocolError("read range \(range) outside NDEF file")
        }
        return source.subdata(in: (source.startIndex + range.lowerBound) ..< (source.startIndex + range.upperBound))
    }

    public func writeMemory(at offset: Int, bytes: Data) throws {
        if offset + bytes.count > ndefFile.count {
            ndefFile.append(contentsOf: [UInt8](repeating: 0x00, count: offset + bytes.count - ndefFile.count))
        }
        ndefFile.replaceSubrange(
            (ndefFile.startIndex + offset) ..< (ndefFile.startIndex + offset + bytes.count),
            with: bytes
        )
    }

    public func readNDEF() throws -> Data {
        guard ndefFile.count >= 2 else { return Data() }
        let length = (Int(ndefFile[ndefFile.startIndex]) << 8) | Int(ndefFile[ndefFile.startIndex + 1])
        guard ndefFile.count >= 2 + length else { throw TagError.malformedResponse(ndefFile) }
        return ndefFile.subdata(in: (ndefFile.startIndex + 2) ..< (ndefFile.startIndex + 2 + length))
    }

    public func writeNDEF(_ message: Data) throws {
        let body: Data = if message.first == 0x03 {
            (try? NDEFEnvelope.unwrap(message)) ?? message
        } else {
            message
        }
        ndefFile = Self.wrapWithLength(body)
    }

    public func authenticate(password: Data) throws -> Data {
        throw TagError.capabilityUnsupported(
            .passwordAuth,
            diagnostics: "NTAG424 DNA uses AES authentication, not PWD/PACK — drive via the 0x71 APDU instead"
        )
    }

    public func setPassword(_ password: Data, pack: Data) throws {
        throw TagError.capabilityUnsupported(
            .passwordAuth,
            diagnostics: "NTAG424 DNA uses AES authentication, not PWD/PACK"
        )
    }

    public func permanentLock() throws {
        throw TagError.capabilityUnsupported(
            .permanentLock,
            diagnostics: "NTAG424 DNA does not expose Type-2-style permanent lock"
        )
    }

    /// Live protection state, read straight from the NDEF file's access rights —
    /// the chip-side counterpart to the production driver's `GetFileSettings`
    /// probe. Both map nibbles to settings via the same interpretation.
    public func readProtectionState() throws -> TagProtection? {
        guard let ar = fileSettings[.ndef]?.accessRights else { return TagProtection.none }
        return NTAG424ProtectionDriver.interpret(accessRights: ar)
    }

    /// A new RF activation: the EV2 session died with the field, so the chip is
    /// unauthenticated again whatever the previous tap did.
    ///
    /// The Type-4 sibling of `Iso15693Simulator.beginActivation`, and it was
    /// missing. Every multi-tap 424 test had to remember `endSession()` by hand,
    /// so a flow that authenticated on one tap and relied on it still holding on
    /// the next passed here and would have failed on silicon. Not the contested
    /// "does SELECT end the session" question in `handleSelect`: that one is
    /// intra-activation and stays open.
    public func beginActivation() {
        endSession()
    }

    /// Test-only: drop the live secure-messaging session, modelling a fresh tap.
    /// Each physical NFC tap re-authenticates; the simulator otherwise keeps one
    /// continuous session, so tests use this to assert unauthenticated behaviour
    /// after an authenticated operation (e.g. enable → re-tap → write refused).
    /// Idempotent, so an explicit call beside `beginActivation()` is harmless.
    public func endSession() {
        session = nil
        pendingAuth = nil
    }

    // MARK: - Test-only session injection

    //
    // AN12196 publishes worked examples with fixed session keys / TI /
    // CmdCtr. These helpers let a test stand up that exact state without
    // re-running the auth dance, so the vectors can be diffed byte-for-byte.

    public func injectTestSession(
        keyNumber: UInt8 = 0,
        encKey: Data,
        macKey: Data,
        ti: Data,
        cmdCtr: UInt16 = 0
    ) {
        session = SessionState(
            keyNumber: keyNumber,
            encKey: encKey,
            macKey: macKey,
            ti: ti,
            cmdCtr: cmdCtr,
            randA: Data(repeating: 0x00, count: 16),
            randB: Data(repeating: 0x00, count: 16)
        )
    }

    /// Mutate the live session's CmdCtr without rebuilding it. Useful for
    /// tests that advance the counter past the auth-reset zero.
    public func seedCmdCtr(_ value: UInt16) {
        guard var s = session else { return }
        s.cmdCtr = value
        session = s
    }

    /// Build a SUN URL from the live session. Throws if not authenticated.
    public func generateSUNURL(
        readCounter: UInt32,
        template: NTAG424SUNMessage.Template = .hexpro
    ) throws -> String {
        guard let session else {
            throw TagError.capabilityUnsupported(.sunMessages, diagnostics: "authenticate first")
        }
        return NTAG424SUNMessage.makeURL(
            uid: uid,
            readCounter: readCounter,
            encKey: session.encKey,
            macKey: session.macKey,
            template: template
        )
    }

    // MARK: - Helpers

    private static func wrapWithLength(_ message: Data) -> Data {
        var data = Data()
        data.append(UInt8((message.count >> 8) & 0xFF))
        data.append(UInt8(message.count & 0xFF))
        data.append(message)
        return data
    }

    /// Deterministic 16-byte sequence so tests that don't override the
    /// nonce provider still see reproducible RndB values.
    private static func defaultNonceProvider() -> () -> Data {
        var counter: UInt8 = 0
        return {
            counter = counter &+ 1
            return Data((0 ..< 16).map { i in UInt8(i) &+ counter })
        }
    }

    // MARK: - Constants

    public static let defaultUID: Data = .init([0x04, 0x42, 0x42, 0xDD, 0x44, 0xEE, 0x77])
    public static let ndefAppAID: Data = .init([0xD2, 0x76, 0x00, 0x00, 0x85, 0x01, 0x01])
    public static let defaultKeys: [Data] = Array(repeating: Data(repeating: 0x00, count: 16), count: 5)

    // ISO 7816 status words.
    static let swOK: Data = .init([0x90, 0x00])
    static let swFileNotFound: Data = .init([0x6A, 0x82])
    static let swSecurity: Data = .init([0x69, 0x82]) // security status not satisfied
    static let swError: Data = .init([0x6F, 0x00])

    // DESFire status words (real chips use 91xx after the body).
    static let swOK91: Data = .init([0x91, 0x00])
    static let swAdditionalFrame: Data = .init([0x91, 0xAF])
    static let swAuthRequired: Data = .init([0x91, 0xAE])
    static let swPermissionDenied: Data = .init([0x91, 0x9D])
    static let swFileNotFoundDESFire: Data = .init([0x91, 0xF0])
    static let swDESFireError: Data = .init([0x91, 0x1C])
    /// `91 7E` LENGTH_ERROR. What a live EV2 session answers a plain command
    /// that should have carried a MAC (measured 2026-09-20, T4-2).
    static let swLengthError: Data = .init([0x91, 0x7E])
}
