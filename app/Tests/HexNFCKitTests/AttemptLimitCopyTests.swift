@testable import HexNFCKit
import HexNFCTagSim
import XCTest

/// What a refusal is allowed to say about a password, on a tag that reported an
/// attempt limit.
///
/// Measured on 2026-09-10 (`docs/internal/bench-traces/2026-09-10-t2-1-ntag213.log`,
/// 11:29:51): an NTAG213 whose `AUTH_LIM` was exhausted refused the **correct**
/// password with a 1-byte NAK, twelve milliseconds after the app read
/// `ACCESS = 01` off the same tag in the same activation. The driver classified
/// the short reply `.authFailed` and the screen said "Wrong password."
///
/// It was not the wrong password. The tag was locked out, and the app had
/// already read the byte that said lockout was possible.
///
/// The copy these tests pin does **not** say the tag is locked out. No chip in
/// this catalogue discloses attempts used, so that would be asserting state no
/// read established, which is the invariant this whole cluster exists to serve.
/// It says a limit is set and the refusal is therefore ambiguous.
final class AttemptLimitCopyTests: XCTestCase {
    private let password = Data([0xA1, 0xB2, 0xC3, 0xD4])
    private let wrong = Data([0x00, 0x00, 0x00, 0x01])
    private let pack = Data([0x00, 0x00])

