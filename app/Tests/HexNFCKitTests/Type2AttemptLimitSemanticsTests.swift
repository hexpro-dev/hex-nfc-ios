import HexNFCKit
import HexNFCTagSim
import XCTest

/// What `AUTH_LIM` actually counts, replayed from silicon.
///
/// `NTAG21xSimulator.authenticate` has always zeroed `failedAuthAttempts` on a
/// successful `PWD_AUTH`, i.e. modelled the limit as a count of **consecutive**
/// failures, and until 2026-09-14 it exhausted on `failedAuthAttempts >= limit`.
/// Neither had a citation when this file was written. The datasheet passage
/// quoted in `chip-config-pages.md` since 2026-09-15 settles the part below the
/// limit (a success "before reaching the limit" resets the counter to zero) and
/// is silent at it, and the shipping copy at the attempt-limit screen avoids
/// claiming either.
///
/// Both were measured on NTAG213 through the shipping UI on a real iPhone. The
/// captures are the authority these tests encode:
///
/// - **The lock comes one past the limit.** Tag C `04:D4:B1:52:7C:16:90` at
///   `AUTH_LIM = 1` refused one wrong password and then accepted the right one
///   (2026-09-14, 23:03:15 then 23:03:38). Tag A `04:A9:DB:3A:D6:1F:90` at the
///   same limit refused the right one only after two wrong attempts (2026-09-10,
///   11:27:15 and 11:29:06, the second being the factory-default offer). An
///   earlier version of this file said tag A "took exactly one refusal" and
///   concluded the chip stops on reaching the limit; the trace holds two.
/// - **A successful auth resets the counter, and how strongly that is shown
///   changed with the threshold.** Tag B `04:8F:DB:3A:D6:1F:90` at `AUTH_LIM = 4`
///   ran: fail, fail, SUCCEED, fail, fail, SUCCEED, then five fails and a refusal
///   of the correct password (2026-09-10, 11:55:32 to 11:58:33). A count that
///   never resets stood at six by 11:57:22, counting the two failures at a limit
///   of 2 before it, and would have refused that success; it was accepted with a
///   2-byte PACK. A count that resets only when ACCESS is written stood at four
///   there, which a limit of 4 tolerates, so 11:57:22 does not exclude that one.
///   What does is the form of the refusals after it: that count locks the tag at
///   11:57:45, and the four refusals after 11:57:45 came back in the transport
///   form, which on 2026-09-14 only an unlocked chip gave. That rests on the
///   form rule. It has not been measured directly.
///
///   The datasheet promises the reset only "before reaching the limit", and
///   tag B's successes came at a count of two under four, inside the promise.
///   Tag C settled the case it leaves open on 2026-09-19: at `AUTH_LIM = 1` it
///   ran wrong, right, wrong, right and accepted the last (19:40:24 to
///   19:45:37), where tag A locked on two wrong passwords with nothing between
///   them. At a limit of 1 a reset to zero and a step back by one cannot be
///   told apart.
///
/// Tags A and B are consumed and recorded in `test-harness.md`; tag C was
/// recovered. What these tests do NOT claim: that either rule holds for every
/// limit value or for the rest of the family, which shares the simulator's code
/// and was never measured.
///
/// The refusal *form* is deliberately not asserted here. On silicon it follows
/// the chip's state: an unlocked chip answers a wrong password with a transport
/// error, and a locked chip answers every password with a 1-byte NAK (ten of ten
/// on 2026-09-14, wrong and right alike). The simulator emits the NAK for both.
/// That divergence is recorded in `unverified-behaviour.md` T2-3.
final class Type2AttemptLimitSemanticsTests: XCTestCase {
    private let password = Data([0xA1, 0xB2, 0xC3, 0xD4])
    private let pack = Data([0x00, 0x00])
    private var wrong: Data {
        Data([0x00, 0x00, 0x00, 0x01])
    }

    private func armed(limit: Int) throws -> NTAG213Simulator {
        let sim = NTAG213Simulator()
        try sim.enablePasswordProtection(
            password: password, pack: pack, protectFromPage: 4, readProtect: false, authLimit: limit
        )
        return sim
    }

    /// Feeding the wrong password and reporting whether the chip refused.
    @discardableResult
    private func present(_ credential: Data, to sim: NTAG213Simulator) -> Bool {
        do {
            _ = try sim.authenticate(password: credential)
            return true
        } catch {
            return false
        }
    }

    // MARK: - The threshold

    /// Tag C: one wrong password at a limit of one does not lock the tag.
    func test_oneFailureAtALimitOfOne_leavesTheRightPasswordWorking() throws {
        let sim = try armed(limit: 1)

        XCTAssertFalse(present(wrong, to: sim), "23:03:15, refused")
        XCTAssertEqual(sim.failedAuthAttempts, 1)
        XCTAssertFalse(sim.isAuthLocked, "one failure does not pass a limit of one")

        XCTAssertTrue(
            present(password, to: sim),
            "tag C accepted the correct password at 23:03:38, one wrong attempt after the limit was set"
        )
    }

