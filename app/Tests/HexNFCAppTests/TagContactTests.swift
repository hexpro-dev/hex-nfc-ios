@testable import HexNFCApp
@testable import HexNFCKit
import XCTest

/// The rule every flow asks before it reports a cancel or a timeout quietly.
///
/// Quiet needs all three: the kind is a cancel or a timeout, the session
/// vouched that no tag was ever detected, and no earlier ending in the flow
/// could have involved a tag. Each test below breaks exactly one of the three.
final class TagContactTests: XCTestCase {
    private let vouchedCancel = TagError.sessionCancelled(diagnostics: "test").endingBeforeAnyTag()
    private let vouchedTimeout = TagError.sessionTimeout(diagnostics: "test").endingBeforeAnyTag()

    func test_aVouchedCancelOrTimeoutOnAFreshFlowIsQuiet() {
        var contact = TagContact()
        XCTAssertEqual(contact.quietEnding(for: vouchedCancel), .cancelled)
        XCTAssertEqual(contact.quietEnding(for: vouchedTimeout), .timedOut)
    }

    /// A quiet ending is not contact, so the one after it is quiet too. This is
    /// the reviewer's path: the sheet times out, Try again, then Cancel.
    func test_aQuietEndingIsNotContact() {
        var contact = TagContact()
        _ = contact.quietEnding(for: vouchedTimeout)
        XCTAssertFalse(contact.mayHaveTouchedATag)
        XCTAssertEqual(contact.quietEnding(for: vouchedCancel), .cancelled)
    }

    /// Once any session has had a tag, nothing about a later empty sheet may be
    /// quiet: that session may have written.
    func test_aTagFromAnEarlierSessionKeepsEveryLaterEndingReported() {
        var contact = TagContact()
        contact.tagArrived()
        XCTAssertNil(contact.quietEnding(for: vouchedCancel))
        XCTAssertNil(contact.quietEnding(for: vouchedTimeout))
    }

    /// The same kinds, without the session's word that nothing was detected, are
    /// a cancel that landed while a tag was being identified.
    func test_anUnvouchedCancelIsReported_andCountsAsContact() {
        var contact = TagContact()
        XCTAssertNil(contact.quietEnding(for: TagError.sessionCancelled(diagnostics: "test")))
        XCTAssertTrue(contact.mayHaveTouchedATag)
        XCTAssertNil(contact.quietEnding(for: vouchedCancel), "and the next empty sheet is reported too")
    }

    func test_anUnvouchedTimeoutIsReported() {
        var contact = TagContact()
        XCTAssertNil(contact.quietEnding(for: TagError.sessionTimeout(diagnostics: "test")))
        XCTAssertTrue(contact.mayHaveTouchedATag)
    }

    /// Any other ending is taken as possible contact, even one the session
    /// vouched for, because only a cancel and a timeout have a quiet reading.
    func test_anyOtherEndingCountsAsContact() {
        var contact = TagContact()
        let unavailable = TagError(
            kind: .sessionUnavailable, userMessage: "test", diagnostics: "test"
        ).endingBeforeAnyTag()
        XCTAssertNil(contact.quietEnding(for: unavailable))
        XCTAssertTrue(contact.mayHaveTouchedATag)

        var another = TagContact()
        XCTAssertNil(another.quietEnding(for: CocoaError(.featureUnsupported)))
        XCTAssertTrue(another.mayHaveTouchedATag, "an error this type cannot account for may have come from a tag")
    }
}
