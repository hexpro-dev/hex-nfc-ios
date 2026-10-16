@testable import HexNFCKit
@testable import HexNFCRecords
@testable import HexNFCTagSim
import XCTest

/// End-to-end Type-4 (NTAG424 DNA) protection, with the production EV2 driver
/// (`NTAG424ProtectionDriver`, reached via the family-agnostic `enableProtection`)
/// run against the chip simulator through `transceive` — no hardware. The sim
/// enforces the NDEF file's access-rights nibbles, so "unauthenticated write
/// refused / authenticated write allowed" is a real assertion, not a vacuous one.
final class NTAG424ProtectionTests: XCTestCase {
    private let userKey = Data((0 ..< 16).map { UInt8(0xA0 &+ $0) })

    private func makeTag() async throws -> (ConnectedTag, NTAG424DNASimulator) {
        let sim = NTAG424DNASimulator()
        let tag = try await SimulatedSession(chip: sim).start(alert: "")
        return (tag, sim)
    }

    /// Select the NDEF file (E104) then attempt a plain ISO UPDATE BINARY — the
    /// route an unauthenticated reader (or iOS's high-level writeNDEF) would take.
    /// Returns the trailing status word.
    private func plainNDEFWrite(_ tag: ConnectedTag) async throws -> UInt16 {
        _ = try await tag.transceive(RawCommand(bytes: Data([0x00, 0xA4, 0x00, 0x0C, 0x02, 0xE1, 0x04])))
        let payload = Data([0x00, 0x03, 0xD0, 0x00, 0x00]) // 2-byte length + tiny NDEF body
        var cmd = Data([0x00, 0xD6, 0x00, 0x00, UInt8(payload.count)])
        cmd.append(payload)
        return try await statusWord(tag.transceive(RawCommand(bytes: cmd)))
    }

    private func statusWord(_ d: Data) -> UInt16 {
        guard d.count >= 2 else { return 0 }
        return (UInt16(d[d.endIndex - 2]) << 8) | UInt16(d[d.endIndex - 1])
    }

    func test_protectionStyle_424_isType4() async throws {
        let (tag, _) = try await makeTag()
        guard case .type4? = tag.protectionStyle else {
            return XCTFail("NTAG424 DNA should report a .type4 protectionStyle")
        }
    }

    func test_freshTag_readsAsUnprotected() async throws {
        let (tag, _) = try await makeTag()
        let state = try await tag.readProtectionState()
        XCTAssertEqual(state, TagProtection.none)
    }

    func test_enable_refusesUnauthenticatedWrite_thenAuthAllows() async throws {
        let (tag, sim) = try await makeTag()

        // Free file: a plain write is accepted.
        sim.endSession()
        let before = try await plainNDEFWrite(tag)
        XCTAssertEqual(before, 0x9000, "a free NDEF file should accept a plain write")

        // Enable write-only protection (AES key in slot 0).
        try await tag.enableProtection(.type4(aesKey: userKey, keySlot: 0, readProtect: false))

        // Fresh tap: unauthenticated write now refused.
        sim.endSession()
        let refused = try await plainNDEFWrite(tag)
        XCTAssertEqual(refused, 0x6982, "key-gated file must refuse a plain write")

        // Authenticate with the key → the session satisfies W=key0 → write allowed.
        _ = try await tag.authenticate(.type4(aesKey: userKey, keySlot: 0))
        let allowed = try await plainNDEFWrite(tag)
        XCTAssertEqual(allowed, 0x9000, "authenticated session should allow the write")
    }

    func test_readProtectionState_reportsWriteOnly() async throws {
        let (tag, sim) = try await makeTag()
        try await tag.enableProtection(.type4(aesKey: userKey, keySlot: 0, readProtect: false))
        sim.endSession()
        let state = try await tag.readProtectionState()
        XCTAssertEqual(state?.passwordProtect, true)
        XCTAssertEqual(state?.effectiveReadProtect, false)
    }

    func test_readProtectVariant_reportsReadProtected() async throws {
        let (tag, sim) = try await makeTag()
        try await tag.enableProtection(.type4(aesKey: userKey, keySlot: 0, readProtect: true))
        sim.endSession()
        let state = try await tag.readProtectionState()
        XCTAssertEqual(state?.passwordProtect, true)
        XCTAssertEqual(state?.effectiveReadProtect, true)
    }

    func test_disable_restoresFreeAccessAndKey() async throws {
        let (tag, sim) = try await makeTag()
        try await tag.enableProtection(.type4(aesKey: userKey, keySlot: 0, readProtect: false))
        sim.endSession()

        try await tag.disableProtection(using: .type4(aesKey: userKey, keySlot: 0))
        sim.endSession()

        let state = try await tag.readProtectionState()
        XCTAssertEqual(state, TagProtection.none)
        let write = try await plainNDEFWrite(tag)
        XCTAssertEqual(write, 0x9000, "plain writes work again after disable")
        // Key reset to factory zero, and the key version with it.
        XCTAssertEqual(sim.keys[0], Data(count: 16))
        XCTAssertEqual(sim.keyVersions[0], NTAG424KeyVersion.factory)
    }

    // MARK: - The read-back ships

