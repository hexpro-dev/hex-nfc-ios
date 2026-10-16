import Foundation
import HexNFCKit
import HexNFCRecords
import HexNFCTagSim
import XCTest

/// The anti-drift guard for "the shipped frames are the tested frames".
///
/// ## Why this file exists
///
/// Every Type-2 credential operation used to have two implementations: one in
/// `CoreNFCConnectedTag` that built frames, and one in `SimulatedConnectedTag`
/// that reached into the simulator's in-memory model. Only the second ever ran
/// in CI. So the four writes that stranded a real NTAG213 on 2026-09-04 had a
/// full green suite behind them and had never once been executed.
///
/// The same bypass had already cost a live run on 2026-08-07, when a
/// dynamic-lock payload that set reserved bits on every NTAG21x reached silicon
/// unopposed, and `Type2LockDriverTests` was written to close it for the lock
/// path. This file closes it for the credential path, and states the rule in a
/// form that fails the build rather than living in a comment.
///
/// ## What it asserts
///
/// That each operation actually **emits frames**. A parallel implementation
/// cannot: it answers from a model and puts nothing on the wire. So if anyone
/// reintroduces a `SimulatedConnectedTag.authenticate(password:)` or similar,
/// the frame count for that operation drops to zero and this fails, naming the
/// operation.
///
/// It asserts the *shape* (opcodes and the pages they address) for most
/// operations, because byte-exact expectations belong with the operation that
/// owns them and this file's job is to notice that the wire went quiet.
///
/// The enable sequence is the exception, on two counts. Its four writes have an
/// order that is load-bearing (AUTH0 last, then prove) and no test held it. And
/// its two configuration writes are read-modify-write over bytes that exist only
/// on a real tag, so a constructed page would have passed everything here while
/// dropping CFG0 byte 0 and CFG1 byte 1 on every NTAG213, NTAG216 and UL EV1 128
/// (bench 2026-09-09, finding 5). Those two frames are asserted literally.
final class ShippedFramesTests: XCTestCase {
    private let password = Data([0x11, 0x22, 0x33, 0x44])
    private let pack = Data([0xAA, 0xBB])

    // MARK: - Each credential operation reaches the wire

    func test_authenticate_emitsAPasswordAuthFrame() async throws {
        let wire = RecordingSimulator(NTAG213Simulator())
        let tag = try await SimulatedSession(chip: wire).start(alert: "")
        try wire.inner.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )
        wire.inner.beginActivation()
        wire.reset()

        _ = try await tag.authenticate(password: password)

