import Foundation

/// What a DESFire card holds, read without changing anything: the one reading
/// Format, Remove NDEF setup and the scan all decide from.
///
/// "Ours" is a claim about the card's **structure**, proven from what it
/// reports rather than assumed from an application ID: the only application is
/// 000001, its key settings are the ones this app creates, and its files are a
/// subset of the two this app creates, each with this app's settings. A card set
/// up by another tool fails that proof even when it is also an NDEF card, and is
/// left alone.
public enum DESFireNDEFState: Equatable, Sendable {
    /// No applications, and the card lets one be created without its master key.
    case blank
    /// No applications, but creating one needs the master key (PICC key
    /// settings bit 2 clear). Nothing this app can do without that key.
    case applicationsNeedKey
    case ours(OwnSetup)
    /// Application 000001 is the only one, but it is not this app's structure.
    case otherNDEFSetup
    /// Some other application is on the card: a transit, access or payment card.
    case otherApplications
    /// The card did not answer the way a DESFire does. Carries what it said.
    case cannotEstablish(String)

    public enum OwnSetup: Equatable, Sendable {
        /// Setup began and has not reached its last step. The Capability
        /// Container is missing or still all zero, so no reader sees an NDEF tag
        /// yet, and finishing it rewrites nothing anyone could have used.
        case inProgress(hasCCFile: Bool, ndefFileSize: Int?)
        /// Set up and armed: the CC is exactly what this app writes for the NDEF
        /// file the card has.
        case complete(ndefFileSize: Int)
        /// This app's structure, holding a CC that is neither blank nor this
        /// app's. Format leaves it alone; Remove may still clear it.
        case unrecognisedContent
    }

    /// A card Format can set up, or finish setting up.
    public var formatCanProceed: Bool {
        switch self {
        case .blank, .ours(.inProgress): true
        default: false
        }
    }
}

public enum DESFireNDEFStep: String, Equatable, Sendable {
    case createApplication = "CreateApplication"
    case selectApplication = "SelectApplication"
    case createCCFile = "CreateStdDataFile (CC)"
    case measureFreeMemory = "GetFreeMemory"
    case createNDEFFile = "CreateStdDataFile (NDEF)"
    case writeNLEN = "WriteData (NLEN)"
    case writeCC = "WriteData (CC)"
    case readBack = "read-back"
    case formatPICC = "FormatPICC"
}

public enum DESFireSetupOutcome: Equatable, Sendable {
    case created(ndefFileSize: Int)
    /// Already set up exactly as this app sets a card up. Nothing was sent that
    /// changes anything (NXP AN11004 §6.5: a formatted card is not formatted
    /// again).
    case alreadySetUp(ndefFileSize: Int)
}

public enum DESFireRemoveOutcome: Equatable, Sendable {
    /// Free memory as the card reported it afterwards, when it answered.
    case removed(freeMemory: Int?)
    /// No applications to begin with. Nothing was sent that changes anything.
    case alreadyBlank
}

/// Why a DESFire setup or removal stopped, and whether anything had reached the
/// card first. The app turns this into words; the split that matters to those
/// words is between a card that **answered** with a refusal and a card that did
/// not answer at all, because only the second leaves the outcome unknown.
public struct DESFireNDEFError: Error, Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        /// Refused from a reading, before anything was written.
        case refused(DESFireNDEFState)
        /// Too little free memory for the smallest NDEF file this app makes.
        case notEnoughMemory(free: Int)
        /// The card answered a step with something other than success.
        case cardRefused(DESFireNDEFStep, status: String)
        /// The frame for this step went out and no answer came back, so the
        /// step may or may not have been applied.
        case noAnswer(DESFireNDEFStep)
        /// Every step was answered, and reading the card back did not show it.
        case readBackMismatch
        /// The card did not show itself at PICC level just before the factory
        /// key would have been presented, so it was not presented.
        case notAtPICCLevel
        /// The card's master key is not the factory key's type or version.
        case piccKeyNotFactory
        /// The card refused the factory key, or answered without proving it.
        case factoryKeyRefused
    }

    public let reason: Reason
    /// Whether a frame that changes the card had been sent before this.
    public let wroteSomething: Bool
    public let diagnostics: String

    public init(reason: Reason, wroteSomething: Bool, diagnostics: String) {
        self.reason = reason
        self.wroteSomething = wroteSomething
        self.diagnostics = diagnostics
    }
}