    /// Tag A: the second wrong password is the one that locks it, and the right
    /// password is refused for good after that. This is what makes the operation
    /// irreversible in the way the screen's warning says.
    func test_theCounterLocksOnePastTheLimit_replayingTagA() throws {
        let sim = try armed(limit: 1)

        // 11:27:15, a wrong password
        XCTAssertFalse(present(wrong, to: sim))
        XCTAssertFalse(sim.isAuthLocked)

        // 11:29:06, the factory-default offer, also wrong
        XCTAssertFalse(present(Data([0xFF, 0xFF, 0xFF, 0xFF]), to: sim))
        XCTAssertTrue(sim.isAuthLocked, "the second consecutive failure passes a limit of one")

        XCTAssertFalse(
            present(password, to: sim),
            "tag A refused the correct password at 11:29:51, after those two"
        )
    }

    // MARK: - Tag B: the reset

    /// The full 2026-09-10 tag B sequence at `AUTH_LIM = 4`, in order.
    ///
    /// The two successes in the middle are each accepted after two refusals. A
    /// count that never resets would have refused the second. See the header for
    /// what this sequence no longer rules out on its own.
    func test_aSuccessfulAuthResetsTheCounter_replayingTagBAtLimitFour() throws {
        let sim = try armed(limit: 4)

        // 11:55:33 and 11:55:57
        XCTAssertFalse(present(wrong, to: sim))
        XCTAssertFalse(present(wrong, to: sim))
        XCTAssertEqual(sim.failedAuthAttempts, 2)

        // 11:56:28, accepted on silicon with a 2-byte PACK
        XCTAssertTrue(present(password, to: sim), "two failures out of four leave the gate reachable")
        XCTAssertEqual(sim.failedAuthAttempts, 0, "and the success clears the count")

        // 11:56:52 and 11:57:03
        XCTAssertFalse(present(wrong, to: sim))
        XCTAssertFalse(present(wrong, to: sim))

        // 11:57:22, accepted on silicon. A count that never resets would stand
        // at six here, with the two failures at a limit of 2, and refuse it.
        XCTAssertTrue(
            present(password, to: sim),
            "silicon accepted this at 11:57:22, two consecutive failures after the last success"
        )
        XCTAssertFalse(sim.isAuthLocked)

        // 11:57:45 to 11:58:19: five in a row. Each answered in the transport
        // form, which on 2026-09-14 is what an unlocked chip gives a wrong
        // password, so the fifth is the one that locked it.
        for _ in 0 ..< 4 {
            XCTAssertFalse(present(wrong, to: sim))
        }
        XCTAssertFalse(sim.isAuthLocked, "four failures do not pass a limit of four")
        XCTAssertFalse(present(wrong, to: sim))
        XCTAssertTrue(sim.isAuthLocked, "the fifth does")

        // 11:58:33, refused with a 1-byte NAK.
        XCTAssertFalse(present(password, to: sim), "and the correct password no longer opens it")
    }

    // MARK: - Tag C: the reset at the limit

    /// The 2026-09-19 run on tag C at `AUTH_LIM = 1`, in order: wrong, right,
    /// wrong, right. The success at 19:41:48 comes at a count of one, the limit,
    /// where the datasheet promises nothing. The last password is accepted only
    /// if that success cleared the count, because otherwise the wrong password
    /// before it is the try past the limit and locks the tag, as it did tag A.
    /// Trace `bench-traces/2026-09-19-part4-authlim-reset-ntag213.log`.
    func test_aSuccessAtTheLimitResetsTheCounter_replayingTagCOnTheNineteenth() throws {
        let sim = try armed(limit: 1)

        // 19:40:24, refused in the transport form
        XCTAssertFalse(present(wrong, to: sim))
        XCTAssertEqual(sim.failedAuthAttempts, 1, "the count now stands at the limit")

        // 19:41:48, accepted with the PACK
        XCTAssertTrue(present(password, to: sim), "a count at the limit still accepts the right password")
        XCTAssertEqual(sim.failedAuthAttempts, 0, "and the success clears it")

        // 19:44:29, refused in the transport form
        XCTAssertFalse(present(wrong, to: sim))
        XCTAssertFalse(sim.isAuthLocked, "one wrong password since the last success is within a limit of one")

        // 19:45:37, accepted with the PACK
        XCTAssertTrue(
            present(password, to: sim),
            "silicon accepted this at 19:45:37, so the success at 19:41:48 cleared the count"
        )
    }

    /// The counter is not disturbed by a successful auth on a tag with no limit
    /// set, which is the ordinary case and the one every other test relies on.
    ///
    /// This passes before and after the 2026-09-10 sitting. It is here so the
    /// replay above cannot be read as saying something about `AUTH_LIM = 0`,
    /// which gates nothing and was never measured on an exhaustion path.
    func test_aTagWithNoLimitNeverExhausts() throws {
        let sim = try armed(limit: 0)

        for _ in 0 ..< 8 {
            XCTAssertFalse(present(wrong, to: sim))
        }

        XCTAssertFalse(sim.isAuthLocked, "AUTH_LIM 0 is unlimited, and never auto-bricks")
        XCTAssertTrue(present(password, to: sim), "so the correct password still opens it")
    }
}
