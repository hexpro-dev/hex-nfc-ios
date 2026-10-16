import Foundation
@testable import HexNFCKit
@testable import HexNFCRecords
@testable import HexNFCTagSim
import XCTest

/// The fault-injection seam's own oracle.
///
/// Everything else that arms a fault reads its verdict through a flow model or a
/// driver, so if the seam quietly did the wrong thing those tests would keep
/// passing and prove something other than what they claim. So the seam is
/// asserted here directly: that a lost ACK really reaches the chip, that a
/// refusal really ends the activation where a dropped frame does not, that the
/// occurrence counter counts matches, and that the decorator does not shadow a
/// single credential method.
final class FaultInjectionTests: XCTestCase {
    /// Type-2 opcodes, spelled out because they are opcodes rather than page
    /// numbers. Every *page* number in this file comes from `ChipMemoryLayout`
    /// or `Type2ConfigLayout`.
    private let write: UInt8 = 0xA2
    private let read: UInt8 = 0x30
    private let ack = Data([0x0A])
    private let nak = Data([0x00])

    // MARK: - The lost ACK

    /// The effect nothing in this repo could model before, and the reason the
    /// seam exists: **the tag applies the write and the answer never arrives.**
    ///
    /// Three assertions, because if any one of them is wrong every torn-write
    /// test built on this effect is worthless: the caller is told the tag was
    /// lost, the chip's memory really moved, and the chip is *not* halted,
    /// because it answered and the reader missed it.
    func test_lostACK_appliesTheWriteAndHidesTheAnswer() async throws {
        let sim = NTAG213Simulator()
        let userPage = try XCTUnwrap(sim.profile?.memoryLayout.ndefRange).lowerBound
        let faults = FaultInjectingSessionFactory(chip: sim)
        faults.arm(TagFault(.write(page: userPage), .lostACK))
        let tag = try await faults.makeSession().start(alert: "")

        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let frame = Data([write, UInt8(userPage)]) + payload
        XCTAssertNotEqual(try sim.readMemory(range: byteRange(ofPage: userPage)), payload)

        await assertLost { _ = try await tag.transceive(RawCommand(bytes: frame, name: "WRITE")) }

        XCTAssertEqual(
            try sim.readMemory(range: byteRange(ofPage: userPage)), payload,
            "the frame reached the chip and the chip applied it: that is the whole point"
        )

        // Asserted on the seam's own record rather than inferred from the read
        // above, so a test that later drives this through a driver can say the
        // write landed instead of guessing it did.
        let swallowed = try XCTUnwrap(faults.report.swallowed.first)
        XCTAssertEqual(swallowed.request, frame)
        XCTAssertEqual(swallowed.hiddenResponse, ack, "the chip ACKed; the seam threw the ACK away")
        XCTAssertNil(swallowed.response, "and the caller saw nothing")

        XCTAssertFalse(sim.isHalted, "a lost answer is not a refusal, so nothing halted")
        let readBack = try await tag.transceive(RawCommand(bytes: Data([read, UInt8(userPage)])))
        XCTAssertEqual(readBack.count, 16, "the tag is still there and still answering")
    }

    // MARK: - Refusal versus silence

