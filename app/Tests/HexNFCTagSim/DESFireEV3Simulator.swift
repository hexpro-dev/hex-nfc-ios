import Foundation
@testable import HexNFCKit
@testable import HexNFCRecords

/// NXP MIFARE DESFire EV3 4K at frame level: an application directory, data
/// files, the PICC master key, and the commands this app sends a DESFire, in
/// both the native form (identification) and the ISO-wrapped form (NDEF setup
/// and removal), plus the ISO 7816 SELECT / READ BINARY / UPDATE BINARY that
/// iOS's own NDEF reader uses.
///
/// Modelled by default as a **factory card**: no applications, PICC key
/// settings `0F 01`, master key version 00, 5120 bytes free, all three
/// live-captured on the owner's blank EV3 4K on 2026-10-30
/// (`bench-traces/2026-10-30-df-0-desfire-ev3-readonly.log`). `personalised()`
/// is the transit card from the same capture.
///
/// **The high-level NDEF view is derived from the files.** `ndefAccess`,
/// `readNDEF` and `writeNDEF` read and write the same Capability Container and
/// NDEF file the ISO commands serve, the way the NTAG424 simulator shares its
/// NDEF file. A card set up through frames is therefore exactly the card iOS's
/// reader sees here, and the simulator cannot report an NDEF card its own frames
/// would not show.
///
/// **What is modelled rather than measured**, each to be replaced by a capture:
/// memory cost (the declared file size rounded up to 32 bytes, applications
/// free), new files reading as zeros, and FormatPICC's answer (eight bytes
/// before the status, the CMAC the EV3 short datasheet §7.7 says follows an
/// authenticated command; its contents are not computed).
///
/// **No refusal is invented for the new commands.** No DESFire refusal code has
/// ever been captured. A frame that breaks a precondition here is recorded in
/// `violations` and answered with one generic status, `genericRefusal`; tests
/// assert the log stays empty, and a test that needs a real refusal injects one
/// through `TagFaultInjection` with the byte it is about. The `9D`, `A0` and
/// `1C` answers inherited from the identification-only model stay as they were;
/// nothing new depends on them.
///
/// It also closes a real gap in the *NTAG424* coverage: `GET_VERSION` is a
/// 3-frame chained command on genuine silicon, and an undrained chain makes the
/// next command answer `91 CA` (COMMAND_ABORTED). This simulator chains for real.
public final class DESFireEV3Simulator: ChipSimulator, @unchecked Sendable {
    public let uid: Data
    public let profile: ChipProfile?

    // MARK: - Card model

    public struct DataFile: Equatable, Sendable {
        public var isoFileID: Data?
        public var communicationSettings: UInt8 = 0x00
        /// Two bytes, least significant first, as the card sends them.
        public var accessRights: Data
        public var bytes: Data

        public init(isoFileID: Data? = nil, communicationSettings: UInt8 = 0x00, accessRights: Data, bytes: Data) {
            self.isoFileID = isoFileID
            self.communicationSettings = communicationSettings
            self.accessRights = accessRights
            self.bytes = bytes
        }

        /// The nibble for one access (Read 12-15, Write 8-11, ReadWrite 4-7).
        func isFree(_ shift: Int) -> Bool {
            let value = Int(accessRights[accessRights.startIndex]) | Int(accessRights[accessRights.startIndex + 1]) << 8
            return (value >> shift) & 0xF == 0xE
        }

        var readIsFree: Bool {
            isFree(12) || isFree(4)
        }

        var writeIsFree: Bool {
            isFree(8) || isFree(4)
        }
    }

    public struct Application: Equatable, Sendable {
        public var aid: Data
        public var keySettings1: UInt8
        public var keySettings2: UInt8
        public var isoFileID: Data?
        public var dfName: Data?
        public var files: [UInt8: DataFile] = [:]

