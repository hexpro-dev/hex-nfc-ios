@testable import HexNFCKit
@testable import HexNFCRecords
@testable import HexNFCTagSim
import XCTest

/// Behavioural coverage of `Iso15693Simulator`. ISO 15693 commands carry
/// a leading flag byte (0x02 = high data rate, no addressing per the
/// presets in `CommandPresetCatalog`). Every test below sends commands in
/// that format and checks the first response byte (0x00 = success,
/// 0x01 = error).
final class Iso15693SimulatorTests: XCTestCase {
    // MARK: - Read / write blocks

    func test_readSingleBlock_block0_returnsType5CapabilityContainer() {
        // Per NFC Forum T5T 1.0 §4.2: CC encodes the T5T_Area *after* the
        // CC. SLIX has 28 × 4 = 112 bytes total; subtract the 4-byte CC →
        // 108 bytes available; MLEN must be a multiple of 8 → floor(108/8)
        // = 13 (0x0D), giving 104 addressable bytes. Feature flags `0x09`
        // advertise MBREAD + Lock Block, both of which SLIX supports.
        let sim = Iso15693Simulator()
        let response = sim.handle(command: Data([0x02, 0x20, 0x00]))
        XCTAssertEqual(response, Data([0x00, 0xE1, 0x40, 0x0D, 0x09]))
    }

    func test_readSingleBlock_block5_returnsZeroes() {
        // Any block past the empty-NDEF TLV (block 1) is still zeros.
        let sim = Iso15693Simulator()
        let response = sim.handle(command: Data([0x02, 0x20, 0x05]))
        XCTAssertEqual(response, Data([0x00, 0x00, 0x00, 0x00, 0x00]))
    }

    func test_readSingleBlock_block1_returnsEmptyNDEFTLV() {
        // Empty TLV envelope at block 1: 0x03 = NDEF Message TLV, 0x00 =
        // zero-length payload, 0xFE = Terminator TLV, then a padding zero.
        let sim = Iso15693Simulator()
        let response = sim.handle(command: Data([0x02, 0x20, 0x01]))
        XCTAssertEqual(response, Data([0x00, 0x03, 0x00, 0xFE, 0x00]))
    }

    func test_writeSingleBlock_thenReadBack_roundTrips() {
        let sim = Iso15693Simulator()
        let writeResponse = sim.handle(command: Data([0x02, 0x21, 0x05, 0xAA, 0xBB, 0xCC, 0xDD]))
        XCTAssertEqual(writeResponse, Data([0x00]))
        let readResponse = sim.handle(command: Data([0x02, 0x20, 0x05]))
        XCTAssertEqual(readResponse, Data([0x00, 0xAA, 0xBB, 0xCC, 0xDD]))
    }

    func test_readMultipleBlocks_returnsFlagPlusCountTimesFourBytes() {
        let sim = Iso15693Simulator()
        _ = sim.handle(command: Data([0x02, 0x21, 0x00, 0x11, 0x22, 0x33, 0x44]))
        _ = sim.handle(command: Data([0x02, 0x21, 0x01, 0x55, 0x66, 0x77, 0x88]))
        // READ_MULTIPLE_BLOCKS firstBlock=0 count=2 → countMinusOne=0x01.
        let response = sim.handle(command: Data([0x02, 0x23, 0x00, 0x01]))
        XCTAssertEqual(response, Data([0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88]))
    }

    func test_readBeyondMemory_returnsErrorFlag() {
        let sim = Iso15693Simulator()
        let response = sim.handle(command: Data([0x02, 0x20, 0xFE])) // way past 28 blocks
        XCTAssertEqual(response.first, 0x01)
    }

    // MARK: - Lock state machine

    func test_lockBlock_blocksFurtherWrites() {
        let sim = Iso15693Simulator()
        let lockResponse = sim.handle(command: Data([0x02, 0x22, 0x03]))
        XCTAssertEqual(lockResponse, Data([0x00]))
        let writeResponse = sim.handle(command: Data([0x02, 0x21, 0x03, 0x00, 0x00, 0x00, 0x00]))
        // §9.6: the SLIX2's only error code is the generic 0F — never 0x12.
        XCTAssertEqual(writeResponse, Data([0x01, 0x0F]))
    }

