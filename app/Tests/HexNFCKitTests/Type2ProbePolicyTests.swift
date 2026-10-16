@testable import HexNFCKit
import XCTest

/// The identification retry rule, and the reason it has to be a rule.
///
/// ## What went wrong
///
/// On 2026-09-21 an NTAG213 was armed from the tag editor and the owner then
/// tried to remove the password from the Operations sheet. Tap 1 identified the
/// tag, the owner typed its fourteen-character UID, and on tap 2 the `60` send
/// failed with "Tag connection lost" before the chip ever saw it. The old code
/// classified that with `(version?.count ?? 0) < 8`, which cannot tell a
/// one-byte NAK from a send that never completed, so it filed a transport
/// failure as a chip refusal. The session re-polled into the second pass, which
/// deliberately never re-sends `GET_VERSION`, and the only decoder on that pass
/// recognises MIFARE Ultralight C. An NTAG213's config[8] is its ACCESS byte,
/// which read back `0x00`, so the decoder returned nil, the tag arrived with
/// `chip == nil`, and `requireType2Driver` refused the removal with "This tag
/// does not support that operation." Not one protection frame reached the tag.
///
/// The chip had refused nothing. It answered `60` cleanly sixteen seconds
/// earlier and again two minutes later.
///
/// ## Why the rule lives in a type of its own
///
/// `CoreNFCSession` and `MiFareTagIdentifier` are both `#if canImport(CoreNFC)
/// && os(iOS)`, and `swift build` / `swift test` on macOS skip those files
/// whole, so nothing in CI can see them. The decision is the load-bearing half
/// of the fix, so the decision is what got pulled out into a pure type.
final class Type2ProbePolicyTests: XCTestCase {
    private func step(
        _ verdict: Type2ProbeVerdict,
        getVersion: Int = 1,
        shape: Int = 0
    ) -> Type2ProbeNextStep {
        Type2ProbePolicy.nextStep(
            after: verdict,
            attempts: .init(getVersion: getVersion, shape: shape)
        )
    }

    // MARK: The defect, as a test

    /// The one that would have caught 2026-09-21. A transport failure must
    /// never reach the memory-shape decoder, because that decoder can only
    /// answer "MIFARE Ultralight C" and the tag in hand may be anything.
    func test_aTransportFailureIsAskedAgainRatherThanDecodedFromMemoryShape() {
        XCTAssertEqual(step(.transportLost), .repollAndRetryGetVersion)
        XCTAssertNotEqual(
            step(.transportLost), .repollAndDecodeShape,
            "a send that never completed says nothing about the chip, and the shape decoder "
                + "recognises exactly one model"
        )
    }

    /// The behaviour that already worked, unchanged: a chip that genuinely
    /// refuses `GET_VERSION` is the case the shape decoder exists for.
    func test_aChipRefusalStillEarnsTheMemoryShapePass() {
        XCTAssertEqual(step(.chipRefused), .repollAndDecodeShape)
    }

    /// A refused chip is never asked a second time. The refusal is the chip
    /// saying it does not implement the command, and asking twice only halts it
    /// twice (live-confirmed 2026-08-06).
    func test_aRefusedChipIsNeverAskedForGetVersionAgain() {
        for attempts in 1 ... 4 {
            XCTAssertNotEqual(
                step(.chipRefused, getVersion: attempts), .repollAndRetryGetVersion,
                "a chip that refused 60h at attempt \(attempts) must not be asked again"
            )
        }
    }

    func test_anAnsweredProbeIsHandedStraightUp() {
        XCTAssertEqual(step(.answered), .handUp)
        XCTAssertEqual(step(.answered, getVersion: 3, shape: 2), .handUp)
    }

    // MARK: The ceiling

    /// A tag that keeps losing the transport must not loop the polling
    /// restart. One extra ask, then hand it up however little we know.
    func test_aSecondTransportFailureIsHandedUpRatherThanAskedAThirdTime() {
        XCTAssertEqual(step(.transportLost, getVersion: 2), .handUp)
        XCTAssertEqual(step(.transportLost, getVersion: 9), .handUp)
    }

    func test_aSecondShapePassIsNeverOffered() {
        XCTAssertEqual(step(.chipRefused, getVersion: 2, shape: 1), .handUp)
    }

