@testable import HexNFCApp
@testable import HexNFCKit
@testable import HexNFCRecords
@testable import HexNFCTagSim
import XCTest

/// The two ways an unlock attempt can fail, and the single thing that separates
/// them: whether the password may be accused.
///
/// `TagError` keeps them apart on purpose. `.authFailed` is a refusal the chip
/// stated, in a payload it actually returned. `.authInconclusive` is the frame
/// not completing, and on a Type-2 tag those two look identical from the reader:
/// a wrong password NAKs, the NAK returns the chip to HALT for the rest of the
/// activation, and CoreNFC reports the whole session gone.
///
/// Which of the two a phone produces for a wrong password is still not settled
/// in this repo. Both captures taken so far are the transport form, and the
/// payload form has no live capture at all. That is exactly why the flow may not
/// branch on the kind to decide whether a tag is still protected, and why the
/// only thing the kind decides here is whether the prompt comes back accusing
/// the credential.
///
/// Lifted out of `HexNFCAppTests` when the pair was written, both because that
/// class had reached its length limit and because these two only make sense read
/// together.
final class ScanUnlockRefusalTests: XCTestCase {
    @MainActor
    func test_scanFlow_readProtectedTag_wrongPassword_staysLockedWithFailure() async throws {
        let message = try NDEFCodec.encode([NDEFRecord.uri(URIRecord(uri: "https://hex.pro"))])
        let factory = SimulatedSessionFactory(makeChip: {
            let sim = NTAG215Simulator(ndefMessage: message)
            try? sim.enablePasswordProtection(
                password: Data([0xCA, 0xFE, 0xBA, 0xBE]), pack: Data([0x12, 0x34]),
                protectFromPage: 4, readProtect: true, authLimit: 0
            )
            return sim
        })
        let model = ScanFlowModel(factory: factory)
        await model.begin()
        XCTAssertEqual(model.phase, .locked)

        await model.unlock(with: .type2(password: Data([0xDE, 0xAD, 0xBE, 0xEF]), pack: Data()))
        XCTAssertEqual(model.phase, .locked, "a wrong password should stay locked, got \(model.phase)")
        XCTAssertTrue(model.unlockFailed)
    }

    /// The transport form of the same refusal, which is the one silicon produces.
    ///
    /// A refused Type-2 PWD_AUTH NAKs, the NAK returns the chip to HALT for the
    /// rest of the activation, and CoreNFC reports the whole session gone. The
    /// driver will not guess between that and a tag leaving the field, so it
    /// raises `.authInconclusive`. The scan flow used to let that fall through to
    /// the reads below it, where the halted chip drew silence,
    /// `tagAnsweredBeforeRead` went false, the recovery at the bottom of the
    /// method could not fire because it requires that flag, and the flow ended at
    /// "Lost the tag mid-read" with the unlock prompt gone (bench 2026-09-09,
    /// finding 3).
    ///
    /// It now ends the activation and returns to the prompt, and the one thing it
    /// does differently from the stated refusal above is that it does not accuse
    /// the password: nothing in this outcome says anything about it.
    @MainActor
    func test_scanFlow_readProtectedTag_lostAuthentication_promptsAgainWithoutBlamingThePassword() async throws {
        let message = try NDEFCodec.encode([NDEFRecord.uri(URIRecord(uri: "https://hex.pro"))])
        let sim = NTAG215Simulator(ndefMessage: message)
        try sim.enablePasswordProtection(
            password: Data([0xCA, 0xFE, 0xBA, 0xBE]), pack: Data([0x12, 0x34]),
            protectFromPage: 4, readProtect: true, authLimit: 0
        )
        let faults = FaultInjectingSessionFactory(chip: sim)
        let model = ScanFlowModel(factory: faults)
        await model.begin()
        XCTAssertEqual(model.phase, .locked)

        // The PWD_AUTH goes out and nothing comes back, which is what the halted
        // chip looks like from the reader. The password itself is the right one,
        // so nothing but the lost frame can explain a failure here.
        faults.arm(TagFault(.opcode(Type2PasswordDriver.pwdAuth), .dropped))

        await model.unlock(with: .type2(password: Data([0xCA, 0xFE, 0xBA, 0xBE]), pack: Data([0x12, 0x34])))

        XCTAssertEqual(
            model.phase, .locked,
            "the tag is still the protected one this tap came back for, so the prompt comes back"
        )
        XCTAssertFalse(
            model.unlockFailed,
            "nothing here says the password was wrong, and this password is in fact correct"
        )
    }

    // MARK: - Which tag the held credential is for

