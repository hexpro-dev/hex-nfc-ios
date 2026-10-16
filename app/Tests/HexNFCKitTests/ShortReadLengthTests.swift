@testable import HexNFCKit
@testable import HexNFCTagSim
import XCTest

/// A READ answered short is judged against the sixteen bytes it asked for.
///
/// Bench finding 21, 2026-09-10 11:43:31, tag B `04:8F:DB:3A:D6:1F:90`, Operations
/// > Remove password (`docs/internal/bench-traces/2026-09-10-t2-1-ntag213.log`):
///
///     -> READ p3   30:03
///     <- E1:10:12:00:03:00:FE:00:34:03:00:FE:00:00:00:00
///     -> READ p41  30:29
///     <- E4:0B
///
/// Two bytes, where sixteen were asked for. `readPages` asked "was that a NAK?"
/// by checking for more than one byte, so the answer passed as data and the
/// removal failed in `readState`'s length guard on "config block read returned 2B, need 8".
/// The phone was running `c1de5da`, which had no retry in `readPages`, so the capture
/// shows the anomaly and nothing after it: the session ended there.
///
/// These tests model that answer rather than replay a sequence silicon produced.
/// No trace shows what a second READ draws after one of these anomalies, because
/// every capture of one ended its activation. `E4:0B` is replayed as bytes and
/// nothing branches on its value.
final class ShortReadLengthTests: XCTestCase {
    private let onTag = Data([0xA1, 0xB2, 0xC3, 0xD4])
    private let pack = Data([0x56, 0x78])
    private let anomaly = Data([0xE4, 0x0B])

    private var layout: Type2ConfigLayout {
        get throws {
            try XCTUnwrap(Type2ConfigLayout.for(.ntag213))
        }
    }

    private func armed(readProtect: Bool = false) throws -> NTAG213Simulator {
        let sim = NTAG213Simulator()
        try sim.enablePasswordProtection(
            password: onTag, pack: pack, protectFromPage: 4, readProtect: readProtect, authLimit: 0
        )
        sim.beginActivation()
        return sim
    }

    private func frames(_ report: TagFaultReport, before opcode: UInt8) -> [TagFaultFrame] {
        guard let index = report.frames.firstIndex(where: { $0.request.first == opcode }) else {
            return report.frames
        }
        return Array(report.frames[..<index])
    }

    // MARK: - The finding

    /// The removal the operator ran, with the anomaly on its opening state read.
    ///
    /// The driver asks again, the second READ answers normally, and the removal
    /// completes. The password is presented only after the sixteen-byte answer,
    /// because state comes first.
    func test_twoBytesAtTheConfigurationPageAreAskedAgainAndTheRemovalCompletes() async throws {
        let sim = try armed()
        let faults = FaultInjectingSessionFactory(chip: sim)
        let configRead = try FrameMatcher.read(page: layout.config0Page)
        faults.arm(TagFault(configRead, .refused(response: anomaly, halts: false), on: .first))
        let tag = try await faults.makeSession().start(alert: "")

        let residue = try await tag.disableProtection(using: .type2(password: onTag, pack: pack))

        XCTAssertEqual(residue.gate, .provenOpen)
        XCTAssertTrue(residue.metItsGoal)
        let report = faults.report
        XCTAssertEqual(report.frames(matching: .opcode(Type2PasswordDriver.pwdAuth)).count, 1)
        XCTAssertEqual(
            frames(report, before: Type2PasswordDriver.pwdAuth).filter { configRead.matches($0.request) }.count, 2,
            "the short answer and the retry, both before the password goes out"
        )
        XCTAssertEqual(
            report.frames(matching: configRead).count, 3,
            "and the removal's own read-back of the gate, after it"
        )
    }