/// Sets up a factory MIFARE DESFire EV1 / EV2 / EV3 as an NFC Forum Type 4 tag,
/// and removes that setup again, over a raw `transceive` closure, so production
/// and the simulator run the same frames.
///
/// The sequence is NXP AN11004 Rev 2.4 §6.5.1 and §8.1 ("INITIALISED Formatting
/// Procedure"), without authentication, with two deliberate differences:
///
/// - **Access rights EEE0h on both files** (read, write and read-write free,
///   change needs key 0). §6.5.1 steps 5e/7e give EEEEh for an unauthenticated
///   setup; §8.1's own bytes for step 4 encode E000h, which contradicts its text
///   and would refuse the unauthenticated CC write that follows. EEE0h keeps the
///   data writes free, which this sequence needs, and stops anyone without key 0
///   changing the files' settings.
/// - **The CC is written last.** It is what makes a reader see an NDEF tag, so
///   writing it after the NDEF file exists and holds `NLEN = 0000` means a setup
///   interrupted at any step is never mistaken for a working one.
///
/// Every decision is taken from a reading. No branch depends on a particular
/// refusal code, because no DESFire refusal has ever been captured; anything
/// other than success counts as "not done", and what happened is re-read.
public struct DESFireNDEFDriver: Sendable {
    public typealias Transceive = @Sendable (RawCommand) async throws -> Data

    public let transceive: Transceive
    public let makeRandom: @Sendable (Int) -> Data

    public init(
        transceive: @escaping Transceive,
        makeRandom: @escaping @Sendable (Int) -> Data = { count in
            Data((0 ..< count).map { _ in UInt8.random(in: 0 ... 255) })
        }
    ) {
        self.transceive = transceive
        self.makeRandom = makeRandom
    }

    // MARK: - Constants (AN11004 Rev 2.4 §6.5.1, §8.1)

    static let piccAID = Data([0x00, 0x00, 0x00])
    /// 000001h, least significant byte first: AN11004 §6.5.1 step 3a's default
    /// for every DESFire after MF3ICD40.
    public static let applicationID = Data([0x01, 0x00, 0x00])
    /// Master key changeable, free file listing, free create/delete of files,
    /// settings changeable: §8.1 step 2.
    public static let keySettings1: UInt8 = 0x0F
    /// One key, ISO file IDs supported, DES/2K3DES: §6.5.1 step 3b.
    public static let keySettings2: UInt8 = 0x21
    /// Key settings 2's "ISO file IDs supported" bit. An EV3 does not report it:
    /// the application this app creates with 21h answers GetKeySettings `0F 01`,
    /// the same as the PICC (bench 2026-10-30, DF-3).
    static let isoFileIDsBit: UInt8 = 0x20
    static let applicationISOFileID = Data([0x10, 0xE1]) // E110h
    public static let ndefDFName = Data([0xD2, 0x76, 0x00, 0x00, 0x85, 0x01, 0x01])
    static let ccFileNumber: UInt8 = 0x01
    static let ndefFileNumber: UInt8 = 0x02
    static let ccISOFileID = Data([0x03, 0xE1]) // E103h
    static let ndefISOFileID = Data([0x04, 0xE1]) // E104h
    /// EEE0h, least significant byte first. See the type's comment.
    static let accessRights = Data([0xE0, 0xEE])
    public static let ccLength = 15
    /// Largest first. The owner chose "up to 4 KB" (2026-10-30).
    static let ndefSizeLadder = [0x1000, 0x0800, 0x0400]
    /// Kept back from the measured free memory before sizing the NDEF file.
    /// The EV3's allocation granularity is not settled (32 B per the D40
    /// specification, 256 B per AN12752), so this covers one 256-byte page.
    static let freeMemoryMargin = 256

