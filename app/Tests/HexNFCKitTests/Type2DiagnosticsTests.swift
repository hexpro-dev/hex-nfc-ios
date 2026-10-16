@testable import HexNFCKit
@testable import HexNFCTagSim
import XCTest

/// The read-only silicon facts surfaced on the scan card, and (more
/// importantly) the two rules that keep collecting them from breaking the scan
/// they are attached to.
///
/// On this transport a refused command returns a Type-2 tag to HALT for the
/// rest of the activation. So an unsupported probe doesn't just fail, it kills
/// everything after it. These probes run last in the session for that reason,
/// and the reader must stop dead at the first refusal instead of talking to a
/// chip that has stopped listening.
final class Type2DiagnosticsTests: XCTestCase {
    // MARK: - Reading real chips

    /// An NTAG213 TT is the chip with the most to say: signature, counter and
    /// the tamper loop that is its whole reason for existing.
    func test_ntag213TT_reportsSignatureCounterAndIntactTamper() async {
        let chip = NTAG213TTSimulator()
        let diagnostics = await read(chip)

        XCTAssertEqual(diagnostics.originalitySignature?.count, 32)
        XCTAssertFalse(diagnostics.signatureIsShort)
        XCTAssertEqual(diagnostics.tamper, .intact, "a factory TT has an unbroken loop")
        XCTAssertNotNil(diagnostics.tapCount)
        XCTAssertFalse(diagnostics.isEmpty)
    }

    /// A broken loop latches, which is the feature. It must read as `.opened`,
    /// and the reading comes from "the reply is not four zero bytes", never from
    /// matching a specific value: a triggered TT answers the customer-programmed
    /// TT_MESSAGE, whose bytes are whoever-programmed-the-tag's to choose.
    func test_ntag213TT_reportsAnOpenedTamperLoop() async {
        let chip = NTAG213TTSimulator()
        chip.tamperStatus = 0x00 // anything but 0x55 = loop broken
        let diagnostics = await read(chip)

        XCTAssertEqual(diagnostics.tamper, .opened)
    }

    /// Ultralight EV1 has three independent counters plus a tearing check,
    /// which is a different shape from NTAG's single counter.
    func test_ultralightEV1_reportsThreeCountersAndTearingStatus() async {
        let diagnostics = await read(MifareUltralightEV1_128Simulator())

        XCTAssertEqual(diagnostics.ultralightCounters.count, 3)
        XCTAssertEqual(diagnostics.countersIntact, true, "0xBD on every counter = no tearing event")
        XCTAssertNil(diagnostics.tapCount, "the single-counter field is NTAG's, not EV1's")
    }

    /// A chip with none of the capabilities must be left completely alone: no
    /// probe is sent at all, because each one would NAK and halt it.
    func test_chipWithoutTheCapabilities_isNeverProbed() async throws {
        let spy = TransceiveSpy(replies: [:])
        let ulc = try XCTUnwrap(ChipCatalog.profile(for: .mifareUltralightC))
        let diagnostics = await Type2DiagnosticsReader(transceive: spy.send).read(chip: ulc)

        XCTAssertTrue(diagnostics.isEmpty)
        XCTAssertEqual(
            spy.sent, [],
            "Ultralight C implements none of these opcodes (rev 3.3 Table 14); sending one halts the tag"
        )
    }

    /// A Type-5 chip must not be handed Type-2 page opcodes at all.
    func test_nonType2Chip_isNeverProbed() async throws {
        let spy = TransceiveSpy(replies: [:])
        let slix = try XCTUnwrap(ChipCatalog.profile(for: .icodeSlix2))
        _ = await Type2DiagnosticsReader(transceive: spy.send).read(chip: slix)

        XCTAssertEqual(spy.sent, [])
    }

    // MARK: - Stop at the first refusal

    /// The rule that matters. A factory NTAG ships with `NFC_CNT_EN = 0` and
    /// NAKs `READ_CNT`, a legitimate state and not a fault. That NAK has already
    /// halted the tag, so nothing may be sent afterwards. The facts gathered
    /// before it must survive.
    func test_aRefusedCounterStopsTheRunAndKeepsWhatCameBefore() async throws {
        let spy = TransceiveSpy(replies: [
            0x3C: Data(repeating: 0xAB, count: 32), // signature: fine
            0x39: Data([0x00]), // counter: NAK (1-byte frame)
        ])
        let diagnostics = try await Type2DiagnosticsReader(transceive: spy.send)
            .read(chip: XCTUnwrap(ChipCatalog.profile(for: .ntag215)))

        XCTAssertEqual(diagnostics.originalitySignature?.count, 32, "the signature was already read")
        XCTAssertTrue(diagnostics.counterDisabled, "a refused READ_CNT means the counter is switched off")
        XCTAssertNil(diagnostics.tapCount)
        XCTAssertEqual(
            spy.sent, [0x3C, 0x39],
            "nothing may be sent after a NAK; the tag has halted"
        )
    }