    func test_lockAFI_blocksFurtherWriteAFI() {
        let sim = Iso15693Simulator()
        _ = sim.handle(command: Data([0x02, 0x27, 0xAA])) // WRITE_AFI 0xAA
        _ = sim.handle(command: Data([0x02, 0x28])) // LOCK_AFI
        let response = sim.handle(command: Data([0x02, 0x27, 0xBB]))
        XCTAssertEqual(response, Data([0x01, 0x0F]))
        XCTAssertEqual(sim.afi, 0xAA, "AFI should remain at locked value")
    }

    /// "Block 79 of the user memory contains the 16-bit counter feature and
    /// cannot be locked" (§9.5.2.3). Live 2026-08-07: the first permanent-lock
    /// run locked 00–4E cleanly, then failed the whole op on this refusal —
    /// because this simulator ACKed the counter-block lock the silicon refuses.
    func test_lockBlock_refusesTheCounterBlock_onSLIX2Geometry() {
        let sim = Iso15693Simulator(blockCount: 80)
        XCTAssertEqual(sim.handle(command: Data([0x02, 0x22, 0x4F])), Data([0x01, 0x0F]))
        XCTAssertFalse(sim.blockLocks[79])
        // The 28-block SLIX has no counter block: block 27 locks normally.
        let slix = Iso15693Simulator()
        XCTAssertEqual(slix.handle(command: Data([0x02, 0x22, 0x1B])), Data([0x00]))
    }

    /// Re-locking a locked block is a refusal (§9.6.3.2) — and it comes back
    /// as the same generic 0F as a real failure, which is why idempotency must
    /// come from reading the security status first, not from error codes.
    func test_lockBlock_refusesRelock() {
        let sim = Iso15693Simulator()
        XCTAssertEqual(sim.handle(command: Data([0x02, 0x22, 0x03])), Data([0x00]))
        XCTAssertEqual(sim.handle(command: Data([0x02, 0x22, 0x03])), Data([0x01, 0x0F]))
    }

    func test_lockDSFID_blocksFurtherWriteDSFID() {
        let sim = Iso15693Simulator()
        _ = sim.handle(command: Data([0x02, 0x29, 0xCC]))
        _ = sim.handle(command: Data([0x02, 0x2A]))
        let response = sim.handle(command: Data([0x02, 0x29, 0xDD]))
        XCTAssertEqual(response.first, 0x01)
        XCTAssertEqual(sim.dsfid, 0xCC)
    }

    // MARK: - System information

    func test_getSystemInformation_returnsUIDAFIDSFIDAndMemorySize() {
        let sim = Iso15693Simulator()
        _ = sim.handle(command: Data([0x02, 0x27, 0x33]))
        _ = sim.handle(command: Data([0x02, 0x29, 0x44]))
        let response = sim.handle(command: Data([0x02, 0x2B]))
        XCTAssertEqual(response.first, 0x00)
        XCTAssertEqual(response[response.startIndex + 1], 0x0F, "info flags: all four fields present")
        XCTAssertEqual(response.subdata(in: (response.startIndex + 2) ..< (response.startIndex + 10)),
                       Iso15693Simulator.defaultUID)
        XCTAssertEqual(response[response.startIndex + 10], 0x44, "DSFID echoed")
        XCTAssertEqual(response[response.startIndex + 11], 0x33, "AFI echoed")
        // VICC memory size (2 bytes) then IC reference, per ISO 15693-3 §10.3.
        // First byte = number of blocks − 1 (28 → 0x1B); second byte's low 5
        // bits = block size − 1 (4-byte blocks → 0x03) → 28 × 4 = 112 B, the
        // ICODE SLIX datasheet figure. IC reference 0x01 = SLIX family.
        XCTAssertEqual(response[response.startIndex + 12], 0x1B, "memory: 28 blocks − 1")
        XCTAssertEqual(response[response.startIndex + 13], 0x03, "memory: 4-byte blocks − 1")
        XCTAssertEqual(response[response.startIndex + 14], 0x01, "IC reference (SLIX family)")
    }

    func test_getMultipleBlockSecurityStatus_returnsPerBlockLockBits() {
        let sim = Iso15693Simulator()
        _ = sim.handle(command: Data([0x02, 0x22, 0x01])) // lock block 1
        // Read security status for blocks 0..3.
        let response = sim.handle(command: Data([0x02, 0x2C, 0x00, 0x03]))
        XCTAssertEqual(response, Data([0x00, 0x00, 0x01, 0x00, 0x00]))
    }