    /// The Capability Container this app writes, for mapping version 2.0:
    /// CCLEN 000Fh, version 20h, MLe 003Ah (the Rev 2.4 value), MLc 0034h, then
    /// the NDEF File Control TLV naming E104h, its size, and free read and write.
    public static func capabilityContainer(ndefFileSize size: Int) -> Data {
        Data([
            0x00, 0x0F, 0x20, 0x00, 0x3A, 0x00, 0x34,
            0x04, 0x06, 0xE1, 0x04, UInt8((size >> 8) & 0xFF), UInt8(size & 0xFF), 0x00, 0x00,
        ])
    }

    /// The largest NDEF file this app makes that fits, or `nil` below 1 KB.
    public static func ndefFileSize(forFreeMemory free: Int) -> Int? {
        ndefSizeLadder.first { $0 <= free - freeMemoryMargin }
    }

    // MARK: - Reading the card

    public func readState() async throws -> DESFireNDEFState {
        guard let select = try await send(DESFireAPDU.wrap(0x5A, Self.piccAID), "SelectApplication 000000"),
              select.isOK
        else {
            return .cannotEstablish("SelectApplication 000000 was not answered 91 00")
        }
        guard let applications = try await applicationIDs() else {
            return .cannotEstablish("GetApplicationIDs was not answered 91 00 with whole AIDs")
        }
        if applications.isEmpty {
            guard let settings = try await keySettings(), settings.count >= 2 else {
                return .cannotEstablish("PICC GetKeySettings was not answered")
            }
            return settings[settings.startIndex] & 0x04 == 0 ? .applicationsNeedKey : .blank
        }
        guard applications == [Self.applicationID] else {
            return .otherApplications
        }
        return try await readOwnSetup()
    }

    private func readOwnSetup() async throws -> DESFireNDEFState {
        // The NDEF DF name, selected the ISO way, proves both the name this app
        // gave the application and that it was created with ISO file IDs. Key
        // settings cannot show the second: an EV3 leaves that bit out of its
        // answer (`isoFileIDsBit`).
        guard try await selectNDEFApplicationByName()?.isISOSuccess == true,
              try await send(DESFireAPDU.wrap(0x5A, Self.applicationID), "SelectApplication 000001")?.isOK
              == true
        else {
            return .otherNDEFSetup
        }
        guard let settings = try await keySettings(), settings.count >= 2,
              settings[settings.startIndex] == Self.keySettings1,
              settings[settings.startIndex + 1] & ~Self.isoFileIDsBit == Self.keySettings2 & ~Self.isoFileIDsBit
        else {
            return .otherNDEFSetup
        }
        guard let ids = try await send(DESFireAPDU.wrap(0x6F), "GetFileIDs"), ids.isOK else {
            return .otherNDEFSetup
        }
        let files = Set(ids.body)
        guard files.isSubset(of: [Self.ccFileNumber, Self.ndefFileNumber]) else {
            return .otherNDEFSetup
        }
        var ndefFileSize: Int?
        if files.contains(Self.ccFileNumber) {
            guard try await fileSize(Self.ccFileNumber) == Self.ccLength else { return .otherNDEFSetup }
        }
        if files.contains(Self.ndefFileNumber) {
            guard let size = try await fileSize(Self.ndefFileNumber), (2 ... 0xFFFE).contains(size) else {
                return .otherNDEFSetup
            }
            ndefFileSize = size
        }
        guard files.contains(Self.ccFileNumber) else {
            return .ours(.inProgress(hasCCFile: false, ndefFileSize: ndefFileSize))
        }
        guard let read = try await send(
            DESFireAPDU.wrap(0xBD, Data([Self.ccFileNumber, 0, 0, 0, UInt8(Self.ccLength), 0, 0])),
            "ReadData 01 (CC)"
        ), read.isOK, read.body.count >= Self.ccLength else {
            return .otherNDEFSetup
        }
        let cc = Data(read.body.prefix(Self.ccLength))
        if cc.allSatisfy({ $0 == 0 }) {
            return .ours(.inProgress(hasCCFile: true, ndefFileSize: ndefFileSize))
        }
        if let ndefFileSize, cc == Self.capabilityContainer(ndefFileSize: ndefFileSize) {
            return .ours(.complete(ndefFileSize: ndefFileSize))
        }
        return .ours(.unrecognisedContent)
    }