        public init(
            aid: Data,
            keySettings1: UInt8,
            keySettings2: UInt8,
            isoFileID: Data? = nil,
            dfName: Data? = nil,
            files: [UInt8: DataFile] = [:]
        ) {
            self.aid = aid
            self.keySettings1 = keySettings1
            self.keySettings2 = keySettings2
            self.isoFileID = isoFileID
            self.dfName = dfName
            self.files = files
        }
    }

    public var applications: [Application]
    /// PICC GetKeySettings answer: key settings, then key count and type.
    public var piccKeySettings = Data([0x0F, 0x01])
    public var piccKeyVersion: UInt8 = 0x00
    /// The PICC master key, 2K3DES form. The factory DES key is all zero.
    public var piccKey = Data(repeating: 0, count: 16)
    /// Reported free memory. Defaults to the blank-card capture.
    ///
    /// Live-verified 2026-08-05 across three DESFire EV3 4K cards, and again
    /// 2026-10-30 with wrapped commands:
    ///
    /// | card | applications | free |
    /// |---|---|---|
    /// | blank ×2 | 0 | 5120 B |
    /// | transit | 2 | 3200 B |
    ///
    /// The blank figure is deliberately *larger* than the 4096 B the GET_VERSION
    /// storage byte decodes to: that byte is the advertised product tier, not a
    /// bound on the pool.
    public var freeMemoryBytes: Int = 5120
    /// What FormatPICC restores free memory to.
    public var totalMemoryBytes: Int = 5120

    public var applicationIDs: [Data] {
        applications.map(\.aid)
    }

    /// Frames that broke a precondition this model enforces. See the type's
    /// comment: these are answered with `genericRefusal`, which no capture has
    /// shown, so a test that ends with entries here has exercised a path real
    /// silicon may answer differently.
    public private(set) var violations: [String] = []
    public static let genericRefusal: UInt8 = 0x9D

    // MARK: - Activation state

    private enum Selection: Equatable {
        case picc
        case application(Int)
    }

    private var selection = Selection.picc
    private var isoSelectedFile: UInt8?
    private var authenticated = false
    private var pendingAuthentication: (rndB: Data, ekRndB: Data)?

    /// How many `GET_VERSION` frames have been handed out. `0` = no chain open.
    public private(set) var versionFramesServed = 0
    public private(set) var authenticationAttempts = 0

    /// Real Myki card capture, the same vector `DESFireIdentificationTests` pins:
    /// vendor NXP (`04`), hw type DESFire (`01`), hw major `33` = EV3,
    /// storage `18` → 4096 B.
    public static let versionFrame1 = Data([0x04, 0x01, 0x01, 0x33, 0x00, 0x18, 0x05])
    /// Software info: same shape, software major/minor in place of hardware's.
    public static let versionFrame2 = Data([0x04, 0x01, 0x01, 0x33, 0x00, 0x18, 0x05])

    /// NXP manufacturer byte (`0x04`) + an arbitrary but stable serial.
    public static let defaultUID = Data([0x04, 0xDE, 0x5F, 0x13, 0xE3, 0x00, 0x01])

    public init(uid: Data = DESFireEV3Simulator.defaultUID, applicationIDs: [Data] = []) {
        precondition(uid.count == 7, "DESFire UID is 7 bytes")
        self.uid = uid
        // Opaque applications: listed, selectable, and nothing else is modelled.
        applications = applicationIDs.map {
            Application(aid: $0, keySettings1: 0x0B, keySettings2: 0x00)
        }
        // Build the profile through the production decoder, from the very frame
        // this simulator serves.
        profile = ChipCatalog.identify(desFireVersion: Data([0xAF]) + Self.versionFrame1)
    }

    /// The transit card captured 2026-10-30: two applications, 3200 B free, PICC
    /// key settings `0B 01` (creating an application needs the master key) and
    /// master key version 01.
    public static func personalised(uid: Data = DESFireEV3Simulator.defaultUID) -> DESFireEV3Simulator {
        let simulator = DESFireEV3Simulator(
            uid: uid,
            applicationIDs: [Data([0x00, 0x11, 0xF2]), Data([0xF0, 0x10, 0xF2])]
        )
        simulator.freeMemoryBytes = 3200
        simulator.piccKeySettings = Data([0x0B, 0x01])
        simulator.piccKeyVersion = 0x01
        return simulator
    }