    // MARK: - SLIX manufacturer commands

    /// `SET_PASSWORD` **authenticates**; it never assigns. Every delivered IC
    /// has all five passwords defined (§9.2.3), so there is no value the chip
    /// will simply accept and store — which is what this test used to assert.
    func test_setPassword_comparesAgainstTheFactoryValue() {
        let sim = Iso15693Simulator()
        let mask = Data([0xC0, 0xDE, 0xC0, 0xDE])
        // Privacy ships as 0F 0F 0F 0F.
        _ = sim.handle(command: Data([0x02, 0xB2]))
        let correct = sim.handle(
            command: Data([0x02, 0xB3, 0x04]) + NTAG424Crypto.xor(Data(repeating: 0x0F, count: 4), mask)
        )
        XCTAssertEqual(correct, Data([0x00]), "the factory privacy password must authenticate")

        _ = sim.handle(command: Data([0x02, 0xB2]))
        let wrong = sim.handle(
            command: Data([0x02, 0xB3, 0x04]) + NTAG424Crypto.xor(Data([0xAA, 0xBB, 0xCC, 0xDD]), mask)
        )
        XCTAssertEqual(wrong.first, 0x01, "an arbitrary value must be refused, not stored")
        XCTAssertEqual(sim.passwords[.privacy], Data(repeating: 0x0F, count: 4), "unchanged")
    }

    /// Assigning takes two commands: authenticate with the old value, then
    /// `WRITE_PASSWORD` the new one (§9.5.3.3) — both in Selected mode, which
    /// is the only mode the chip honours them in that iOS can transmit.
    func test_writePassword_assignsOnlyAfterSetPassword() {
        let sim = Iso15693Simulator()
        let mask = Data([0xC0, 0xDE, 0xC0, 0xDE])
        let newPassword = Data([0xAA, 0xBB, 0xCC, 0xDD])

        XCTAssertEqual(sim.handle(command: Data([0x02, 0x25])), Data([0x00]), "SELECT")
        // Without a prior SET_PASSWORD it is refused.
        XCTAssertEqual(sim.handle(command: Data([0x12, 0xB4, 0x02]) + newPassword).first, 0x01)

        _ = sim.handle(command: Data([0x02, 0xB2]))
        _ = sim.handle(
            command: Data([0x12, 0xB3, 0x02]) + NTAG424Crypto.xor(Data(repeating: 0x00, count: 4), mask)
        )
        XCTAssertEqual(sim.handle(command: Data([0x12, 0xB4, 0x02]) + newPassword), Data([0x00]))
        XCTAssertEqual(sim.passwords[.write], newPassword)
    }

    /// A password without `PROTECT PAGE` protects nothing (§9.5.3.6).
    func test_aWritePasswordAloneDoesNotGateWrites() {
        let sim = Iso15693Simulator()
        let mask = Data([0xC0, 0xDE, 0xC0, 0xDE])
        XCTAssertEqual(sim.handle(command: Data([0x02, 0x25])), Data([0x00]), "SELECT")
        _ = sim.handle(command: Data([0x02, 0xB2]))
        XCTAssertEqual(
            sim.handle(command: Data([0x12, 0xB3, 0x02]) + NTAG424Crypto.xor(Data(repeating: 0x00, count: 4), mask)),
            Data([0x00]), "the setup's SET_PASSWORD must actually run, or this test is vacuous"
        )
        XCTAssertEqual(
            sim.handle(command: Data([0x12, 0xB4, 0x02]) + Data([0xAA, 0xBB, 0xCC, 0xDD])),
            Data([0x00])
        )
        sim.endSession() // fresh tap: nothing presented

        XCTAssertEqual(
            sim.handle(command: Data([0x02, 0x21, 0x02, 1, 2, 3, 4])), Data([0x00]),
            "access conditions are still Public, so the write must be accepted"
        )
    }