    /// CLAUDE.md: "the verification may not be `#if DEBUG`". Both Type-4
    /// protection operations read the access rights back and report a verdict
    /// the caller can act on, in the shipping driver rather than in the harness.
    func test_enable_readsTheGateBackAndReportsAProvenVerdict() async throws {
        let sim = NTAG424DNASimulator()
        let driver = NTAG424ProtectionDriver(transceive: { sim.handle(command: $0.bytes) })
        let residue = try await driver.enable(aesKey: userKey, keySlot: 0, readProtect: false)

        XCTAssertEqual(residue.family, .type4)
        XCTAssertEqual(residue.intent, .enable)
        XCTAssertEqual(residue.gate, .provenArmed(fromPage: 0))
        XCTAssertEqual(residue.credential, .callerSupplied)
        XCTAssertTrue(residue.completed.contains(.stateRead))
        XCTAssertTrue(residue.completed.contains(.credentialProven),
                      "the key is proven by authenticating with it before the gate is armed")
        XCTAssertTrue(residue.completed.contains(.gateProven))
        XCTAssertTrue(residue.metItsGoal)
        XCTAssertTrue(residue.isComplete, "nothing was refused or lost")
    }

    func test_disable_readsTheGateBackAndReportsAProvenVerdict() async throws {
        let sim = NTAG424DNASimulator()
        let driver = NTAG424ProtectionDriver(transceive: { sim.handle(command: $0.bytes) })
        try await driver.enable(aesKey: userKey, keySlot: 0, readProtect: false)
        sim.endSession()

        let removal = NTAG424ProtectionDriver(transceive: { sim.handle(command: $0.bytes) })
        let residue = try await removal.disable(currentKey: userKey, keySlot: 0)
        XCTAssertEqual(residue.intent, .disable)
        XCTAssertEqual(residue.gate, .provenOpen)
        XCTAssertEqual(residue.credential, .factoryDefault)
        XCTAssertTrue(residue.metItsGoal)
        XCTAssertTrue(residue.isComplete)
    }

    /// The gate is armed **after** the key, not before it. Asserted on the wire,
    /// because the order is the whole of the abort-recovery guarantee.
    func test_enable_changesTheKeyBeforeItArmsTheGate() async throws {
        let sim = NTAG424DNASimulator()
        let order = INSRecorder()
        let driver = NTAG424ProtectionDriver(transceive: { command in
            let bytes = [UInt8](command.bytes)
            if bytes.count >= 2, bytes[0] == 0x90 {
                await order.record(bytes[1])
            }
            return sim.handle(command: command.bytes)
        })
        try await driver.enable(aesKey: userKey, keySlot: 0, readProtect: false)

        let sent = await order.instructions
        let changeKey = try XCTUnwrap(sent.firstIndex(of: 0xC4))
        let changeFileSettings = try XCTUnwrap(sent.firstIndex(of: 0x5F))
        XCTAssertLessThan(changeKey, changeFileSettings,
                          "ChangeKey first: an abort between the two must leave the file free")
    }

    /// The core of the architectural fix: after authenticating a write-protected
    /// 424, a high-level `writeNDEF` runs *inside the live EV2 session* (the tag
    /// persists it via `ev2Session`) and round-trips through the gated NDEF file.
    func test_authenticatedRewrite_writeOnly_roundTripsViaSession() async throws {
        let (tag, sim) = try await makeTag()
        let records: [NDEFRecord] = [.uri(URIRecord(uri: "https://hex.pro"))]

        try await tag.enableProtection(.type4(aesKey: userKey, keySlot: 0, readProtect: false))
        sim.endSession() // fresh tap — no session yet

        _ = try await tag.authenticate(.type4(aesKey: userKey, keySlot: 0))
        try await tag.writeNDEF(records) // plain-comm WriteData, gated on the session
        let echoed = try await tag.readNDEF()
        XCTAssertEqual(echoed, try NDEFCodec.encode(records),
                       "an authenticated 424 NDEF write must round-trip via the EV2 session")
    }

    /// Read+write protection puts the NDEF file in *full* comm mode, so the write
    /// is encrypted+MAC'd and the read response is decrypted+verified — exercising
    /// the secure WriteData/ReadData path, not just the plain one.
    func test_authenticatedRewrite_readProtected_fullModeRoundTrips() async throws {
        let (tag, sim) = try await makeTag()
        let records: [NDEFRecord] = [.uri(URIRecord(uri: "https://hex.pro"))]

        try await tag.enableProtection(.type4(aesKey: userKey, keySlot: 0, readProtect: true))
        sim.endSession()

        _ = try await tag.authenticate(.type4(aesKey: userKey, keySlot: 0))
        try await tag.writeNDEF(records) // full-mode (encrypted + MAC) WriteData
        let echoed = try await tag.readNDEF() // full-mode (decrypt + verify MAC) ReadData
        XCTAssertEqual(echoed, try NDEFCodec.encode(records),
                       "a read+write-protected 424 must round-trip through full secure messaging")
    }

    func test_wrongKey_authFails() async throws {
        let (tag, sim) = try await makeTag()
        try await tag.enableProtection(.type4(aesKey: userKey, keySlot: 0, readProtect: false))
        sim.endSession()
        do {
            _ = try await tag.authenticate(.type4(aesKey: Data(repeating: 0xFF, count: 16), keySlot: 0))
            XCTFail("authenticating with the wrong key should throw")
        } catch let error as TagError {
            if case .authFailed = error.kind {
                return
            }
            XCTFail("expected .authFailed, got \(error.kind)")
        }
    }
}

private actor INSRecorder {
    private(set) var instructions: [UInt8] = []
    func record(_ ins: UInt8) {
        instructions.append(ins)
    }
}