    /// A card already set up the way `DESFireNDEFDriver` sets one up, holding
    /// `message`. A read-only card carries `FF` as its CC write-access byte.
    public static func ndefFormatted(
        message: Data = Data(),
        isWritable: Bool = true,
        ndefFileSize: Int = 0x1000,
        uid: Data = DESFireEV3Simulator.defaultUID
    ) -> DESFireEV3Simulator {
        let simulator = DESFireEV3Simulator(uid: uid)
        var cc = DESFireNDEFDriver.capabilityContainer(ndefFileSize: ndefFileSize)
        if !isWritable {
            cc[cc.startIndex + 14] = 0xFF
        }
        var ndef = Data(repeating: 0, count: ndefFileSize)
        ndef.replaceSubrange(
            0 ..< 2 + message.count,
            with: Data([UInt8(message.count >> 8), UInt8(message.count & 0xFF)]) + message
        )
        simulator.applications = [Application(
            aid: DESFireNDEFDriver.applicationID,
            keySettings1: DESFireNDEFDriver.keySettings1,
            keySettings2: DESFireNDEFDriver.keySettings2,
            isoFileID: Data([0x10, 0xE1]),
            dfName: DESFireNDEFDriver.ndefDFName,
            files: [
                0x01: DataFile(isoFileID: Data([0x03, 0xE1]), accessRights: Data([0xE0, 0xEE]), bytes: cc),
                0x02: DataFile(isoFileID: Data([0x04, 0xE1]), accessRights: Data([0xE0, 0xEE]), bytes: ndef),
            ]
        )]
        simulator.freeMemoryBytes -= Self.applicationCost + Self.allocation(DESFireNDEFDriver.ccLength)
            + Self.allocation(ndefFileSize)
        return simulator
    }

    /// A real tag is re-selected at every tap: PICC level, unauthenticated, no
    /// chain open.
    public func beginActivation() {
        selection = .picc
        isoSelectedFile = nil
        authenticated = false
        pendingAuthentication = nil
        versionFramesServed = 0
    }

    // MARK: - Command dispatch

    public func handle(command: Data) -> Data {
        guard let first = command.first else { return Data([0x1C]) }
        let bytes = [UInt8](command)
        if first == 0x00, bytes.count >= 4 {
            return handleISO(bytes)
        }
        if first == 0x90, bytes.count >= 5 {
            // `90 INS 00 00 [Lc data] Le`: the same command, status trailing.
            let data = bytes.count > 5 ? Data(bytes[5 ..< min(bytes.count, 5 + Int(bytes[4]))]) : Data()
            let (status, body) = execute(bytes[1], data)
            return body + Data([0x91, status])
        }
        let (status, body) = execute(first, Data(bytes.dropFirst()))
        return Data([status]) + body
    }

    /// One native command, as `(status, body)`.
    private func execute(_ instruction: UInt8, _ data: Data) -> (UInt8, Data) {
        if instruction != 0xAF {
            versionFramesServed = 0
            if instruction != 0x1A {
                pendingAuthentication = nil
            }
        }
        switch instruction {
        case 0x60:
            versionFramesServed = 1
            return (0xAF, Self.versionFrame1)

        case 0xAF:
            return continueChain(data)

        case 0x6A:
            guard selection == .picc else { return violation("GetApplicationIDs outside the PICC level") }
            return (0x00, applications.reduce(into: Data()) { $0.append($1.aid) })

        case 0x6E:
            return (0x00, DESFireNDEFDriver.littleEndian3(max(0, freeMemoryBytes)))

        case 0x5A:
            return selectApplication(data)

        case 0x45:
            switch selection {
            case .picc:
                return (0x00, piccKeySettings)

            case .application(let index):
                // Silicon leaves out bit 5, "ISO file IDs": an application
                // created with 21h answers `0F 01` (EV3, bench 2026-10-30).
                let reported = applications[index].keySettings2 & ~0x20
                return (0x00, Data([applications[index].keySettings1, reported]))
            }

        case 0x64:
            guard data.first == 0x00 else { return violation("GetKeyVersion for a key other than 0") }
            return (0x00, Data([selection == .picc ? piccKeyVersion : 0x00]))

        case 0xCA:
            return createApplication(data)

        case 0xCD:
            return createStandardDataFile(data)

        case 0x6F, 0xF5, 0xBD, 0x3D:
            return fileCommand(instruction, data)

        case 0xC4:
            return (0x9D, Data())

        case 0x1A:
            return beginAuthentication(data)

        case 0xFC:
            return formatPICC()

        default:
            return (0x1C, Data())
        }
    }