    private func protectedTag(authLimit: Int) throws -> NTAG213Simulator {
        let sim = NTAG213Simulator()
        try sim.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: false, authLimit: authLimit
        )
        return sim
    }

    /// Drive the shipping driver over the shipping frames, through the public
    /// fault-injection factory. `SingletonChipFactory` is `private` in three
    /// separate test files and is not reachable from here.
    private func driver(for sim: NTAG213Simulator) async throws -> Type2PasswordDriver {
        let tag = try await FaultInjectingSessionFactory(chip: sim).makeSession().start(alert: "")
        return try XCTUnwrap(tag.type2PasswordDriver)
    }

    // MARK: - The finding

    /// A refusal on a tag with a limit set may not say the password was wrong.
    func test_aRefusalOnALimitedTagDoesNotAccuseThePassword() async throws {
        let sim = try protectedTag(authLimit: 1)
        let driver = try await driver(for: sim)

        do {
            _ = try await driver.openGate(password: wrong)
            XCTFail("the wrong password must be refused")
        } catch let error as TagError {
            let message = String(localized: error.userMessage)
            XCTAssertNotEqual(
                message, String(localized: TagError.authFailed().userMessage),
                "\"Wrong password.\" is a claim the frame does not support on a tag that can lock out"
            )
            XCTAssertTrue(
                message.contains("attempt limit"),
                "the copy has to name the thing that makes the refusal ambiguous. Got: \(message)"
            )
            XCTAssertEqual(
                error.attemptLimit,
                1,
                "and it carries the byte it read, for surfaces that compose their own copy"
            )
        }
    }

    /// The exact silicon case: the tag is exhausted and the password is right.
    /// This is the tap that produced the finding.
    func test_theExhaustedTagRefusingTheCorrectPasswordDoesNotAccuseIt() async throws {
        let sim = try protectedTag(authLimit: 1)
        // Two wrong attempts: the chip locks one past its limit. Tag A took the
        // same two, the second being the factory-default offer.
        _ = try? sim.authenticate(password: wrong)
        _ = try? sim.authenticate(password: wrong)
        XCTAssertTrue(sim.isAuthLocked, "the fixture must actually be exhausted")

        let driver = try await driver(for: sim)

        do {
            _ = try await driver.openGate(password: password)
            XCTFail("an exhausted tag refuses the correct password: measured 11:29:51")
        } catch let error as TagError {
            let message = String(localized: error.userMessage)
            XCTAssertFalse(
                message.contains("Wrong password"),
                "the password was right. Got: \(message)"
            )
        }
    }

    // MARK: - The counter-cases

    /// A tag with no limit keeps the plain copy. Most tags are this, and
    /// "Wrong password." is exactly right for them.
    func test_aTagWithNoLimitStillSaysWrongPassword() async throws {
        let sim = try protectedTag(authLimit: 0)
        let driver = try await driver(for: sim)

        do {
            _ = try await driver.openGate(password: wrong)
            XCTFail("the wrong password must be refused")
        } catch let error as TagError {
            XCTAssertEqual(
                String(localized: error.userMessage),
                String(localized: TagError.authFailed().userMessage),
                "nothing about this tag makes the refusal ambiguous, so do not hedge it"
            )
            XCTAssertNil(error.attemptLimit, "0 is not a limit, and must not be filed as one")
        }
    }

    /// The transport form earns its own hedge, and it must not repeat the plain
    /// copy's "try again" without saying what a try costs.
    ///
    /// `AUTH_LIM` counts **failed** verifications only, and a correct password
    /// below the limit resets the counter (`Type2AttemptLimitSemanticsTests`).
    /// So the copy says a *wrong* try counts, not that every try counts. An
    /// earlier draft of this change said the latter, and the 2026-09-10 bench
    /// run disproves it.
    ///
    /// Nor may it open with "the tag stopped answering": on a limited tag this
    /// form is what an unlocked chip gives a wrong password (2026-09-14, tag C at
    /// 23:03:15), and that lead told the user the password was never checked.
    func test_theTransportFormSaysWhichAttemptsCount() {
        let qualified = TagError.authInconclusive(attemptLimit: 3, diagnostics: "d")
        let message = String(localized: qualified.userMessage)

        XCTAssertTrue(message.contains("attempt limit"), "Got: \(message)")
        XCTAssertTrue(
            message.contains("wrong try"),
            "AUTH_LIM counts failed verifications only. Saying every try counts is false, and is "
                + "the exact over-statement the review caught. Got: \(message)"
        )
        XCTAssertFalse(
            message.contains("stopped answering"),
            "on a limited tag this form is a refused wrong password, not an unchecked one. Got: \(message)"
        )
        XCTAssertEqual(qualified.kind, .authInconclusive, "the kind is what it always was")
    }

    /// A limit read off a tag that could have rolled over may not reach the copy.
    ///
    /// Without a 7-byte UID a `30 <config0Page>` can serve page 0, whose byte at
    /// the ACCESS offset is UID or BCC data rather than CFG1. `gateVerdictFromReading`
    /// already refuses to file a gate page on that basis; the limit gets the same
    /// guard, because it is about to change what the user is told about their
    /// password.
    func test_aLimitIsNotFiledWhenARolloverCouldHaveForgedIt() {
        XCTAssertNil(
            Type2Rollover.signature(forUID: Data([0x04, 0x8F, 0xDB, 0x3A])),
            "a 4-byte UID has no roll-over signature, so nothing read can be checked against one"
        )
        XCTAssertNotNil(
            Type2Rollover.signature(forUID: Data([0x04, 0x8F, 0xDB, 0x3A, 0xD6, 0x1F, 0x90])),
            "and a 7-byte UID does"
        )
    }

    /// A limit of `nil` or `0` falls all the way through to the plain copy, on
    /// both forms. This is what keeps the change confined to tags that really
    /// reported a limit, and it is asserted on the constructors rather than on
    /// the internal helper so it pins the contract callers actually see.
    func test_anAbsentOrZeroLimitChangesNothing() {
        for limit in [nil, 0] as [Int?] {
            XCTAssertEqual(
                String(localized: TagError.authRefused(attemptLimit: limit, diagnostics: "d").userMessage),
                String(localized: TagError.authFailed().userMessage),
                "limit \(String(describing: limit)) is not a limit"
            )
            XCTAssertNil(TagError.authRefused(attemptLimit: limit, diagnostics: "d").attemptLimit)
            XCTAssertEqual(
                String(localized: TagError.authInconclusive(attemptLimit: limit, diagnostics: "d").userMessage),
                String(localized: TagError.authInconclusive(diagnostics: "d").userMessage)
            )
        }
    }

    /// The kind is untouched by the copy change, on both forms.
    ///
    /// Load-bearing: `ScanFlowModel.isLikelyProtectionFailure`, the unlock switch,
    /// `ProtectionProbe` and `OperationsFlowModel.recovery` all key on the kind.
    /// A new `Kind` case here would have fallen into their `default:` arms and
    /// silently dropped the read-protected unlock route.
    func test_theKindSurvivesTheCopyChange() {
        XCTAssertEqual(TagError.authRefused(attemptLimit: 2, diagnostics: "d").kind, .authFailed)
        XCTAssertEqual(TagError.authInconclusive(attemptLimit: 2, diagnostics: "d").kind, .authInconclusive)
    }

    // MARK: - The tag that will not say

    /// A read-protected tag keeps `AUTH_LIM` in the pages it refuses to serve,
    /// so the driver reads no limit at all. Reported as "no limit" that becomes
    /// the plain "Wrong password." for the scan prompt's purposes, which is how
    /// the prompt came back in its neutral first-run copy after a refusal: the
    /// owner saw nothing to say a try had been spent, and the same button spent
    /// the next one. On a tag armed at a limit of 1 that is two presses to a tag
    /// that will never accept its password again.
    ///
    /// Three unknowns are all real here, and the copy may not resolve any of
    /// them: whether a limit is set, whether the password was wrong (the
    /// transport form is also what a lifted tag looks like, 2026-09-14), and how
    /// many tries remain (no chip in this catalogue discloses that).
    func test_aRefusalFromAReadGatedTagSaysTheTryMayHaveCounted() async throws {
        let sim = NTAG213Simulator()
        try sim.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: true, authLimit: 1
        )
        let driver = try await driver(for: sim)

        do {
            _ = try await driver.openGate(password: wrong)
            XCTFail("the wrong password must be refused")
        } catch let error as TagError {
            XCTAssertEqual(
                error.limitReading, .hidden,
                "the gate hid AUTH_LIM, and that is a third state, not 'no limit'"
            )
            XCTAssertNil(error.attemptLimit, "no number was read, so none may be reported")
            let message = String(localized: error.userMessage)
            XCTAssertNotEqual(
                message, String(localized: TagError.authFailed().userMessage),
                "the plain copy invites the same password again on the one tag whose counter "
                    + "this app cannot watch"
            )
            XCTAssertNotEqual(
                message, String(localized: TagError.authInconclusive().userMessage),
                "and 'hold it steady and try again' invites it twice over"
            )
            XCTAssertTrue(message.contains("attempt limit"), "Got: \(message)")
        }
    }

    /// The same qualification reaches the two screens that authenticate through
    /// a read gate on the raw primitive, because `openGate` cannot be used
    /// there: its state read is the very read such a tag refuses.
    func test_theRawGatedPrimitiveQualifiesItsRefusalToo() async throws {
        let sim = NTAG213Simulator()
        try sim.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: true, authLimit: 1
        )
        let driver = try await driver(for: sim)

        do {
            _ = try await driver.authenticateThroughAReadGate(password: wrong)
            XCTFail("the wrong password must be refused")
        } catch let error as TagError {
            XCTAssertEqual(error.limitReading, .hidden)
        }
    }

    /// The removal's gated arm carries it too. `disable` on a read-gated tag
    /// authenticates on the raw primitive and passes `limitIsHidden`, and
    /// without that the refusal a user sees while removing a password on such a
    /// tag loses the same warning.
    func test_aRemovalRefusedByAReadGatedTagCarriesTheHiddenReading() async throws {
        let sim = NTAG213Simulator()
        try sim.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: true, authLimit: 1
        )
        let driver = try await driver(for: sim)

        do {
            _ = try await driver.disable(currentPassword: wrong)
            XCTFail("the wrong password must be refused")
        } catch let error as TagError {
            guard case .protectionIncomplete = error.kind else {
                return XCTFail("a refused removal reports its residue, got \(error.kind)")
            }
            XCTAssertEqual(
                error.limitReading, .hidden,
                "the tag hid AUTH_LIM behind the gate the removal was trying to open"
            )
            XCTAssertTrue(String(localized: error.userMessage).contains("attempt limit"))
        }
    }

    /// And it changes nothing for every other failure that passes through it. A
    /// length rejection or a lost session says what it always said.
    func test_theHiddenQualificationTouchesOnlyAnAuthenticationOutcome() {
        let lost = TagError.tagLost(diagnostics: "d")
        XCTAssertEqual(lost.qualifiedByAHiddenAttemptLimit().limitReading, .notRead)
        XCTAssertEqual(
            String(localized: lost.qualifiedByAHiddenAttemptLimit().userMessage),
            String(localized: lost.userMessage)
        )
    }
}