    /// Asked twice and short twice: malformed, and nothing is sent.
    ///
    /// Not `readProtected`, which carries `.authFailed` and would reach the unlock
    /// prompt's accusation, and not any claim about the tag.
    func test_twoBytesTwiceAtTheConfigurationPageAreMalformedAndNothingIsWritten() async throws {
        let sim = try armed()
        let faults = FaultInjectingSessionFactory(chip: sim)
        try faults.arm(TagFault(.read(page: layout.config0Page), .refused(response: anomaly, halts: false), on: .every))
        let tag = try await faults.makeSession().start(alert: "")

        do {
            _ = try await tag.disableProtection(using: .type2(password: onTag, pack: pack))
            XCTFail("two short answers establish no state, so there is nothing to act on")
        } catch let error as TagError {
            guard case .malformedResponse = error.kind else {
                return XCTFail("expected .malformedResponse, got \(error.kind)")
            }
            XCTAssertNotEqual(
                String(localized: error.userMessage),
                String(localized: TagError.readProtected().userMessage)
            )
            XCTAssertTrue(error.diagnostics.contains("E4:0B"), "Got: \(error.diagnostics)")
            XCTAssertTrue(error.diagnostics.contains("of 16"), "name the length asked for. Got: \(error.diagnostics)")
            XCTAssertTrue(error.diagnostics.contains("asked again"), "Got: \(error.diagnostics)")
        }
        XCTAssertFalse(faults.report.contains(.opcode(Type2PasswordDriver.pwdAuth)), "no password was presented")
        XCTAssertFalse(faults.report.contains(.opcode(0xA2)), "and nothing was written")
    }

    /// A short answer followed by a one-byte answer is still not the gate.
    ///
    /// The first answer already showed the frame was not refused, and nothing
    /// changes what a page gates between two READs. Filing `readProtected` here
    /// would put "That password didn't unlock the tag" on screen for a password
    /// that never left the phone.
    func test_twoBytesThenOneAtAGatedPageIsNotReportedAsTheGate() async throws {
        let sim = try armed()
        let faults = FaultInjectingSessionFactory(chip: sim)
        let configRead = try FrameMatcher.read(page: layout.config0Page)
        // `.nth(2)` is armed first. The seam stops counting at the first fault
        // that fires, so a `.first` armed ahead of it would hide match 1 from it.
        faults.arm(
            TagFault(configRead, .refused(response: Data([0x00]), halts: false), on: .nth(2)),
            TagFault(configRead, .refused(response: anomaly, halts: false), on: .first)
        )
        let tag = try await faults.makeSession().start(alert: "")

        do {
            _ = try await tag.readProtectionState()
            XCTFail("neither answer was sixteen bytes")
        } catch let error as TagError {
            guard case .malformedResponse = error.kind else {
                return XCTFail("expected .malformedResponse, got \(error.kind)")
            }
        }
    }

    /// If the retry itself is lost, the kind is the loss and the anomaly that
    /// prompted the retry stays in the report.
    func test_aLostRetryReportsTheLossAndKeepsTheFirstAnswer() async throws {
        let sim = try armed()
        let faults = FaultInjectingSessionFactory(chip: sim)
        let configRead = try FrameMatcher.read(page: layout.config0Page)
        faults.arm(
            TagFault(configRead, .dropped, on: .nth(2)),
            TagFault(configRead, .refused(response: anomaly, halts: false), on: .first)
        )
        let tag = try await faults.makeSession().start(alert: "")

        do {
            _ = try await tag.disableProtection(using: .type2(password: onTag, pack: pack))
            XCTFail("the state was never read")
        } catch let error as TagError {
            XCTAssertEqual(error.kind, .tagLost)
            XCTAssertTrue(error.diagnostics.contains("E4:0B"), "Got: \(error.diagnostics)")
        }
        XCTAssertFalse(faults.report.contains(.opcode(Type2PasswordDriver.pwdAuth)))
        XCTAssertFalse(faults.report.contains(.opcode(0xA2)))
    }

    // MARK: - At the Capability Container

    /// The roll-over check needs the whole frame.
    ///
    /// A short `30 03` used to pass as "not rolled over", so `readState` went on
    /// to address the configuration pages of a tag that gates them, the chip
    /// refused and halted, and the owner, having just typed their password, was
    /// told the tag needs its password. Asking again sees the roll-over, and the
    /// removal takes the read-protected route it should have taken. The bytes are
    /// the 11:43:31 answer moved to page 3 to test length handling; no capture
    /// shows a two-byte answer there.
    func test_aShortAnswerAtTheCapabilityContainerIsAskedAgainBeforeTheRolloverIsJudged() async throws {
        let sim = try armed(readProtect: true)
        let faults = FaultInjectingSessionFactory(chip: sim)
        let ccRead = FrameMatcher.read(page: Type2PasswordDriver.capabilityContainerPage)
        faults.arm(TagFault(ccRead, .refused(response: anomaly, halts: false), on: .first))
        let tag = try await faults.makeSession().start(alert: "")

        let residue = try await tag.disableProtection(using: .type2(password: onTag, pack: pack))

        XCTAssertEqual(residue.gate, .provenOpen)
        let beforePassword = frames(faults.report, before: Type2PasswordDriver.pwdAuth)
        XCTAssertEqual(beforePassword.filter { ccRead.matches($0.request) }.count, 2)
        XCTAssertFalse(
            try beforePassword.contains { try FrameMatcher.read(page: layout.config0Page).matches($0.request) },
            "a gated configuration page is never addressed before the password"
        )
    }