    /// The size of a standard data file this app could have made, or `nil` when
    /// the file is anything else: another type, communication mode or access
    /// rights. GetFileSettings answers file type, comm settings, access rights
    /// (2, LSB first) and size (3, LSB first); later generations may append more,
    /// which is ignored.
    private func fileSize(_ file: UInt8) async throws -> Int? {
        guard let response = try await send(
            DESFireAPDU.wrap(0xF5, Data([file])),
            String(format: "GetFileSettings %02X", file)
        ), response.isOK, response.body.count >= 7 else { return nil }
        let body = [UInt8](response.body)
        guard body[0] == 0x00, body[1] == 0x00, Data(body[2 ... 3]) == Self.accessRights else { return nil }
        return Self.littleEndianValue(body[4 ... 6])
    }

    private func keySettings() async throws -> Data? {
        guard let response = try await send(DESFireAPDU.wrap(0x45), "GetKeySettings"), response.isOK else {
            return nil
        }
        return response.body
    }

    /// Every AID on the card, following `91 AF` continuations (a card with
    /// more than nineteen applications answers in several frames). `nil` when
    /// the listing does not finish with `91 00` or splits unevenly.
    private func applicationIDs() async throws -> [Data]? {
        guard var response = try await send(DESFireAPDU.wrap(0x6A), "GetApplicationIDs") else { return nil }
        var body = response.body
        var continuations = 0
        while response.hasMore, continuations < 4 {
            guard let next = try await send(DESFireAPDU.wrap(0xAF), "GetApplicationIDs (cont.)") else { return nil }
            response = next
            body.append(next.body)
            continuations += 1
        }
        guard response.isOK, body.count % 3 == 0 else { return nil }
        return stride(from: 0, to: body.count, by: 3)
            .map { Data(body[body.startIndex + $0 ..< body.startIndex + $0 + 3]) }
    }

    // MARK: - Set up

    /// Create the NDEF Tag Application, or finish one this app began, and prove
    /// it the way a reader will see it.
    ///
    /// Reads the card first, on this activation, and refuses anything but a
    /// blank card or this app's unfinished setup before a single write. A card
    /// already set up the way this app sets cards up is reported and left as
    /// it is.
    public func setUp() async throws -> DESFireSetupOutcome {
        let state = try await readState()
        var run = Run()
        let hasCCFile: Bool
        var ndefFileSize: Int?
        switch state {
        case .ours(.complete(let size)):
            return .alreadySetUp(ndefFileSize: size)

        case .ours(.inProgress(let hasCC, let size)):
            hasCCFile = hasCC
            ndefFileSize = size

        case .blank:
            try await write(
                .createApplication,
                DESFireAPDU.wrap(0xCA, Self.applicationID + [Self.keySettings1, Self.keySettings2]
                    + Self.applicationISOFileID + Self.ndefDFName),
                &run
            )
            hasCCFile = false

        default:
            throw DESFireNDEFError(reason: .refused(state), wroteSomething: false, diagnostics: "\(state)")
        }

        try await expectOK(
            .selectApplication, DESFireAPDU.wrap(0x5A, Self.applicationID), run, "SelectApplication 000001"
        )
        if !hasCCFile {
            try await write(
                .createCCFile,
                DESFireAPDU.wrap(0xCD, Data([Self.ccFileNumber]) + Self.ccISOFileID + [0x00]
                    + Self.accessRights + [UInt8(Self.ccLength), 0x00, 0x00]),
                &run
            )
        }
        // The size is fixed by the file once it exists. Re-running the policy on
        // a resume would declare a size in the CC that the card does not have.
        let size: Int
        if let ndefFileSize {
            size = ndefFileSize
        } else {
            let free = try await freeMemoryAtPICCLevel(run)
            guard let chosen = Self.ndefFileSize(forFreeMemory: free) else {
                throw DESFireNDEFError(
                    reason: .notEnoughMemory(free: free),
                    wroteSomething: run.wroteSomething,
                    diagnostics: "free \(free) B after the application and CC file"
                )
            }
            try await write(
                .createNDEFFile,
                DESFireAPDU.wrap(0xCD, Data([Self.ndefFileNumber]) + Self.ndefISOFileID + [0x00]
                    + Self.accessRights + Self.littleEndian3(chosen)),
                &run
            )
            size = chosen
        }
        try await write(
            .writeNLEN,
            DESFireAPDU.wrap(0x3D, Data([Self.ndefFileNumber, 0, 0, 0, 0x02, 0, 0, 0x00, 0x00])),
            &run
        )
        let cc = Self.capabilityContainer(ndefFileSize: size)
        try await write(
            .writeCC,
            DESFireAPDU.wrap(0x3D, Data([Self.ccFileNumber, 0, 0, 0, UInt8(Self.ccLength), 0, 0]) + cc),
            &run
        )
        try await verifyAsAReaderSeesIt(cc: cc)
        return .created(ndefFileSize: size)
    }