        XCTAssertTrue(
            wire.contains(opcode: 0x1B),
            "authenticate must put a PWD_AUTH on the wire. A zero-frame authenticate means a "
                + "parallel implementation has been reintroduced on SimulatedConnectedTag."
        )
    }

    func test_enableProtection_emitsWritesToEveryCredentialAndConfigPage() async throws {
        let layout = try XCTUnwrap(Type2ConfigLayout.for(.ntag213))
        let wire = RecordingSimulator(NTAG213Simulator())
        let tag = try await SimulatedSession(chip: wire).start(alert: "")

        try await tag.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )

        for page in [layout.pwdPage, layout.packPage, layout.config1Page, layout.config0Page] {
            XCTAssertTrue(
                wire.contains(write: page),
                "enable must write page \(page) on the wire, not into a model"
            )
        }
    }

    /// AUTH0 last, then prove. Until AUTH0 lands the tag is simply unprotected
    /// rather than half protected, so the credential and ACCESS go first. The
    /// `1B` afterwards is the credential proof: PWD and PACK read back as zeros
    /// by design, so presenting the password and seeing the PACK come back is the
    /// only proof of the credential a Type-2 tag can give.
    ///
    /// No test held any of this. The four-page assertion above passes for every
    /// permutation of the same four writes (bench 2026-09-09, finding 5).
    func test_enableProtection_writesAUTH0LastAndProvesTheCredentialAfterIt() async throws {
        let layout = try XCTUnwrap(Type2ConfigLayout.for(.ntag213))
        let wire = RecordingSimulator(NTAG213Simulator())
        let tag = try await SimulatedSession(chip: wire).start(alert: "")

        try await tag.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )

        let pwdWrite = try XCTUnwrap(wire.firstIndex(write: layout.pwdPage))
        let packWrite = try XCTUnwrap(wire.firstIndex(write: layout.packPage))
        let accessWrite = try XCTUnwrap(wire.firstIndex(write: layout.config1Page))
        let auth0Write = try XCTUnwrap(wire.firstIndex(write: layout.config0Page))

        XCTAssertLessThan(pwdWrite, packWrite, "the PACK follows the PWD")
        XCTAssertLessThan(packWrite, accessWrite, "ACCESS follows the credential it gates")
        XCTAssertLessThan(accessWrite, auth0Write, "AUTH0 is the activation step and goes last")

        let proof = wire.frames.enumerated().first { index, frame in
            index > auth0Write && frame.first == 0x1B
        }
        XCTAssertNotNil(
            proof,
            "a PWD_AUTH must follow the AUTH0 write: an ACK is not proof, and the PACK round trip "
                + "is the only proof of the credential this chip can give"
        )
    }

    /// The delivery bytes come back on the wire.
    ///
    /// `Type2Credential.config0(settingAuth0:)` and
    /// `config1(readProtect:authLimit:)` are read-modify-write: they replace
    /// AUTH0 and the PROT / AUTH_LIM bits and preserve every other byte. Until
    /// 2026-09-09 the simulator held zeros in those bytes, so a constructed
    /// `Data([access, 0, 0, 0])` would have passed every test in this file while
    /// every real NTAG213, NTAG216 and UL EV1 128 quietly lost its `05`.
    ///
    /// Both expected frames were captured on silicon on 2026-09-09 and are
    /// recorded in `docs/internal/chip-config-pages.md`.
    func test_enableProtection_carriesTheDeliveryBytesBackOntoTheWire() async throws {
        let layout = try XCTUnwrap(Type2ConfigLayout.for(.ntag213))
        let wire = RecordingSimulator(NTAG213Simulator())
        let tag = try await SimulatedSession(chip: wire).start(alert: "")

        try await tag.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )

        XCTAssertEqual(
            try XCTUnwrap(wire.frame(write: layout.config0Page)),
            Data([0xA2, UInt8(layout.config0Page), 0x04, 0x00, 0x00, 0x04]),
            "CFG0: AUTH0 set to page 4, the delivery 04 in byte 0 preserved (A2:29:04:00:00:04)"
        )
        XCTAssertEqual(
            try XCTUnwrap(wire.frame(write: layout.config1Page)),
            Data([0xA2, UInt8(layout.config1Page), 0x00, 0x05, 0x00, 0x00]),
            "CFG1: ACCESS written, the delivery 05 in byte 1 preserved (A2:2A:00:05:00:00)"
        )
    }

    /// The tag carries an attempt limit so that every page in the list below is
    /// a page this removal has something to change.
    ///
    /// `disable` skips the ACCESS write when the byte it would send is the byte
    /// already on the page, which on a write-only-protected tag with no limit is
    /// every time. The frame-on-the-wire guard is unchanged and still the point
    /// of this test: what the limit does is make ACCESS a real change, so the
    /// assertion is about a frame the driver owes rather than one it has nothing
    /// to put in. The skip itself is covered in `ProtectionDesyncTests`.
    func test_disableProtection_emitsWritesAndReadsTheGateBack() async throws {
        let layout = try XCTUnwrap(Type2ConfigLayout.for(.ntag213))
        let wire = RecordingSimulator(NTAG213Simulator())
        let tag = try await SimulatedSession(chip: wire).start(alert: "")
        try wire.inner.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 3
        )
        wire.inner.beginActivation()
        wire.reset()

        try await tag.disableProtection(using: .type2(password: password, pack: pack))

        for page in [layout.config1Page, layout.config0Page, layout.pwdPage, layout.packPage] {
            XCTAssertTrue(wire.contains(write: page), "removal must write page \(page) on the wire")
        }
        // The read-back is the success criterion, so it has to be a real frame.
        let lastGateWrite = try XCTUnwrap(wire.lastIndex(write: layout.config0Page))
        let readAfter = wire.frames.enumerated().contains { index, frame in
            index > lastGateWrite && frame.first == 0x30
        }
        XCTAssertTrue(readAfter, "removal must READ the config back AFTER writing AUTH0, to prove the gate is open")
    }

    func test_readProtectionState_readsTheConfigPagesOffTheWire() async throws {
        let layout = try XCTUnwrap(Type2ConfigLayout.for(.ntag213))
        let wire = RecordingSimulator(NTAG213Simulator())
        let tag = try await SimulatedSession(chip: wire).start(alert: "")

        _ = try await tag.readProtectionState()

        XCTAssertTrue(
            wire.frames.contains { $0.first == 0x30 },
            "protection state must be read from the tag, never reported from a model"
        )
        XCTAssertTrue(
            wire.frames.contains { $0.first == 0x30 && Int($0[$0.startIndex + 1]) == layout.config0Page }
                || wire.frames.contains { $0.first == 0x30 && Int($0[$0.startIndex + 1]) <= layout.config0Page },
            "the read must reach the configuration block"
        )
    }

    // MARK: - The credential never appears in a readable page

    /// PWD and PACK read back as zeros on real silicon by design (NTAG213 rev
    /// 3.2 section 8.8). A simulator that serves the real bytes would let an
    /// implementer "verify" a credential by reading it back: green in CI,
    /// broken on every real tag.
    func test_credentialPagesNeverReadBackTheirRealBytes() async throws {
        let layout = try XCTUnwrap(Type2ConfigLayout.for(.ntag213))
        let sim = NTAG213Simulator()
        let tag = try await SimulatedSession(chip: sim).start(alert: "")
        try await tag.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: false, authLimit: 0
        )

        let served = sim.handle(command: Data([0x30, UInt8(layout.pwdPage)]))
        XCTAssertGreaterThan(served.count, 1, "the read itself must succeed")
        XCTAssertFalse(
            served.dropFirst(0).prefix(4) == password,
            "a READ of the PWD page must not disclose the password: real silicon answers zeros"
        )
    }
}