    /// The distinction the two effects exist for. A NAK is the tag refusing, and
    /// on Type-2 a refusal returns the chip to HALT for the rest of the
    /// activation. A dropped frame is the tag not answering, so the tag is still
    /// there for the retry.
    ///
    /// The HALT is delivered as the chip's own `50` frame rather than by reaching
    /// into the simulator, so it is the simulator's halt modelling that decides
    /// what happens next, not the seam's opinion of it.
    func test_refusedWithHalt_endsTheActivation_butDroppedDoesNot() async throws {
        let refusing = NTAG213Simulator()
        let userPage = try XCTUnwrap(refusing.profile?.memoryLayout.ndefRange).lowerBound
        let payload = Data([0x01, 0x02, 0x03, 0x04])
        let frame = Data([write, UInt8(userPage)]) + payload

        let refusals = FaultInjectingSessionFactory(chip: refusing)
        refusals.arm(TagFault(.write(page: userPage), .type2NAK))
        let refusedTag = try await refusals.makeSession().start(alert: "")

        let answer = try await refusedTag.transceive(RawCommand(bytes: frame, name: "WRITE"))
        XCTAssertEqual(answer, nak, "the caller states the refusal bytes and the caller sees them")
        XCTAssertTrue(refusing.isHalted, "a Type-2 NAK returns the chip to HALT")
        do {
            _ = try await refusedTag.transceive(RawCommand(bytes: Data([read, UInt8(userPage)])))
            XCTFail("a halted chip answers nothing for the rest of the activation")
        } catch let error as TagError {
            // Silence, not a second refusal: every frame the 2026-09-10 trace
            // shows after a refusal drew "Tag connection lost", and none a byte.
            XCTAssertEqual(error.kind, .tagLost)
        }
        // A halted chip answers nothing at all, memory helpers included, so the
        // read-back needs the re-activation a real re-tap would give it.
        refusing.wakeUp()
        XCTAssertNotEqual(
            try refusing.readMemory(range: byteRange(ofPage: userPage)), payload,
            "a refused write never reached the chip"
        )

        // The HALT is the seam's own frame, not the driver's, so it stays out of
        // the log a caller reads to check what was sent.
        XCTAssertFalse(
            refusals.report.contains(.opcode(0x50)),
            "the injected HALT must not read as a frame the caller sent"
        )
        XCTAssertTrue(refusals.report.allFrames.contains { $0.request == Data([0x50]) })

        let dropping = NTAG213Simulator()
        let drops = FaultInjectingSessionFactory(chip: dropping)
        drops.arm(TagFault(.write(page: userPage), .dropped))
        let droppedTag = try await drops.makeSession().start(alert: "")

        await assertLost { _ = try await droppedTag.transceive(RawCommand(bytes: frame, name: "WRITE")) }
        XCTAssertFalse(dropping.isHalted, "nothing was refused, so nothing halted")
        let afterDrop = try await droppedTag.transceive(RawCommand(bytes: Data([read, UInt8(userPage)])))
        XCTAssertEqual(
            afterDrop.count, 16,
            "the tag is still available for the retry, which is the premise of every dropped-frame test"
        )
        XCTAssertNotEqual(
            try dropping.readMemory(range: byteRange(ofPage: userPage)), payload,
            "a dropped frame never reached the chip either"
        )
    }

    // MARK: - Occurrence

    /// A fault that can only fire on the first match cannot model a credential
    /// sequence, where the same opcode addresses four pages in a row and one of
    /// them tears. `.nth` counts matches, and the log records the outcome of each
    /// one in order, so the counter is observable rather than inferred.
    func test_occurrence_firesOnTheNthMatchNotTheFirst() async throws {
        let sim = NTAG213Simulator()
        let userPage = try XCTUnwrap(sim.profile?.memoryLayout.ndefRange).lowerBound
        // Dropped rather than refused, so the chip stays awake for all three.
        let third = FaultInjectingSessionFactory(chip: sim)
        third.arm(TagFault(.write(page: userPage), .dropped, on: .nth(3)))
        let tag = try await third.makeSession().start(alert: "")

        for value in UInt8(1) ... 3 {
            let frame = Data([write, UInt8(userPage)]) + Data(repeating: value, count: 4)
            _ = try? await tag.transceive(RawCommand(bytes: frame))
        }

        XCTAssertEqual(third.report.outcomes, [.delivered, .delivered, .dropped])
        XCTAssertEqual(
            try sim.readMemory(range: byteRange(ofPage: userPage)), Data(repeating: 2, count: 4),
            "the second write is the last one the chip saw"
        )

        let all = FaultInjectingSessionFactory(chip: NTAG213Simulator())
        all.arm(TagFault(.write(page: userPage), .dropped, on: .every))
        let everyTag = try await all.makeSession().start(alert: "")
        for value in UInt8(1) ... 3 {
            let frame = Data([write, UInt8(userPage)]) + Data(repeating: value, count: 4)
            _ = try? await everyTag.transceive(RawCommand(bytes: frame))
        }
        XCTAssertEqual(all.report.outcomes, [.dropped, .dropped, .dropped])
    }

    // MARK: - Absence

    /// A tag that left the field is gone from **every** entry point, including
    /// the three that reach the chip without putting a frame on the wire.
    ///
    /// This is why absence is a state of the tag rather than an effect on a
    /// frame. Both the write and the scan flow take
    /// `ProtectionProbe.presence(of:)` first, which goes through `readMemory`; a
    /// tag whose absence only began at the next `transceive` would have answered
    /// that probe, and the flow would already have recorded it as present. The
    /// tag would then be reported as *protected* rather than lost, which is the
    /// 2026-08-14 bug in the direction that harms the user.
    func test_anAbsentTagIsGoneFromEveryEntryPoint_fromTheMomentItIsArmed() async throws {
        let sim = NTAG213Simulator()
        let ccPage = try XCTUnwrap(sim.profile?.memoryLayout.ccPage)
        let faults = FaultInjectingSessionFactory(chip: sim)
        faults.tagLeavesTheField()
        let tag = try await faults.makeSession().start(alert: "")

        // It identified first. This is a tag lifted off the phone, not one that
        // never arrived.
        XCTAssertEqual(tag.uid, sim.uid)
        XCTAssertEqual(tag.chip?.id, .ntag213)

        await assertLost { _ = try await tag.readMemory(range: byteRange(ofPage: ccPage)) }
        await assertLost { try await tag.writeMemory(at: ccPage * 4, bytes: Data(repeating: 0, count: 4)) }
        await assertLost { _ = try await tag.readNDEF() }
        await assertLost { try await tag.writeNDEF([]) }
        await assertLost { _ = try await tag.transceive(RawCommand(bytes: Data([read, UInt8(ccPage)]))) }
        await assertLost { _ = try await tag.readProtectionState() }
    }