    /// GetFreeMemory is a PICC-level command, so step out of the application to
    /// ask it and back in afterwards. Measured after the CC file exists, so the
    /// figure already includes that file's real cost.
    private func freeMemoryAtPICCLevel(_ run: Run) async throws -> Int {
        try await expectOK(.measureFreeMemory, DESFireAPDU.wrap(0x5A, Self.piccAID), run, "SelectApplication 000000")
        let raw = try await answer(.measureFreeMemory, DESFireAPDU.wrap(0x6E), "GetFreeMemory", run)
        guard let response = DESFireAPDU.split(raw), response.isOK, response.body.count >= 3 else {
            throw refusal(.measureFreeMemory, raw, run)
        }
        let body = [UInt8](response.body)
        try await expectOK(
            .measureFreeMemory, DESFireAPDU.wrap(0x5A, Self.applicationID), run, "SelectApplication 000001"
        )
        return Self.littleEndianValue(body[0 ... 2])
    }

    /// The success criterion: the ISO commands iOS's own NDEF reader sends, and
    /// the bytes they return. Every write above was acknowledged, but an
    /// acknowledgement is not proof.
    private func verifyAsAReaderSeesIt(cc: Data) async throws {
        let run = Run(wroteSomething: true)
        let checks: [(Data, String, Data?)] = [
            (Data([0x00, 0xA4, 0x04, 0x00, 0x07]) + Self.ndefDFName + [0x00], "SELECT NDEF application", nil),
            (Data([0x00, 0xA4, 0x00, 0x0C, 0x02, 0xE1, 0x03]), "SELECT E103", nil),
            (Data([0x00, 0xB0, 0x00, 0x00, UInt8(Self.ccLength)]), "READ BINARY CC", cc),
            (Data([0x00, 0xA4, 0x00, 0x0C, 0x02, 0xE1, 0x04]), "SELECT E104", nil),
            (Data([0x00, 0xB0, 0x00, 0x00, 0x02]), "READ BINARY NLEN", Data([0x00, 0x00])),
        ]
        for (frame, name, expected) in checks {
            let raw = try await answer(.readBack, frame, name, run)
            guard let response = DESFireAPDU.split(raw), response.isISOSuccess,
                  expected == nil || response.body == expected
            else {
                throw DESFireNDEFError(
                    reason: .readBackMismatch,
                    wroteSomething: true,
                    diagnostics: "\(name) answered \(raw.hexString)"
                        + (expected.map { ", expected \($0.hexString) 90 00" } ?? ", expected 90 00")
                )
            }
        }
    }

    // MARK: - Remove

    /// Return a card this app set up to blank: present the factory master key
    /// once, then FormatPICC, which releases the memory (EV3 short datasheet
    /// Table 5; DeleteApplication only deactivates it, Table 7).
    ///
    /// FormatPICC deletes every application, so it is sent only after this
    /// activation has read the card and found this app's NDEF application as
    /// its sole content, and confirmed it is back at PICC level before key 0 is
    /// presented: key 0 inside the application is also the zero key.
    public func remove() async throws -> DESFireRemoveOutcome {
        guard try await requireOwnSetupToRemove() else { return .alreadyBlank }
        try await authenticateWithFactoryKey()

        let raw: Data
        do {
            raw = try await transceive(RawCommand(bytes: DESFireAPDU.wrap(0xFC), name: "FormatPICC"))
        } catch let error as TagError {
            throw DESFireNDEFError(
                reason: .noAnswer(.formatPICC), wroteSomething: true, diagnostics: error.diagnostics
            )
        }
        // The answer carries a CMAC under the session the authentication opened,
        // which is not verified: the read-back below is the proof.
        guard let response = DESFireAPDU.split(raw), response.isOK else {
            throw DESFireNDEFError(
                reason: .cardRefused(.formatPICC, status: raw.suffix(2).hexString),
                wroteSomething: true, diagnostics: "FormatPICC answered \(raw.hexString)"
            )
        }
        return try await verifyBlank()
    }