    /// `PROTECT PAGE` is the gate, and it is reversible.
    func test_protectPage_armsAndClearsWriteProtection() {
        let sim = Iso15693Simulator()
        let mask = Data([0xC0, 0xDE, 0xC0, 0xDE])
        // Fresh tap → SELECT again (selection dies with the field), then
        // present read + write passwords, Selected-mode frames throughout.
        func selectAndAuthenticateBoth() {
            XCTAssertEqual(sim.handle(command: Data([0x02, 0x25])), Data([0x00]), "SELECT")
            for identifier in [UInt8(0x01), UInt8(0x02)] {
                _ = sim.handle(command: Data([0x02, 0xB2]))
                XCTAssertEqual(
                    sim.handle(
                        command: Data([0x12, 0xB3, identifier])
                            + NTAG424Crypto.xor(Data(repeating: 0x00, count: 4), mask)
                    ),
                    Data([0x00])
                )
            }
        }
        selectAndAuthenticateBoth()
        // Pointer 0 puts all memory in Page H; bit 5 write-protects it.
        XCTAssertEqual(sim.handle(command: Data([0x12, 0xB6, 0x00, 0x20])), Data([0x00]))
        sim.endSession()
        XCTAssertEqual(
            sim.handle(command: Data([0x02, 0x21, 0x02, 1, 2, 3, 4])).first, 0x01,
            "an unauthenticated write must now be refused"
        )

        selectAndAuthenticateBoth()
        XCTAssertEqual(sim.handle(command: Data([0x12, 0xB6, 0x00, 0x00])), Data([0x00]))
        sim.endSession()
        XCTAssertEqual(
            sim.handle(command: Data([0x02, 0x21, 0x02, 1, 2, 3, 4])), Data([0x00]),
            "clearing the access conditions must return the tag to Public"
        )
    }

    func test_enablePrivacy_silencesTheLabel_untilPasswordSubmitted() {
        // SLIX2 §9.5.3.9: ENABLE_PRIVACY = 0xBA, carries XOR'd Privacy
        // password inline. Once enabled the label "does not respond to any
        // command except GET RANDOM NUMBER and SET PASSWORD" and cannot be
        // inventoried; exit privacy by re-submitting the password via
        // SET_PASSWORD, which is one of the two it still answers.
        //
        // This asserted an `01` error frame until the simulator was corrected.
        // A privacy tag does not refuse, it says nothing, and modelling a
        // refusal made a tag look reachable in CI that no iPhone can even
        // discover: iOS only vends a tag nfcd has inventoried.
        let sim = Iso15693Simulator()
        let password = Data(repeating: 0x0F, count: 4) // factory privacy value (§9.2.3)
        let mask = Data([0xC0, 0xDE, 0xC0, 0xDE])
        // 1. Present the Privacy password (SET_PASSWORD authenticates).
        _ = sim.handle(command: Data([0x02, 0xB2]))
        _ = sim.handle(command: Data([0x02, 0xB3, 0x04]) + NTAG424Crypto.xor(password, mask))
        // 2. Refresh random for ENABLE_PRIVACY's inline XOR'd password.
        _ = sim.handle(command: Data([0x02, 0xB2]))
        let enableResponse = sim.handle(command: Data([0x02, 0xBA]) + NTAG424Crypto.xor(password, mask))
        XCTAssertEqual(enableResponse, Data([0x00]))
        XCTAssertTrue(sim.privacyMode)
        // Reads, and every other command bar the two, now draw silence.
        XCTAssertEqual(sim.handle(command: Data([0x02, 0x20, 0x00])), Data(), "a read draws no response")
        XCTAssertEqual(sim.handle(command: Data([0x02, 0x25])), Data(), "nor does SELECT")
        XCTAssertEqual(sim.handle(command: Data([0x02, 0x2B])), Data(), "nor GET_SYSTEM_INFORMATION")
        XCTAssertEqual(
            sim.handle(command: Data([0x02, 0xB2])).first, 0x00,
            "GET_RANDOM_NUMBER is one of the two commands it does answer"
        )
        // SET_PASSWORD again with the correct Privacy password clears privacy.
        _ = sim.handle(command: Data([0x02, 0xB2]))
        _ = sim.handle(command: Data([0x02, 0xB3, 0x04]) + NTAG424Crypto.xor(password, mask))
        XCTAssertFalse(sim.privacyMode)
        let unblockedRead = sim.handle(command: Data([0x02, 0x20, 0x00]))
        XCTAssertEqual(unblockedRead.first, 0x00)
    }