    /// The same rule on the Ultralight EV1 branch, which has a second probe
    /// behind the counters and so a second chance to talk to a halted tag.
    ///
    /// Not a factory-state test: a factory EV1 answers all three counters with
    /// zero and all three tearing checks with `0xBD` (live MF0UL21, 2026-08-14).
    /// This covers the EV1 that *does* refuse, where the tearing check sitting
    /// after the loop must not be sent anyway.
    func test_anUltralightEV1_thatRefusesACounter_skipsTheTearingCheck() async throws {
        let spy = TransceiveSpy(replies: [
            0x3C: Data(repeating: 0xCD, count: 32), // signature: fine
            0x39: Data([0x00]), // counter 0: NAK
            0x3E: Data([0xBD]), // tearing would answer, if we got there
        ])
        let diagnostics = try await Type2DiagnosticsReader(transceive: spy.send)
            .read(chip: XCTUnwrap(ChipCatalog.profile(for: .mifareUltralightEV1_128)))

        XCTAssertEqual(diagnostics.originalitySignature?.count, 32)
        XCTAssertTrue(diagnostics.ultralightCounters.isEmpty)
        XCTAssertNil(diagnostics.countersIntact, "the tearing check is meaningless with no counter read")
        XCTAssertFalse(
            diagnostics.counterDisabled,
            "counterDisabled is NTAG's NFC_CNT_EN story; EV1 counters are a different mechanism"
        )
        XCTAssertEqual(spy.sent, [0x3C, 0x39], "the NAK halted the tag; 0x3E must never be sent")
    }

    /// Same rule one probe earlier: a chip that stubs `READ_SIG` gets no further
    /// questions.
    func test_aShortSignatureStopsTheRun() async throws {
        let spy = TransceiveSpy(replies: [
            0x3C: Data([0x01, 0x02]), // answered, but not 32 bytes
            0x39: Data([0x11, 0x22, 0x33]),
        ])
        let diagnostics = try await Type2DiagnosticsReader(transceive: spy.send)
            .read(chip: XCTUnwrap(ChipCatalog.profile(for: .ntag215)))

        XCTAssertTrue(diagnostics.signatureIsShort)
        XCTAssertNil(diagnostics.originalitySignature)
        XCTAssertNil(diagnostics.tapCount)
        XCTAssertEqual(spy.sent, [0x3C], "a chip lying about this opcode is not one to keep probing")
    }

    /// A thrown error is a refusal too: iOS surfaces a halted tag as a dropped
    /// one about as often as a protocol error, so neither may be special-cased.
    func test_aThrownErrorStopsTheRun() async throws {
        let spy = TransceiveSpy(replies: [:], throwOn: 0x3C)
        let diagnostics = try await Type2DiagnosticsReader(transceive: spy.send)
            .read(chip: XCTUnwrap(ChipCatalog.profile(for: .ntag213TT)))

        XCTAssertTrue(diagnostics.isEmpty)
        XCTAssertEqual(spy.sent, [0x3C])
    }

    /// Ordering is load-bearing: tamper is asked before the counter, because the
    /// counter is the probe that is commonly refused and reading it first would
    /// cost every NTAG213 TT the one fact that chip uniquely knows.
    func test_tamperIsReadBeforeTheCounter() async throws {
        let spy = TransceiveSpy(replies: [
            0x3C: Data(repeating: 0xAB, count: 32),
            0xA4: Data([0x00, 0x00, 0x00, 0x00]),
            0x39: Data([0x00]), // NAK, as on a factory chip
        ])
        let diagnostics = try await Type2DiagnosticsReader(transceive: spy.send)
            .read(chip: XCTUnwrap(ChipCatalog.profile(for: .ntag213TT)))

        XCTAssertEqual(diagnostics.tamper, .intact, "the tamper state survived the counter's refusal")
        XCTAssertEqual(spy.sent, [0x3C, 0xA4, 0x39])
    }

    // MARK: - A short answer is not always the gate

    /// An anomalous short frame at the Capability Container may not accuse a
    /// password.
    ///
    /// `readPages` used to map any answer of one byte or less to
    /// `TagError.readProtected` whatever page was addressed. Above AUTH0 that is
    /// right, and it is what routes a user to the unlock prompt. At page 3 it
    /// cannot be: the driver's own comment records the Capability Container as
    /// sitting below every AUTH0 this app writes, "so asking for it can never trip
    /// protection". The owner of an unprotected tag was told it "needs its
    /// password before it will show anything" on the strength of one frame.
    ///
    /// The byte replayed here is the one an NTAG213 produced on 2026-09-10, on a
    /// clean callback with no adjacent error line, answering this exact frame and
    /// throwing a protect that had not yet written a byte. `0F` is not a
    /// documented NTAG21x NAK, and neither was the `1F` a `30 29` drew on
    /// 2026-09-09. `halts: false` is a modelling choice: both captures ended their
    /// activation there, so neither shows what the chip did next. Nothing
    /// branches on either value.
    ///
    /// **One frame does not get to fail an operation here.** The read is
    /// non-mutating and spends no counted attempt, and the page sits below every
    /// AUTH0 this driver writes, so the driver asks again. The fault is armed
    /// `.first`, so the second read answers normally and the anomaly is absorbed:
    /// the caller sees a protection state, not an error.
    func test_oneShortAnswerAtTheCapabilityContainerIsRetriedRatherThanReported() async throws {
        let sim = NTAG213Simulator()
        let faults = FaultInjectingSessionFactory(chip: sim)
        faults.arm(TagFault(
            .read(page: Type2PasswordDriver.capabilityContainerPage),
            .refused(response: Data([0x0F]), halts: false)
        ))
        let tag = try await faults.makeSession().start(alert: "")

        let state = try await tag.readProtectionState()

        XCTAssertNotNil(state, "a factory NTAG213 reports a protection state; one bad frame is not a verdict")
        XCTAssertEqual(state?.passwordProtect, false, "and the tag it describes is unprotected")
    }