    // MARK: - What the decorator must not declare

    /// The one mistake this decorator can make.
    ///
    /// `enableProtection`, `disableProtection`, `authenticate`, `permanentLock`
    /// and `readProtectionState` are `ConnectedTag` extension defaults that build
    /// their driver from `self.transceive`. A `FaultInjectingTag` that declared
    /// any of them would point that driver at the *inner* tag, so every armed
    /// fault would be bypassed without a word and every test built on the seam
    /// would pass while injecting nothing at all.
    ///
    /// So drive each of them with nothing armed and require that each put frames
    /// through the seam. A shadowed method leaves the log empty.
    func test_faultInjectingTag_doesNotShadowAnyCredentialMethod() async throws {
        let sim = NTAG213Simulator()
        let layout = try XCTUnwrap(sim.profile?.type2ConfigLayout)
        let firstDataPage = try XCTUnwrap(sim.profile?.memoryLayout.ndefRange).lowerBound
        let password = Data([0xA1, 0xB2, 0xC3, 0xD4])
        let pack = Data([0x56, 0x78])
        let faults = FaultInjectingSessionFactory(chip: sim)
        let tag = try await faults.makeSession().start(alert: "")

        _ = try await tag.readProtectionState()
        XCTAssertTrue(
            faults.report.contains(.read(page: layout.config0Page)),
            "readProtectionState must read the config page over the seam"
        )

        faults.resetLog()
        _ = try await tag.enableProtection(
            .type2(
                password: password, pack: pack, protectFromPage: firstDataPage,
                readProtect: false, authLimit: 0
            ),
            replacing: nil
        )
        XCTAssertTrue(faults.report.contains(.write(page: layout.pwdPage)), "the credential write")
        XCTAssertTrue(faults.report.contains(.write(page: layout.config0Page)), "and AUTH0, last")

        faults.resetLog()
        let opening = try await tag.authenticate(.type2(password: password, pack: pack))
        XCTAssertEqual(opening.route, .authenticated)
        XCTAssertTrue(faults.report.contains(.opcode(0x1B)), "PWD_AUTH must go over the seam")

        faults.resetLog()
        _ = try await tag.disableProtection(using: .type2(password: password, pack: pack))
        XCTAssertTrue(faults.report.contains(.write(page: layout.config0Page)), "the gate comes down over the seam")

        // A permanent lock is irreversible, so it gets its own chip.
        let lockable = NTAG213Simulator()
        let lockLayout = try XCTUnwrap(lockable.profile?.memoryLayout)
        let lockFaults = FaultInjectingSessionFactory(chip: lockable)
        let lockTag = try await lockFaults.makeSession().start(alert: "")
        _ = try await lockTag.permanentLock()
        let dynamicLockPage = try XCTUnwrap(lockLayout.dynamicLockPage)
        XCTAssertTrue(
            lockFaults.report.contains(.write(page: dynamicLockPage)),
            "the lock driver's frames must go over the seam too"
        )
    }

    /// The mirror of the rule above. The three session holders are protocol
    /// requirements with extension defaults that hand back a fresh throwaway on
    /// every access, so a decorator that let them default would forget an
    /// Ultralight C handshake the wrapped tag remembers, and a second
    /// `AUTHENTICATE` in one activation would be attempted. The card refuses
    /// that, and the refusal halts a Type-2 chip.
    func test_sessionHoldersAreForwarded_soASecondUltralightCAuthIsNeverAttempted() async throws {
        let sim = MifareUltralightCSimulator()
        let faults = FaultInjectingSessionFactory(chip: sim)
        let tag = try await faults.makeSession().start(alert: "")

        let first = try await tag.authenticate(.ultralightC(key: .factoryDefault))
        XCTAssertEqual(first.route, .authenticated)
        XCTAssertTrue(tag.ultralightCSession.isAuthenticated, "the holder is the wrapped tag's, not a throwaway")

        let second = try await tag.authenticate(.ultralightC(key: .factoryDefault))
        XCTAssertEqual(second.route, .alreadyOpen, "the reader remembers, because the card cannot be asked")
        XCTAssertEqual(sim.successfulAuthentications, 1, "exactly one handshake per activation")
    }