    private func continueChain(_ data: Data) -> (UInt8, Data) {
        if pendingAuthentication != nil {
            return completeAuthentication(data)
        }
        switch versionFramesServed {
        case 1:
            versionFramesServed = 2
            return (0xAF, Self.versionFrame2)

        case 2:
            versionFramesServed = 0
            // UID(7) ‖ batch number(5) ‖ production week(1) ‖ year(1).
            return (0x00, uid + Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x24, 0x23]))

        default:
            // No chain open: real silicon answers ILLEGAL_COMMAND_CODE.
            return (0x1C, Data())
        }
    }

    private func selectApplication(_ data: Data) -> (UInt8, Data) {
        guard data.count >= 3 else { return (0x1C, Data()) }
        let aid = Data(data.prefix(3))
        // Selecting ends any authenticated session.
        authenticated = false
        isoSelectedFile = nil
        if aid == Data([0x00, 0x00, 0x00]) {
            selection = .picc
            return (0x00, Data())
        }
        guard let index = applications.firstIndex(where: { $0.aid == aid }) else {
            return (0xA0, Data()) // APPLICATION_NOT_FOUND
        }
        selection = .application(index)
        return (0x00, Data())
    }

    private func createApplication(_ data: Data) -> (UInt8, Data) {
        guard selection == .picc else { return violation("CreateApplication outside the PICC level") }
        guard piccKeySettings.first.map({ $0 & 0x04 != 0 }) == true || authenticated else {
            return violation("CreateApplication without the master key on a card that requires it")
        }
        let bytes = [UInt8](data)
        guard bytes.count >= 5 else { return violation("CreateApplication too short") }
        let aid = Data(bytes[0 ..< 3])
        guard !applications.contains(where: { $0.aid == aid }) else {
            return violation("CreateApplication of an AID that exists")
        }
        var app = Application(aid: aid, keySettings1: bytes[3], keySettings2: bytes[4])
        if bytes[4] & 0x20 != 0 {
            guard bytes.count >= 7 else { return violation("CreateApplication without its ISO file ID") }
            app.isoFileID = Data(bytes[5 ..< 7])
            app.dfName = bytes.count > 7 ? Data(bytes[7...]) : nil
        }
        guard Self.applicationCost <= freeMemoryBytes else {
            return violation("CreateApplication without the memory for it")
        }
        freeMemoryBytes -= Self.applicationCost
        applications.append(app)
        return (0x00, Data())
    }

    private func createStandardDataFile(_ data: Data) -> (UInt8, Data) {
        guard case .application(let index) = selection else {
            return violation("CreateStdDataFile at the PICC level")
        }
        guard applications[index].keySettings1 & 0x04 != 0 || authenticated else {
            return violation("CreateStdDataFile without a key on an application that requires one")
        }
        let hasISO = applications[index].keySettings2 & 0x20 != 0
        let bytes = [UInt8](data)
        guard bytes.count == (hasISO ? 9 : 7) else { return violation("CreateStdDataFile length") }
        let fileNumber = bytes[0]
        guard applications[index].files[fileNumber] == nil else {
            return violation("CreateStdDataFile of a file that exists")
        }
        let rest = hasISO ? Array(bytes[3...]) : Array(bytes[1...])
        let size = DESFireNDEFDriver.littleEndianValue(rest[3 ... 5])
        guard Self.allocation(size) <= freeMemoryBytes else {
            return violation("CreateStdDataFile larger than free memory")
        }
        freeMemoryBytes -= Self.allocation(size)
        applications[index].files[fileNumber] = DataFile(
            isoFileID: hasISO ? Data(bytes[1 ... 2]) : nil,
            communicationSettings: rest[0],
            accessRights: Data(rest[1 ... 2]),
            // Modelled, not captured: a new file reads as zeros.
            bytes: Data(repeating: 0, count: size)
        )
        return (0x00, Data())
    }

    /// GetFileIDs, GetFileSettings, ReadData and WriteData. At the PICC level
    /// the first three keep the `9D` the identification-only model gave them.
    private func fileCommand(_ instruction: UInt8, _ data: Data) -> (UInt8, Data) {
        guard case .application(let index) = selection else {
            return instruction == 0x3D ? violation("WriteData at the PICC level") : (0x9D, Data())
        }
        let app = applications[index]
        switch instruction {
        case 0x6F:
            guard app.keySettings1 & 0x02 != 0 || authenticated else { return violation("GetFileIDs needs a key") }
            return (0x00, Data(app.files.keys.sorted()))

        case 0xF5:
            guard let number = data.first, let file = app.files[number] else {
                return violation("GetFileSettings of a missing file")
            }
            return (0x00, Data([0x00, file.communicationSettings]) + file.accessRights
                + DESFireNDEFDriver.littleEndian3(file.bytes.count))

        default:
            let bytes = [UInt8](data)
            guard bytes.count >= 7, let file = app.files[bytes[0]] else {
                return violation("file data command on a missing file")
            }
            let offset = DESFireNDEFDriver.littleEndianValue(bytes[1 ... 3])
            let length = DESFireNDEFDriver.littleEndianValue(bytes[4 ... 6])
            if instruction == 0xBD {
                guard file.readIsFree else { return violation("ReadData without read access") }
                let end = length == 0 ? file.bytes.count : offset + length
                guard end <= file.bytes.count else { return violation("ReadData past the end") }
                return (0x00, Data(file.bytes[offset ..< end]))
            }
            let payload = Data(bytes.dropFirst(7))
            guard file.writeIsFree else { return violation("WriteData without write access") }
            guard payload.count == length, offset + length <= file.bytes.count else {
                return violation("WriteData length or bounds")
            }
            applications[index].files[bytes[0]]?.bytes.replaceSubrange(offset ..< offset + length, with: payload)
            return (0x00, Data())
        }
    }

    // MARK: - Authentication (card side; deliberately not `ISO3DESHandshake`)

    private func beginAuthentication(_ data: Data) -> (UInt8, Data) {
        guard selection == .picc, data.first == 0x00 else {
            return violation("AuthenticateISO for anything but PICC key 0")
        }
        authenticationAttempts += 1
        authenticated = false
        let rndB = Data([0x5C, 0x13, 0x8E, 0x21, 0x9A, 0x47, 0xD0, 0x6B])
        guard let ekRndB = try? EMRTDCrypto.tripleDESCBCEncrypt(
            key: piccKey, iv: Data(repeating: 0, count: 8), data: rndB
        ) else { return violation("3DES failed") }
        pendingAuthentication = (rndB, ekRndB)
        return (0xAF, ekRndB)
    }

    private func completeAuthentication(_ token: Data) -> (UInt8, Data) {
        guard let pending = pendingAuthentication else { return (0x1C, Data()) }
        pendingAuthentication = nil
        guard token.count == 16,
              let plain = try? EMRTDCrypto.tripleDESCBCDecrypt(key: piccKey, iv: pending.ekRndB, data: token),
              Data(plain.suffix(8)) == NTAG424Crypto.rotateLeftByOne(pending.rndB),
              let ekRndAPrime = try? EMRTDCrypto.tripleDESCBCEncrypt(
                  key: piccKey, iv: Data(token.suffix(8)),
                  data: NTAG424Crypto.rotateLeftByOne(Data(plain.prefix(8)))
              )
        else {
            return violation("AuthenticateISO token did not decrypt to RndB′ under the PICC key")
        }
        authenticated = true
        return (0x00, ekRndAPrime)
    }

    private func formatPICC() -> (UInt8, Data) {
        guard selection == .picc, authenticated else {
            return violation("FormatPICC without PICC master key authentication")
        }
        applications = []
        freeMemoryBytes = totalMemoryBytes
        // Eight bytes standing in for the CMAC (not computed).
        return (0x00, Data(repeating: 0xC3, count: 8))
    }

    // MARK: - ISO 7816

    private func handleISO(_ bytes: [UInt8]) -> Data {
        switch bytes[1] {
        case 0xA4:
            guard bytes.count >= 5 else { return Data([0x6A, 0x82]) }
            let body = Data(bytes[5 ..< min(bytes.count, 5 + Int(bytes[4]))])
            if bytes[2] == 0x04 {
                // Captured on a factory EV3 (2026-08-05): the NDEF AID is not found.
                guard let index = applications.firstIndex(where: { $0.dfName == body }) else {
                    return Data([0x6A, 0x82])
                }
                selection = .application(index)
                isoSelectedFile = nil
                authenticated = false
                return Data([0x90, 0x00])
            }
            guard case .application(let index) = selection,
                  let entry = applications[index].files.first(where: { $0.value.isoFileID == Data(body.reversed()) })
            else {
                return Data([0x6A, 0x82])
            }
            isoSelectedFile = entry.key
            return Data([0x90, 0x00])

        case 0xB0, 0xD6:
            guard case .application(let index) = selection, let number = isoSelectedFile,
                  let file = applications[index].files[number], bytes.count >= 5
            else {
                return isoViolation("READ/UPDATE BINARY with no file selected")
            }
            let offset = Int(bytes[2]) << 8 | Int(bytes[3])
            if bytes[1] == 0xB0 {
                guard file.readIsFree else { return isoViolation("READ BINARY without read access") }
                let length = bytes[4] == 0 ? 256 : Int(bytes[4])
                let end = min(file.bytes.count, offset + length)
                guard offset <= end else { return isoViolation("READ BINARY past the end") }
                return Data(file.bytes[offset ..< end]) + Data([0x90, 0x00])
            }
            let payload = Data(bytes[5 ..< min(bytes.count, 5 + Int(bytes[4]))])
            guard file.writeIsFree, offset + payload.count <= file.bytes.count else {
                return isoViolation("UPDATE BINARY without write access or past the end")
            }
            applications[index].files[number]?.bytes.replaceSubrange(offset ..< offset + payload.count, with: payload)
            return Data([0x90, 0x00])

        default:
            return isoViolation(String(format: "ISO instruction %02X", bytes[1]))
        }
    }

    private func violation(_ what: String) -> (UInt8, Data) {
        violations.append(what)
        return (Self.genericRefusal, Data())
    }

    private func isoViolation(_ what: String) -> Data {
        violations.append(what)
        return Data([0x69, 0x82])
    }

    /// What a standard data file takes from free memory: its declared size
    /// rounded up to 32 bytes. Measured on an EV3 4K (bench 2026-10-30): the
    /// 4096-byte NDEF file took exactly 4096 B, and the 15-byte CC file and the
    /// application together took 192 B. See `applicationCost` for the split.
    static func allocation(_ size: Int) -> Int {
        (size + 31) / 32 * 32
    }

    /// What CreateApplication takes from free memory. The bench measured the
    /// application and the 15-byte CC file together at 192 B (5120 B free
    /// before, 4928 B after); with the file in one 32-byte block that leaves
    /// 160 B for the application. The sum is measured, the split is inferred.
    public static let applicationCost = 160

    // MARK: - The NDEF application, as iOS's reader sees it

    /// The NDEF Tag Application's CC and NDEF file, found the way a reader finds
    /// them: by DF name, then the CC's file control TLV. `nil` when there is no
    /// valid CC, which is what makes an unfinished setup invisible to a reader.
    private var ndefFiles: (app: Int, fileNumber: UInt8, writeAccess: UInt8)? {
        guard let index = applications.firstIndex(where: { $0.dfName == DESFireNDEFDriver.ndefDFName }),
              let cc = applications[index].files.values.first(where: { $0.isoFileID == Data([0x03, 0xE1]) })?.bytes,
              cc.count >= 15, cc[0] == 0x00, cc[1] == 0x0F, cc[7] == 0x04, cc[8] == 0x06
        else { return nil }
        let fileID = Data([cc[10], cc[9]])
        guard let entry = applications[index].files.first(where: { $0.value.isoFileID == fileID }) else {
            return nil
        }
        return (index, entry.key, cc[14])
    }

    public var ndefAccess: NDEFAccess {
        guard let files = ndefFiles else { return .notSupported }
        switch files.writeAccess {
        case 0x00: return .readWrite
        case 0xFF: return .readOnly
        default: return .notSupported
        }
    }

    /// The message and writability, for tests that look at the card directly.
    public struct NDEFApplication: Equatable {
        public var message: Data
        public var isWritable: Bool
    }

    public var ndefApplication: NDEFApplication? {
        guard ndefFiles != nil else { return nil }
        return try? NDEFApplication(message: readNDEF(), isWritable: ndefAccess == .readWrite)
    }

    // MARK: - Higher-level surface

    private func unsupported(_ capability: TagCapability) -> TagError {
        TagError.capabilityUnsupported(
            capability,
            diagnostics: "DESFire stores data in key-protected applications; this card has no NDEF application"
        )
    }

    public func readMemory(range: Range<Int>) throws -> Data {
        throw unsupported(.memoryRead)
    }

    public func writeMemory(at offset: Int, bytes: Data) throws {
        throw unsupported(.memoryWrite)
    }

    /// Mirrors production: with no NDEF application, CoreNFC's `queryNDEFStatus`
    /// reports `.notSupported`, which `CoreNFCConnectedTag.readNDEF` surfaces as
    /// `capabilityUnsupported(.ndefRead)`, not a transport failure.
    public func readNDEF() throws -> Data {
        guard let files = ndefFiles,
              let bytes = applications[files.app].files[files.fileNumber]?.bytes, bytes.count >= 2
        else { throw unsupported(.ndefRead) }
        let length = Int(bytes[0]) << 8 | Int(bytes[1])
        guard 2 + length <= bytes.count else { throw TagError.malformedResponse(bytes.prefix(2)) }
        return Data(bytes[2 ..< 2 + length])
    }

    /// Takes the TLV envelope `SimulatedConnectedTag` wraps every write in, and
    /// stores the bare message behind its length, as the NTAG424 simulator does.
    public func writeNDEF(_ message: Data) throws {
        guard let files = ndefFiles, ndefAccess == .readWrite,
              let size = applications[files.app].files[files.fileNumber]?.bytes.count
        else { throw unsupported(.ndefWrite) }
        let body = message.first == 0x03 ? (try? NDEFEnvelope.unwrap(message)) ?? message : message
        guard 2 + body.count <= size else {
            throw TagError.writeOverflow(needed: 2 + body.count, available: size)
        }
        let stored = Data([UInt8(body.count >> 8), UInt8(body.count & 0xFF)]) + body
        applications[files.app].files[files.fileNumber]?.bytes.replaceSubrange(0 ..< stored.count, with: stored)
    }

    public func authenticate(password: Data) throws -> Data {
        throw unsupported(.passwordAuth)
    }

    public func setPassword(_ password: Data, pack: Data) throws {
        throw unsupported(.passwordAuth)
    }

    public func permanentLock() throws {
        throw unsupported(.permanentLock)
    }
}