    private func verifyBlank() async throws -> DESFireRemoveOutcome {
        do {
            // Selecting the PICC level ends the authenticated session, so the
            // listing below comes back plain rather than with a CMAC appended.
            guard try await send(DESFireAPDU.wrap(0x5A, Self.piccAID), "SelectApplication 000000")?.isOK == true,
                  let applications = try await applicationIDs(), applications.isEmpty
            else {
                throw DESFireNDEFError(
                    reason: .readBackMismatch, wroteSomething: true,
                    diagnostics: "applications remain after FormatPICC"
                )
            }
            // Tidy-up, never a reason to fail: the card is blank either way.
            let free = try? await send(DESFireAPDU.wrap(0x6E), "GetFreeMemory")
            let bytes = free.flatMap { $0 }.flatMap { $0.isOK && $0.body.count >= 3 ? [UInt8]($0.body) : nil }
            return .removed(freeMemory: bytes.map { Self.littleEndianValue($0[0 ... 2]) })
        } catch let error as TagError {
            throw DESFireNDEFError(
                reason: .noAnswer(.readBack), wroteSomething: true, diagnostics: error.diagnostics
            )
        }
    }

    /// Remove NDEF setup's first tap: every check `remove()` makes before it
    /// presents the factory key, and nothing after it. Read-only. `false` for a
    /// card with no applications, which has nothing to remove.
    public func checkRemovable() async throws -> Bool {
        guard try await requireOwnSetupToRemove() else { return false }
        try await requireFactoryKeyPresentable()
        return true
    }

    /// `false` for a card with no applications; throws for anything but this
    /// app's own setup, which includes answering to the NDEF DF name.
    private func requireOwnSetupToRemove() async throws -> Bool {
        let state = try await readState()
        switch state {
        // No applications is blank whatever the key settings say.
        case .blank, .applicationsNeedKey:
            return false

        case .ours:
            return true

        default:
            throw DESFireNDEFError(reason: .refused(state), wroteSomething: false, diagnostics: "\(state)")
        }
    }

    /// ISO SELECT of the NDEF application by its DF name.
    private func selectNDEFApplicationByName() async throws -> DESFireAPDU.Response? {
        try await send(Data([0x00, 0xA4, 0x04, 0x00, 0x07]) + Self.ndefDFName + [0x00], "SELECT NDEF application")
    }

    /// Present the factory PICC master key (DES, all zero) once, with
    /// AuthenticateISO, after checking that the card is at PICC level and that
    /// its master key is still the factory one by type and version.
    ///
    /// One attempt per activation. A refusal is reported, never retried: a
    /// card whose key is not the factory one will not take it on a second try.
    public func authenticateWithFactoryKey() async throws {
        try await requireFactoryKeyPresentable()
        try await presentFactoryKey()
    }

    private func requireFactoryKeyPresentable() async throws {
        guard try await send(DESFireAPDU.wrap(0x5A, Self.piccAID), "SelectApplication 000000")?.isOK == true,
              let settings = try await keySettings(), settings.count >= 2
        else {
            throw DESFireNDEFError(reason: .notAtPICCLevel, wroteSomething: false, diagnostics: "no PICC key settings")
        }
        let keyByte = settings[settings.startIndex + 1]
        // The select's `91 00` is what puts the card at PICC level; key
        // settings cannot tell the levels apart on an EV3, where this app's
        // application answers `0F 01` just as the PICC does (bench 2026-10-30).
        // What they do say is the master key's shape: the PICC has exactly one
        // key and never reports ISO file IDs, so anything else is not its answer.
        guard keyByte & Self.isoFileIDsBit == 0, keyByte & 0x0F == 0x01 else {
            throw DESFireNDEFError(
                reason: .notAtPICCLevel, wroteSomething: false,
                diagnostics: "GetKeySettings answered \(settings.hexString)"
            )
        }
        guard keyByte >> 6 == 0 else {
            throw DESFireNDEFError(
                reason: .piccKeyNotFactory, wroteSomething: false,
                diagnostics: "PICC master key type bits \(keyByte >> 6), not DES"
            )
        }
        let version = try await send(DESFireAPDU.wrap(0x64, Data([0x00])), "GetKeyVersion 0")
        guard let version, version.isOK, version.body.first == 0x00 else {
            throw DESFireNDEFError(
                reason: .piccKeyNotFactory, wroteSomething: false,
                diagnostics: "PICC master key version \(version?.body.hexString ?? "unread"), not 00"
            )
        }
    }