    // MARK: - What the log may print

    /// The frame log holds raw bytes because that is what a test asserts against,
    /// and on a credential frame those bytes *are* the credential.
    /// `redactedDescription` is the only printable form, and it applies the same
    /// rule `CoreNFCSession.isSecretFrame` applies to the live trace: the page
    /// number survives, the payload does not, and on a `PWD_AUTH` not even the
    /// first parameter byte survives, because there it is the password.
    func test_frameLogRedactsCredentialPayloads() async throws {
        let sim = NTAG213Simulator()
        let layout = try XCTUnwrap(sim.profile?.type2ConfigLayout)
        let password = Data([0xA1, 0xB2, 0xC3, 0xD4])
        let faults = FaultInjectingSessionFactory(chip: sim)
        let tag = try await faults.makeSession().start(alert: "")

        _ = try await tag.setPassword(password, pack: Data([0x56, 0x78]))
        let credentialWrite = try XCTUnwrap(faults.report.frames(matching: .write(page: layout.pwdPage)).first)
        XCTAssertEqual(
            credentialWrite.redactedDescription,
            String(format: "A2 %02X ..", layout.pwdPage),
            "the opcode and the page, and nothing of the payload"
        )

        faults.resetLog()
        _ = try? await tag.authenticate(password: password)
        let pwdAuth = try XCTUnwrap(faults.report.frames(matching: .opcode(0x1B)).first)
        XCTAssertEqual(
            pwdAuth.redactedDescription, "1B ..",
            "PWD_AUTH's first parameter byte is a password byte, so it goes too"
        )
        for byte in password {
            XCTAssertFalse(
                pwdAuth.redactedDescription.contains(String(format: "%02X", byte)),
                "no password byte may reach a printable form"
            )
        }

        // The Ultralight C key goes out in the clear (the chip has no secure
        // channel for key programming), so a key-page write is redacted the same
        // way and for the same reason.
        let ulc = MifareUltralightCSimulator()
        let keyPage = UltralightCLayout.keyPages.lowerBound
        let ulcFaults = FaultInjectingSessionFactory(chip: ulc)
        let ulcTag = try await ulcFaults.makeSession().start(alert: "")
        _ = try? await ulcTag.transceive(
            RawCommand(bytes: Data([write, UInt8(keyPage)]) + Data(repeating: 0xAB, count: 4))
        )
        let keyWrite = try XCTUnwrap(ulcFaults.report.frames(matching: .write(page: keyPage)).first)
        XCTAssertEqual(keyWrite.redactedDescription, String(format: "A2 %02X ..", keyPage))
        XCTAssertFalse(keyWrite.redactedDescription.contains("AB"))
    }

    // MARK: - Taps

    /// Sessions come off the same chip, so state carries across taps exactly as
    /// it does on one physical tag, and each frame records which tap it belonged
    /// to. That is what a cross-tap assertion is built on.
    func test_framesAreTaggedWithTheirTap_andTheChipCarriesAcrossThem() async throws {
        let sim = NTAG213Simulator()
        let userPage = try XCTUnwrap(sim.profile?.memoryLayout.ndefRange).lowerBound
        let payload = Data([0x11, 0x22, 0x33, 0x44])
        let faults = FaultInjectingSessionFactory(chip: sim)

        let firstTap = try await faults.makeSession().start(alert: "")
        _ = try await firstTap.transceive(RawCommand(bytes: Data([write, UInt8(userPage)]) + payload))

        let secondTap = try await faults.makeSession().start(alert: "")
        let readBack = try await secondTap.transceive(RawCommand(bytes: Data([read, UInt8(userPage)])))

        XCTAssertEqual(readBack.prefix(4), payload, "the same chip answered both taps")
        XCTAssertEqual(faults.tapCount, 2)
        XCTAssertEqual(faults.report.taps, 2)
        XCTAssertEqual(faults.report.frames(inTap: 1).count, 1)
        XCTAssertEqual(faults.report.frames(inTap: 2).count, 1)
        XCTAssertFalse(faults.report.didFire, "nothing was armed, so nothing fired")
    }

    // MARK: - Helpers

    private func byteRange(ofPage page: Int) -> Range<Int> {
        (page * 4) ..< (page * 4 + 4)
    }

    private func assertLost(
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("the tag was supposed to be unreachable", file: file, line: line)
        } catch let error as TagError {
            XCTAssertEqual(error.kind, .tagLost, file: file, line: line)
        } catch {
            XCTFail("expected TagError.tagLost, got \(error)", file: file, line: line)
        }
    }
}