    func test_enablePrivacy_withWrongPassword_isRejected() {
        let sim = Iso15693Simulator()
        let mask = Data([0xC0, 0xDE, 0xC0, 0xDE])
        _ = sim.handle(command: Data([0x02, 0xB2]))
        let response = sim.handle(command: Data([0x02, 0xBA]) + NTAG424Crypto.xor(Data([0xDE, 0xAD, 0xBE, 0xEF]), mask))
        XCTAssertEqual(response.first, 0x01)
        XCTAssertFalse(sim.privacyMode)
    }

    func test_destroy_withoutDestroyPassword_isRejected() {
        // SLIX2 §9.5.3.8: DESTROY = 0xB9, carries XOR'd Destroy password
        // inline, and is honoured only in Addressed or Selected mode. With no
        // Destroy password presented this tap, DESTROY rejects regardless of
        // what the caller sends.
        let sim = Iso15693Simulator()
        XCTAssertEqual(sim.handle(command: Data([0x02, 0x25])), Data([0x00]), "SELECT")
        let response = sim.handle(command: Data([0x12, 0xB9, 0x00, 0x00, 0x00, 0x00]))
        XCTAssertEqual(response.first, 0x01)
        XCTAssertFalse(sim.destroyed)
    }

    func test_destroy_withWrongPassword_isRejected() {
        let sim = Iso15693Simulator()
        let mask = Data([0xC0, 0xDE, 0xC0, 0xDE])
        XCTAssertEqual(sim.handle(command: Data([0x02, 0x25])), Data([0x00]), "SELECT")
        _ = sim.handle(command: Data([0x02, 0xB2]))
        XCTAssertEqual(
            sim.handle(command: Data([0x12, 0xB3, 0x08]) + NTAG424Crypto.xor(Data(repeating: 0x0F, count: 4), mask)),
            Data([0x00]), "presenting the factory destroy password must succeed"
        )
        _ = sim.handle(command: Data([0x02, 0xB2]))
        let response = sim.handle(command: Data([0x12, 0xB9]) + NTAG424Crypto.xor(Data([0x00, 0x00, 0x00, 0x00]), mask))
        XCTAssertEqual(response.first, 0x01)
        XCTAssertFalse(sim.destroyed)
    }

    func test_destroy_terminatesAllSubsequentCommands() {
        let sim = Iso15693Simulator()
        let pw = Data(repeating: 0x0F, count: 4) // factory destroy value (§9.2.3)
        let mask = Data([0xC0, 0xDE, 0xC0, 0xDE])
        XCTAssertEqual(sim.handle(command: Data([0x02, 0x25])), Data([0x00]), "SELECT")
        // 1. Present the destroy password (SET_PASSWORD authenticates).
        _ = sim.handle(command: Data([0x02, 0xB2]))
        _ = sim.handle(command: Data([0x12, 0xB3, 0x08]) + NTAG424Crypto.xor(pw, mask))
        // 2. Refresh random, then DESTROY 0xB9 with XOR'd password.
        _ = sim.handle(command: Data([0x02, 0xB2]))
        let destroyResponse = sim.handle(command: Data([0x12, 0xB9]) + NTAG424Crypto.xor(pw, mask))
        XCTAssertEqual(destroyResponse, Data([0x00]))
        XCTAssertTrue(sim.destroyed)
        // Every subsequent command errors.
        let response = sim.handle(command: Data([0x02, 0x20, 0x00]))
        XCTAssertEqual(response.first, 0x01)
    }

    // MARK: - Addressing-mode enforcement (§9.5.3.2/3.3)

    /// The failure that burned six live taps on 2026-08-07: gated commands
    /// sent non-addressed draw **silence** from the chip, while this simulator
    /// answered them in any mode — so CI stayed green as silicon ignored us.
    func test_gatedCommand_nonAddressed_isIgnored() {
        let sim = Iso15693Simulator()
        let mask = Data([0xC0, 0xDE, 0xC0, 0xDE])
        _ = sim.handle(command: Data([0x02, 0xB2]))
        let setResponse = sim.handle(
            command: Data([0x02, 0xB3, 0x02]) + NTAG424Crypto.xor(Data(repeating: 0x00, count: 4), mask)
        )
        XCTAssertTrue(setResponse.isEmpty, "non-addressed SET_PASSWORD draws silence, not an answer")
        let writeResponse = sim.handle(command: Data([0x02, 0xB4, 0x02, 0xAA, 0xBB, 0xCC, 0xDD]))
        XCTAssertTrue(writeResponse.isEmpty, "non-addressed WRITE_PASSWORD draws silence")
        XCTAssertEqual(sim.passwords[.write], Data(repeating: 0x00, count: 4), "nothing was assigned")
    }