    private func presentFactoryKey() async throws {
        let challenge = try await send(DESFireAPDU.wrap(0x1A, Data([0x00])), "AuthenticateISO")
        guard let challenge, challenge.hasMore, challenge.body.count == ISO3DESHandshake.blockSize else {
            throw DESFireNDEFError(
                reason: .factoryKeyRefused, wroteSomething: false,
                diagnostics: "AuthenticateISO leg 1 answered \(challenge?.statusHex ?? "nothing")"
            )
        }
        let handshake = try ISO3DESHandshake(
            key: Data(repeating: 0, count: 16),
            challenge: challenge.body,
            rndA: makeRandom(ISO3DESHandshake.blockSize)
        )
        let proof = try await send(DESFireAPDU.wrap(0xAF, handshake.token), "AuthenticateISO part 2")
        guard let proof, proof.isOK, proof.body.count >= ISO3DESHandshake.blockSize,
              try handshake.cardProvesKey(Data(proof.body.prefix(ISO3DESHandshake.blockSize)))
        else {
            throw DESFireNDEFError(
                reason: .factoryKeyRefused, wroteSomething: false,
                diagnostics: "AuthenticateISO leg 2 answered \(proof?.statusHex ?? "nothing")"
            )
        }
    }

    // MARK: - Frames

    /// What a run has done so far, so a stop can say whether the card changed.
    private struct Run {
        var wroteSomething = false
    }

    private func send(_ frame: Data, _ name: String) async throws -> DESFireAPDU.Response? {
        try await DESFireAPDU.split(transceive(RawCommand(bytes: frame, name: name)))
    }

    /// A step whose frame may change the card. Marked as written **before** the
    /// frame goes out: a lost answer may hide a write that was applied.
    private func write(_ step: DESFireNDEFStep, _ frame: Data, _ run: inout Run) async throws {
        run.wroteSomething = true
        let raw = try await answer(step, frame, step.rawValue, run)
        guard DESFireAPDU.split(raw)?.isOK == true else { throw refusal(step, raw, run) }
    }

    private func expectOK(
        _ step: DESFireNDEFStep, _ frame: Data, _ run: Run, _ name: String? = nil
    ) async throws {
        let raw = try await answer(step, frame, name ?? step.rawValue, run)
        guard DESFireAPDU.split(raw)?.isOK == true else { throw refusal(step, raw, run) }
    }

    /// Send a frame and return its raw answer. A transport failure after the
    /// card may have changed becomes `noAnswer`; before that, the original
    /// error stands, because nothing happened and the ordinary "tag lost"
    /// handling is the right one.
    private func answer(_ step: DESFireNDEFStep, _ frame: Data, _ name: String, _ run: Run) async throws -> Data {
        do {
            return try await transceive(RawCommand(bytes: frame, name: name))
        } catch let error as TagError where run.wroteSomething {
            throw DESFireNDEFError(reason: .noAnswer(step), wroteSomething: true, diagnostics: error.diagnostics)
        }
    }

    private func refusal(_ step: DESFireNDEFStep, _ raw: Data, _ run: Run) -> DESFireNDEFError {
        DESFireNDEFError(
            reason: .cardRefused(step, status: raw.suffix(2).hexString),
            wroteSomething: run.wroteSomething,
            diagnostics: "\(step.rawValue) answered \(raw.hexString)"
        )
    }

    static func littleEndianValue(_ bytes: ArraySlice<UInt8>) -> Int {
        var value = 0
        for (shift, byte) in bytes.enumerated() {
            value |= Int(byte) << (8 * shift)
        }
        return value
    }

    static func littleEndian3(_ value: Int) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF)])
    }
}