    /// The credential is supplied between taps, with no session open and nothing
    /// making the user put the same tag back. It may not be presented to
    /// whatever turns up next.
    ///
    /// On a Type-2 chip a refused `PWD_AUTH` is a counted attempt against a tag
    /// that never owed one, and on a tag carrying an `AUTH_LIM` it can be the
    /// attempt that ends authentication on it for good. `begin()` resets ten
    /// fields of per-tag state and this credential was not one of them, so the
    /// second tap presented tag A's password to tag B with no comparison
    /// anywhere in the flow.
    @MainActor
    func test_scanFlow_unlockFollowedByADifferentTag_presentsNoCredentialToIt() async throws {
        let message = try NDEFCodec.encode([NDEFRecord.uri(URIRecord(uri: "https://hex.pro"))])
        let locked = NTAG215Simulator(ndefMessage: message)
        try locked.enablePasswordProtection(
            password: Data([0xCA, 0xFE, 0xBA, 0xBE]), pack: Data([0x12, 0x34]),
            protectFromPage: 4, readProtect: true, authLimit: 0
        )
        // A different tag, protected with its own password and carrying a limit.
        // It has to be gated for the fixture to bite: `openGate` reads state
        // first, so an ungated stranger is sent nothing whatever the flow
        // believes it holds, and the whole cost of the bug lands on the tags
        // that do have something to refuse.
        let stranger = NTAG213Simulator(ndefMessage: message)
        try stranger.enablePasswordProtection(
            password: Data([0x01, 0x02, 0x03, 0x04]), pack: Data([0xAB, 0xCD]),
            protectFromPage: 4, readProtect: true, authLimit: 3
        )
        XCTAssertNotEqual(locked.uid, stranger.uid, "the fixture only means anything if the UIDs differ")

        let factory = TwoTagSeamFactory(first: locked, second: stranger)
        let model = ScanFlowModel(factory: factory)
        await model.begin()
        XCTAssertEqual(model.phase, .locked)

        await model.unlock(with: .type2(password: Data([0xCA, 0xFE, 0xBA, 0xBE]), pack: Data([0x12, 0x34])))

        XCTAssertTrue(
            factory.second.report.frames(matching: .opcode(Type2PasswordDriver.pwdAuth)).isEmpty,
            "a tag that was never asked for a password may not be sent one it did not ask for"
        )
        XCTAssertEqual(
            stranger.failedAuthAttempts, 0,
            "three tries is all this tag has, and it did not spend one on another tag's password"
        )
        XCTAssertEqual(
            model.phase, .locked,
            "the prompt comes back, now asking for this tag's own password"
        )
        XCTAssertFalse(
            model.unlockFailed,
            "nothing was presented to this tag, so nothing here may accuse a password"
        )

        // And the stranger is untouched: its own password still opens it.
        stranger.beginActivation()
        XCTAssertEqual(try stranger.authenticate(password: Data([0x01, 0x02, 0x03, 0x04])), Data([0xAB, 0xCD]))
    }

    /// The affordance the guard may not break: the same tag, twice, still
    /// unlocks, and on exactly one attempt.
    ///
    /// The tempting fix was to blank the credential in `begin()`, which is where
    /// the rest of the per-tag state is cleared. That would have removed the
    /// unlock path altogether, because the credential is supplied while no
    /// session is open and `begin()` is what opens the next one.
    @MainActor
    func test_scanFlow_unlockFollowedByTheSameTag_authenticatesOnOneAttempt() async throws {
        let message = try NDEFCodec.encode([NDEFRecord.uri(URIRecord(uri: "https://hex.pro"))])
        let sim = NTAG215Simulator(ndefMessage: message)
        try sim.enablePasswordProtection(
            password: Data([0xCA, 0xFE, 0xBA, 0xBE]), pack: Data([0x12, 0x34]),
            protectFromPage: 4, readProtect: true, authLimit: 0
        )
        let faults = FaultInjectingSessionFactory(chip: sim)
        let model = ScanFlowModel(factory: faults)
        await model.begin()
        XCTAssertEqual(model.phase, .locked)

        await model.unlock(with: .type2(password: Data([0xCA, 0xFE, 0xBA, 0xBE]), pack: Data([0x12, 0x34])))

        XCTAssertEqual(model.phase, .ready, "the right password on the right tag still reads it")
        XCTAssertEqual(
            faults.report.frames(inTap: 2).filter { $0.request.first == Type2PasswordDriver.pwdAuth }.count, 1,
            "one authentication attempt per activation, and the UID check may not add a second"
        )
    }
}

/// One tag per tap, each behind its own seam.
///
/// `SwappingFactory` already models the user presenting a different tag on a
/// later tap, but it vends plain simulated sessions and nothing records what
/// crossed the wire. What these tests assert is a frame that never left, so the
/// per-chip frame log is the whole fixture.
private final class TwoTagSeamFactory: TagSessionFactory, @unchecked Sendable {
    let first: FaultInjectingSessionFactory
    let second: FaultInjectingSessionFactory
    private var taps = 0

    init(first: ChipSimulator, second: ChipSimulator) {
        self.first = FaultInjectingSessionFactory(chip: first)
        self.second = FaultInjectingSessionFactory(chip: second)
    }

    func makeSession() -> TagSession {
        taps += 1
        return taps <= 1 ? first.makeSession() : second.makeSession()
    }
}
