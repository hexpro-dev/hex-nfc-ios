@testable import HexNFCKit
import XCTest

/// Which families may have their protection state read before a credential is
/// presented, and which have to authenticate first.
///
/// The rule was a private static on `WriteFlowModel` with a long doc comment
/// and no test. Three other places need the same answer and none of them could
/// reach it: the Operations preflight, `HexNFCTestKit`'s plans, and the DEBUG
/// enforcement verifier. Both halves of that are worth fixing, but the test is
/// the half that stops the rule drifting once it has more than one caller.
///
/// Each expectation below is a measured fact, not a preference. The reasoning
/// lives on `TagFamily.gateIsSafeToReadBeforeAuthenticating`; what lives here
/// is the table.
final class GateReadOrderingTests: XCTestCase {
    private func readsFirst(_ family: TagFamily?) -> Bool {
        TagFamily.gateIsSafeToReadBeforeAuthenticating(family)
    }

    /// The whole table, with no default arm anywhere in it, so a new variant
    /// fails this build rather than quietly inheriting an answer.
    func test_everyFamilyStatesWhetherItsGateIsSafeToReadFirst() {
        for variant in Type2Variant.allCases {
            let expected = switch variant {
            // Ultralight C is Type-2 by transport only. Its config pages are
            // readable on every tag this app can reach.
            case .mifareUltralightC:
                true

            // The PWD_AUTH families. Config sits at or above AUTH0, and a
            // refused read halts the chip for the rest of the activation.
            case .ntag210Micro, .ntag213, .ntag213TT, .ntag215, .ntag216,
                 .mifareUltralightEV1_48, .mifareUltralightEV1_128,
                 .emV10, .emV11, .emV16, .unknown:
                false

            // A 424 reached through the .type2 case is a mislabelling, but the
            // conservative answer is the Type-2 one: authenticate first.
            case .ntag424DNA:
                false
            }
            XCTAssertEqual(
                readsFirst(.type2(variant)), expected,
                "\(variant.shortName) must \(expected ? "read its gate first" : "authenticate first")"
            )
        }

        // A Type-4 read SELECTs, and a SELECT ends a live EV2 session
        // (measured 2026-09-20), so reading after authenticating throws the
        // session away.
        for variant in Type4Variant.allCases {
            XCTAssertTrue(readsFirst(.type4(variant)), "\(variant.shortName) reads its gate first")
        }
        // On Type-5 the credential a flow holds may be one the tag has never
        // held, and presenting it blind is what stopped SLIX2 ever arming.
        for variant in Type5Variant.allCases {
            XCTAssertTrue(readsFirst(.type5(variant)), "\(variant.shortName) reads its gate first")
        }
        XCTAssertTrue(readsFirst(.felica))
        XCTAssertTrue(readsFirst(.unknown))

        // No page map, no idea where the configuration sits. Guessing wrong
        // costs a tap on the family where that is most expensive, so an
        // unidentified chip takes the careful answer.
        XCTAssertFalse(readsFirst(nil), "an unidentified chip authenticates first")
    }

    /// The two sitting side by side, because the exception is the part that
    /// gets lost. It was lost once already: `readsItsGateBeforeAuthenticating`
    /// first shipped matching on `.type2` alone, and the Ultralight C bench run
    /// on 2026-09-20 failed with "chip is halted by an earlier refusal" until
    /// the variant was pulled out of the family arm (bench finding 14).
    func test_ultralightCIsTheType2Exception() {
        XCTAssertTrue(readsFirst(.type2(.mifareUltralightC)))
        XCTAssertFalse(readsFirst(.type2(.ntag213)))
    }
}