    /// A Select-flagged frame names "the tag in the Selected state" — a tag
    /// that has not been SELECTed is not the addressee and stays silent.
    func test_selectFlaggedFrame_beforeSelect_isIgnored() {
        let sim = Iso15693Simulator()
        XCTAssertTrue(sim.handle(command: Data([0x12, 0xB2])).isEmpty)
        XCTAssertEqual(sim.handle(command: Data([0x02, 0x25])), Data([0x00]), "SELECT")
        XCTAssertEqual(sim.handle(command: Data([0x12, 0xB2])).first, 0x00, "answered once selected")
    }

    /// Selection dies with the RF field: after `endSession` the tag is back in
    /// the Ready state and Select-flagged frames are ignored again.
    func test_selectedState_doesNotSurviveTheField() {
        let sim = Iso15693Simulator()
        _ = sim.handle(command: Data([0x02, 0x25]))
        XCTAssertTrue(sim.isSelected)
        sim.endSession()
        XCTAssertFalse(sim.isSelected)
        XCTAssertTrue(sim.handle(command: Data([0x12, 0xB2])).isEmpty)
    }

    /// "If the IC receives an invalid password, it will not execute any
    /// following command until a Power-On Reset" (§9.5.3.2). No flow may
    /// retry a failed password in-session — the tag must leave the field.
    func test_invalidPassword_silencesEverythingUntilPOR() {
        let sim = Iso15693Simulator()
        let mask = Data([0xC0, 0xDE, 0xC0, 0xDE])
        _ = sim.handle(command: Data([0x02, 0xB2]))
        // Privacy SET_PASSWORD is the documented non-addressed exception, so
        // it reaches the comparison — and fails.
        let wrong = sim.handle(command: Data([0x02, 0xB3, 0x04]) + NTAG424Crypto.xor(
            Data([0xAA, 0xBB, 0xCC, 0xDD]),
            mask
        ))
        XCTAssertEqual(wrong.first, 0x01)
        XCTAssertTrue(sim.poisoned)
        XCTAssertTrue(sim.handle(command: Data([0x02, 0x20, 0x00])).isEmpty, "even a plain read draws silence now")
        sim.endSession() // POR
        XCTAssertEqual(sim.handle(command: Data([0x02, 0x20, 0x00])).first, 0x00, "the RF reset lifts the lockout")
    }

    // MARK: - Higher-level ConnectedTag surface

    func test_iso15693_unformattedTag_readsAsZeroRecords() async throws {
        // A factory ICODE with no NDEF Capability Container (block 0 magic byte
        // is not 0xE1/0xE2) isn't NDEF-formatted. On a real device CoreNFC
        // surfaces this as NFCError 102 "Tag Not NDEF formatted"; the contract
        // both the simulator and the CoreNFC session honour is a clean read of
        // *zero records*, not a failure — exactly like a blank NTAG. (The real
        // path's mapping lives in `CoreNFCConnectedTag.isUnformattedNDEF`.)
        let sim = Iso15693Simulator()
        // Clobber the CC block so no valid Type-5 capability container remains.
        let cleared = sim.handle(command: Data([0x02, 0x21, 0x00, 0x00, 0x00, 0x00, 0x00]))
        XCTAssertEqual(cleared, Data([0x00]), "CC block write should succeed")
        let session = SimulatedSession(chip: sim)
        let tag = try await session.start(alert: "")
        let read = try await tag.readNDEF()
        XCTAssertTrue(read.isEmpty, "unformatted ISO 15693 reads as zero records")
        // Decode exactly as ScanFlowModel does — an empty message is zero
        // records, never a decode error that aborts the scan.
        let records = (try? NDEFCodec.decode(read)) ?? []
        XCTAssertEqual(records.count, 0)
    }