// MARK: - Recording

/// Wraps a simulator and records every frame that reaches it.
private final class RecordingSimulator: ChipSimulator, @unchecked Sendable {
    let inner: NTAG213Simulator
    private(set) var frames: [Data] = []

    init(_ inner: NTAG213Simulator) {
        self.inner = inner
    }

    func reset() {
        frames.removeAll()
    }

    func contains(opcode: UInt8) -> Bool {
        frames.contains { $0.first == opcode }
    }

    func contains(write page: Int) -> Bool {
        lastIndex(write: page) != nil
    }

    func lastIndex(write page: Int) -> Int? {
        frames.lastIndex { $0.count >= 2 && $0.first == 0xA2 && Int($0[$0.startIndex + 1]) == page }
    }

    func firstIndex(write page: Int) -> Int? {
        frames.firstIndex { $0.count >= 2 && $0.first == 0xA2 && Int($0[$0.startIndex + 1]) == page }
    }

    /// The whole WRITE frame, opcode and page byte included, so a test can assert
    /// the payload and not only that the page was addressed.
    func frame(write page: Int) -> Data? {
        lastIndex(write: page).map { frames[$0] }
    }

    var uid: Data {
        inner.uid
    }

    var profile: ChipProfile? {
        inner.profile
    }

    func handle(command: Data) -> Data {
        frames.append(command)
        return inner.handle(command: command)
    }

    func readMemory(range: Range<Int>) throws -> Data {
        try inner.readMemory(range: range)
    }

    func writeMemory(at offset: Int, bytes: Data) throws {
        try inner.writeMemory(at: offset, bytes: bytes)
    }

    func readNDEF() throws -> Data {
        try inner.readNDEF()
    }

    func writeNDEF(_ bytes: Data) throws {
        try inner.writeNDEF(bytes)
    }

    func permanentLock() throws {
        try inner.permanentLock()
    }

    func beginActivation() {
        inner.beginActivation()
    }

    /// Seed-and-assert helpers, not a production path.
    func authenticate(password: Data) throws -> Data {
        try inner.authenticate(password: password)
    }

    func setPassword(_ password: Data, pack: Data) throws {
        try inner.setPassword(password, pack: pack)
    }

    func readProtectionState() throws -> TagProtection? {
        try inner.readProtectionState()
    }

    func enablePasswordProtection(
        password: Data, pack: Data, protectFromPage: Int, readProtect: Bool, authLimit: Int
    ) throws {
        try inner.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: protectFromPage,
            readProtect: readProtect, authLimit: authLimit
        )
    }

    func disablePasswordProtection(currentPassword: Data) throws {
        try inner.disablePasswordProtection(currentPassword: currentPassword)
    }
}