    /// The ceiling stated as a whole rather than case by case: walk every
    /// reachable sequence of verdicts and prove the tap ends. Three activations
    /// is the deepest: ask, lose the transport, ask again, get refused, decode
    /// the shape.
    func test_everyVerdictSequenceTerminatesWithinThreeActivations() {
        let verdicts: [Type2ProbeVerdict] = [.answered, .chipRefused, .transportLost]

        func walk(_ attempts: Type2ProbePolicy.Attempts, depth: Int, path: [Type2ProbeVerdict]) {
            XCTAssertLessThanOrEqual(
                depth, 3,
                "a tap reached \(depth) activations via \(path.map(\.rawValue).joined(separator: " -> "))"
            )
            guard depth < 3 else { return }
            for verdict in verdicts {
                var spent = attempts
                switch Type2ProbePolicy.nextStep(after: verdict, attempts: spent) {
                case .handUp:
                    continue

                case .repollAndRetryGetVersion:
                    spent.getVersion += 1
                    walk(spent, depth: depth + 1, path: path + [verdict])

                case .repollAndDecodeShape:
                    // The shape pass sends reads only and produces no verdict of
                    // its own, so it is a leaf.
                    spent.shape += 1
                    XCTAssertLessThanOrEqual(depth + 1, 3)
                }
            }
        }

        walk(.init(getVersion: 1), depth: 1, path: [])
    }

    // MARK: Why the policy is the guard, and not a byte

    /// The memory-shape decoder is unsafe for an NTAG21x, and no guard inside
    /// it can fix that. This pins the hazard so nobody widens its caller.
    ///
    /// `ChipCatalog.identify(preEV1PageZero:configPages:)` accepts `config[8]`
    /// anywhere in `0x03...0x30` because that is Ultralight C's AUTH0 range. On
    /// an NTAG21x that byte is ACCESS, whose low three bits are `AUTH_LIM`, so
    /// any tag carrying an attempt limit of 3 to 7 lands inside the window. The
    /// other checks pass too: `config[12]` is `PWD` byte 0, which NTAG21x
    /// answers as `00` because it never serves the password pages, so the AUTH1
    /// test (`auth1 & ~0x01 == 0`) is satisfied, and the manufacturer, BCC and
    /// roll-over guards all hold on a 45-page chip.
    ///
    /// The app's own Attempt limit screen defaults to 3.
    ///
    /// So the decoder WILL claim an NTAG213 with an attempt limit, and the only
    /// thing standing between that and a user is that a chip which answers
    /// `60h` never earns `.repollAndDecodeShape`. That is the test above; this
    /// one records what it is protecting.
    func test_theShapeDecoderWouldClaimAnNTAG213CarryingAnAttemptLimit() {
        // A real NTAG213's page 0, straight out of the 2026-09-21 capture.
        let pageZero = Data([
            0x04, 0xD4, 0xB1, 0xE9, 0x52, 0x7C, 0x16, 0x90,
            0xA8, 0x48, 0x00, 0x00, 0xE1, 0x10, 0x12, 0x00,
        ])
        // Pages 28h-2Bh from the same tag, with ACCESS set to AUTH_LIM = 3.
        // Page 2Bh is PWD, which the chip answers as zeros (rev 3.2 section 8.8).
        var configPages = [UInt8]([
            0x00, 0x00, 0x00, 0xBD, // 28h dynamic lock + RFUI
            0x04, 0x00, 0x00, 0x04, // 29h MIRROR, RFUI, MIRROR_PAGE, AUTH0
            0x00, 0x05, 0x00, 0x00, // 2Ah ACCESS, RFUI...
            0x00, 0x00, 0x00, 0x00, // 2Bh PWD, served as zeros
        ])

        XCTAssertNil(
            ChipCatalog.identify(preEV1PageZero: pageZero, configPages: Data(configPages)),
            "AUTH_LIM = 0 keeps ACCESS below the Ultralight C window, which is luck, not a guard"
        )

        for limit in 3 ... 7 {
            configPages[8] = UInt8(limit)
            XCTAssertEqual(
                ChipCatalog.identify(preEV1PageZero: pageZero, configPages: Data(configPages))?.id,
                .mifareUltralightC,
                "recorded, not endorsed: with AUTH_LIM = \(limit) this decoder claims an NTAG213. "
                    + "It is safe only because Type2ProbePolicy never routes an answering chip here."
            )
        }
    }
}