    func test_iso15693_writeNDEF_thenReadNDEF_roundTrips() async throws {
        let sim = Iso15693Simulator()
        let session = SimulatedSession(chip: sim)
        let tag = try await session.start(alert: "")
        XCTAssertEqual(tag.chip?.id, .icodeSlix)
        try await tag.writeNDEF([.uri(URIRecord(uri: "https://hex.pro"))])
        let read = try await tag.readNDEF()
        let decoded = try NDEFCodec.decode(read)
        guard case .uri(let uri) = decoded[0] else { return XCTFail("expected uri") }
        XCTAssertEqual(uri.uri, "https://hex.pro")
    }

    /// Authenticating a SLIX through the `ConnectedTag` surface, on the Type-5
    /// path that actually exists.
    ///
    /// This used to call `setPassword(_:pack:)` and `authenticate(password:)`,
    /// which are the **Type-2** PWD/PACK primitives. Production has never
    /// offered either to a SLIX: they need a `Type2ConfigLayout`, which is nil
    /// for `icodeSlix`, so a real tag answers `capabilityUnsupported`. The old
    /// form only passed because the simulator carried its own implementations,
    /// which made the simulated tag more capable than the silicon it stands in
    /// for. A SLIX gate is `SET_PASSWORD` (B3h) in Selected mode, reached with a
    /// `.type5` credential.
    func test_iso15693_authenticate_succeedsWithMatchingPassword() async throws {
        let sim = Iso15693Simulator()
        let password = Data([0x11, 0x22, 0x33, 0x44])

        // Assign a non-factory write password first, so "matching" means
        // matching a value this test chose rather than the delivery one.
        // Two frames, per SL2S2602 §9.5.3.3: SET_PASSWORD presents the value the
        // tag holds now (00 00 00 00 at delivery), WRITE_PASSWORD replaces it.
        let mask = Data([0xC0, 0xDE, 0xC0, 0xDE])
        XCTAssertEqual(sim.handle(command: Data([0x02, 0x25])), Data([0x00]), "SELECT")
        _ = sim.handle(command: Data([0x02, 0xB2]))
        XCTAssertEqual(
            sim.handle(
                command: Data([0x12, 0xB3, 0x02]) + NTAG424Crypto.xor(Data(repeating: 0x00, count: 4), mask)
            ),
            Data([0x00]), "the setup's SET_PASSWORD must actually run, or this test is vacuous"
        )
        XCTAssertEqual(sim.handle(command: Data([0x12, 0xB4, 0x02]) + password), Data([0x00]), "WRITE_PASSWORD")
        XCTAssertEqual(sim.passwords[.write], password)
        sim.endSession() // fresh tap: nothing is presented any more

        let tag = try await SimulatedSession(chip: sim).start(alert: "")
        let opening = try await tag.authenticate(.type5(password: password, kind: .write))
        XCTAssertEqual(opening.route, .authenticated)

        // …and a value the tag is not holding is refused, which is what makes
        // "matching" load-bearing. A wrong password also poisons the IC until
        // the next POR (§9.5.3.2), so the retry has to be a fresh tap.
        sim.endSession()
        do {
            _ = try await tag.authenticate(.type5(password: Data([0xDE, 0xAD, 0xBE, 0xEF]), kind: .write))
            XCTFail("a SLIX write password the tag is not holding must be refused")
        } catch is TagError {
            // Expected: SET_PASSWORD compares, and answers an error frame.
        }
    }

    func test_iso15693_permanentLock_locksEveryBlock() throws {
        let sim = Iso15693Simulator()
        try sim.permanentLock()
        let response = sim.handle(command: Data([0x02, 0x21, 0x00, 0x00, 0x00, 0x00, 0x00]))
        XCTAssertEqual(response.first, 0x01, "every block should be locked")
        XCTAssertTrue(sim.afiLocked)
        XCTAssertTrue(sim.dsfidLocked)
    }

    func test_iso15693_unknownOpcode_isRefusedWithTheGeneric0F() {
        // §9.6.2.2: "If the received command or option is not supported ... the
        // label IC responds with the error code 0Fh" — the SLIX2's only error
        // code, for this and every other refusal.
        let sim = Iso15693Simulator()
        let response = sim.handle(command: Data([0x02, 0xFF]))
        XCTAssertEqual(response, Data([0x01, 0x0F]))
    }
}