    /// The retry is one second look, not a loop. A page that answers short twice
    /// in the same activation is reported, and the report names both answers so a
    /// bug report carries what the tag actually said.
    ///
    /// It still may not be reported as protection: two anomalous frames are no
    /// more evidence of a password than one.
    func test_aCapabilityContainerThatAnswersShortTwiceIsReportedAndNamesBoth() async throws {
        let sim = NTAG213Simulator()
        let faults = FaultInjectingSessionFactory(chip: sim)
        faults.arm(TagFault(
            .read(page: Type2PasswordDriver.capabilityContainerPage),
            .refused(response: Data([0x1F]), halts: false),
            on: .every
        ))
        let tag = try await faults.makeSession().start(alert: "")

        do {
            _ = try await tag.readProtectionState()
            XCTFail("the read did not answer twice, so there is no protection state to report")
        } catch let error as TagError {
            guard case .malformedResponse = error.kind else {
                return XCTFail("expected .malformedResponse, got \(error.kind)")
            }
            XCTAssertNotEqual(
                String(localized: error.userMessage),
                String(localized: TagError.readProtected().userMessage),
                "this tag is not protected, and two short frames are not evidence that it is"
            )
            XCTAssertTrue(
                error.diagnostics.contains("1F"),
                "the raw byte belongs in the diagnostics, uppercase: `Data.hexString` formats %02X. "
                    + "Got: \(error.diagnostics)"
            )
            XCTAssertTrue(
                error.diagnostics.contains("asked again"),
                "the diagnostics must say a second read was taken, so a reader knows the anomaly "
                    + "persisted rather than being a single frame. Got: \(error.diagnostics)"
            )
        }
    }

    /// The negative half, so the change cannot be widened by accident.
    ///
    /// At a configuration page a short answer really is the gate: those pages sit
    /// above AUTH0. This is the case that must keep reaching `.readProtected`,
    /// because its kind is what `ScanFlowModel.isLikelyProtectionFailure` matches
    /// and what puts the unlock prompt on screen.
    func test_aShortAnswerAtAConfigurationPageIsStillTheGate() async throws {
        let layout = try XCTUnwrap(Type2ConfigLayout.for(.ntag213))
        let sim = NTAG213Simulator()
        let faults = FaultInjectingSessionFactory(chip: sim)
        faults.arm(TagFault(
            .read(page: layout.config0Page),
            .refused(response: Data([0x00]), halts: false)
        ))
        let tag = try await faults.makeSession().start(alert: "")

        do {
            _ = try await tag.readProtectionState()
            XCTFail("the configuration read was refused")
        } catch let error as TagError {
            XCTAssertEqual(
                String(localized: error.userMessage),
                String(localized: TagError.readProtected().userMessage),
                "a refusal above AUTH0 is the gate answering, and the user needs the unlock prompt"
            )
        }
    }

    // MARK: - Helpers

    private func read(_ chip: ChipSimulator) async -> TagDiagnostics {
        guard let tag = try? await SimulatedSession(chip: chip).start(alert: "") else {
            XCTFail("simulated session should start")
            return TagDiagnostics()
        }
        let reader = Type2DiagnosticsReader(transceive: { try await tag.transceive($0) })
        return await reader.read(chip: tag.chip)
    }
}

/// Records every opcode sent and answers from a fixed table, so a test can
/// assert on what was *not* sent, which is the whole point when an extra frame
/// is the bug.
private final class TransceiveSpy: @unchecked Sendable {
    private(set) var sent: [UInt8] = []
    private let replies: [UInt8: Data]
    private let throwOn: UInt8?

    init(replies: [UInt8: Data], throwOn: UInt8? = nil) {
        self.replies = replies
        self.throwOn = throwOn
    }

    @Sendable
    func send(_ command: RawCommand) async throws -> Data {
        let opcode = command.bytes.first ?? 0
        sent.append(opcode)
        if opcode == throwOn {
            throw TagError.tagLost(diagnostics: "spy")
        }
        // An unlisted opcode answers a bare NAK, exactly like real silicon.
        return replies[opcode] ?? Data([0x00])
    }
}