    // MARK: - What did not change

    /// A one-byte refusal at a gated page is still the gate, and it still gets
    /// exactly one frame: a real refusal halts the chip, and a second READ would
    /// only turn a correct verdict into a lost tag.
    func test_aOneByteRefusalAtAGatedPageIsStillTheGateWithNoSecondRead() async throws {
        let sim = NTAG213Simulator()
        let faults = FaultInjectingSessionFactory(chip: sim)
        let configRead = try FrameMatcher.read(page: layout.config0Page)
        faults.arm(TagFault(configRead, .type2NAK))
        let tag = try await faults.makeSession().start(alert: "")

        do {
            _ = try await tag.readProtectionState()
            XCTFail("the configuration read was refused")
        } catch let error as TagError {
            XCTAssertEqual(
                String(localized: error.userMessage),
                String(localized: TagError.readProtected().userMessage)
            )
        }
        XCTAssertEqual(faults.report.frames(matching: configRead).count, 1)
    }

    /// The 2026-09-09 `1F`, on the frame it actually answered.
    ///
    /// ACCESS and AUTH0 had been written and ACKed, and the removal's read-back of
    /// the gate, `30 29`, drew one byte (`bench-traces/2026-09-09-t2-3-x-2-ntag213.log`,
    /// 13:24:10). Earlier records put it on `30 03`. One byte at a gated page is
    /// still read as a refusal, so this is absorbed by `disable`'s own second
    /// read-back, not by `readPages`.
    func test_theOneByteAnswerAtTheRemovalsReadBackIsAbsorbedByTheSecondReadBack() async throws {
        let sim = try armed()
        let faults = FaultInjectingSessionFactory(chip: sim)
        try faults.arm(TagFault(
            .read(page: layout.config0Page), .refused(response: Data([0x1F]), halts: false), on: .nth(2)
        ))
        let tag = try await faults.makeSession().start(alert: "")

        let residue = try await tag.disableProtection(using: .type2(password: onTag, pack: pack))

        XCTAssertEqual(residue.gate, .provenOpen)
        XCTAssertEqual(residue.credential, .factoryDefault)
        XCTAssertEqual(
            faults.report.frames(matching: .read(page: Type2PasswordDriver.capabilityContainerPage)).count, 3,
            "the state read, the read-back, and the read-back's follow-up: `disable` absorbed the byte, "
                + "not a second READ inside `readPages`"
        )
    }

    /// The read-back stays short: the gate is unproven and the credential is not
    /// touched. Two retries deep, this is where a wrong answer would cost most.
    func test_aReadBackThatStaysShortLeavesTheCredentialAlone() async throws {
        let sim = try armed()
        let faults = FaultInjectingSessionFactory(chip: sim)
        try faults.arm(TagFault(
            .read(page: layout.config0Page), .refused(response: anomaly, halts: false), on: .fromNth(2)
        ))
        let tag = try await faults.makeSession().start(alert: "")

        do {
            _ = try await tag.disableProtection(using: .type2(password: onTag, pack: pack))
            XCTFail("the gate was never read back")
        } catch let error as TagError {
            guard case .protectionIncomplete(let residue) = error.kind else {
                return XCTFail("expected protectionIncomplete, got \(error.kind)")
            }
            XCTAssertNotEqual(residue.gate, .provenOpen)
            XCTAssertEqual(residue.credential, .unchanged)
        }
        let layout = try layout
        XCTAssertFalse(faults.report.contains(.write(page: layout.pwdPage)), "PWD untouched")
        XCTAssertFalse(faults.report.contains(.write(page: layout.packPage)), "PACK untouched")
    }
}
