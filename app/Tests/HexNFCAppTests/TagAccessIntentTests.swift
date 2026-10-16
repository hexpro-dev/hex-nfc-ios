@testable import HexNFCApp
@testable import HexNFCKit
@testable import HexNFCRecords
import XCTest

/// Whether a tap needs the tag's credential, answered from what the tap
/// touches rather than from which screen launched it.
///
/// Both routes get this wrong today, in opposite directions. The editor asks
/// the question inline and only about itself. Operations never asks it at all,
/// so erase writes the data area with no credential and the memory dump reads
/// gated pages with no credential, while the editor can do both on the same
/// tag. This is the table that makes the two agree.
final class TagAccessIntentTests: XCTestCase {
    private let ndefUpper = 39 // NTAG213: the last page of the data area.

    private func open() -> TagProtection {
        TagProtection(passwordProtect: false)
    }

    /// Write-gated from the first data page: the ordinary armed tag.
    private func writeGated() -> TagProtection {
        TagProtection(passwordProtect: true, protectFromPage: 4, readProtect: false)
    }

    /// Armed, but with the gate above the data area, so the records are
    /// writable and only the configuration is not.
    private func configGatedOnly() -> TagProtection {
        TagProtection(passwordProtect: true, protectFromPage: 41, readProtect: false)
    }

    /// What `Type2PasswordDriver.readState()` hands back for a read-gated tag:
    /// the page number is behind the gate it describes, so it is nil.
    private func readGatedProjection() -> TagProtection {
        TagProtection(passwordProtect: true, protectFromPage: nil, readProtect: true)
    }

    private func needs(_ intent: TagAccessIntent, _ state: TagProtection) -> Bool {
        intent.needsCredential(given: state, ndefUpperBound: ndefUpper)
    }

    // MARK: An open tag never needs one

    func test_anUnprotectedTagNeedsNoCredentialForAnyIntent() {
        for intent: TagAccessIntent in [
            [], .readsGatedPages, .writesDataArea, .writesConfigPages,
            [.writesDataArea, .writesConfigPages],
        ] {
            XCTAssertFalse(needs(intent, open()), "an open tag gates nothing")
        }
    }

    // MARK: The ordinary armed tag

    func test_aWriteGatedTagNeedsACredentialToWriteAndNotToRead() {
        XCTAssertTrue(needs(.writesDataArea, writeGated()))
        XCTAssertTrue(needs(.writesConfigPages, writeGated()))
        XCTAssertFalse(
            needs(.readsGatedPages, writeGated()),
            "PROT = 0 leaves reads open, which is the whole point of a write-only gate"
        )
    }

    /// The case the editor's inline test already got right, kept because it is
    /// the reason the comparison is `<=` against the upper bound rather than a
    /// plain `passwordProtect`.
    func test_aTagGatedOnlyAboveTheDataAreaStillNeedsACredentialForItsConfigPages() {
        XCTAssertFalse(needs(.writesDataArea, configGatedOnly()))
        XCTAssertTrue(needs(.writesConfigPages, configGatedOnly()))
    }

    // MARK: The read-gated projection

    /// `protectFromPage: nil` must read as "everything is gated". Defaulting it
    /// to the first data page, or to anything above the bound, would answer
    /// "no credential needed" about the one tag that certainly needs one.
    func test_aReadGatedProjectionNeedsACredentialForEverything() {
        XCTAssertTrue(needs(.readsGatedPages, readGatedProjection()))
        XCTAssertTrue(needs(.writesDataArea, readGatedProjection()))
        XCTAssertTrue(needs(.writesConfigPages, readGatedProjection()))
    }

    // MARK: The empty intent

    /// Format's answer, and the invariant behind it. Its one write and its
    /// read-back are both page 3, which sits below every AUTH0 this app is able
    /// to put on a tag.
    func test_aFormatNeedsNoCredentialBecauseItsOnePageSitsBelowEveryAUTH0() {
        for state in [open(), writeGated(), configGatedOnly(), readGatedProjection()] {
            XCTAssertFalse(
                needs([], state),
                "an intent that touches nothing gated needs nothing, whatever the tag says"
            )
        }
    }

    // MARK: Most gated wins

    func test_aCombinedIntentTakesTheMostGatedAnswer() {
        XCTAssertTrue(needs([.writesDataArea, .writesConfigPages], configGatedOnly()))
        XCTAssertTrue(needs([.readsGatedPages, .writesConfigPages], writeGated()))
    }
}

/// Every operation states what it touches. Structured so that adding an
/// `Operation` case fails the build here rather than inheriting an answer.
final class OperationsAccessIntentTests: XCTestCase {
    func test_everyOperationStatesWhatItTouches() {
        let pending = PendingProtection(
            settings: TagProtection(passwordProtect: true, protectFromPage: 4),
            credential: .type2(password: Data([1, 2, 3, 4]), pack: Data([5, 6]))
        )

        let table: [(OperationsFlowModel.Operation, TagAccessIntent)] = [
            (.erase, .writesDataArea),
            (.format, []),
            (.permanentLock, .writesConfigPages),
            (.enableProtection(pending), .writesConfigPages),
            (.disableProtection, .writesConfigPages),
            (.setAttemptLimit(limit: 3), .writesConfigPages),
            (.memoryDump, .readsGatedPages),
        ]

        for (operation, expected) in table {
            XCTAssertEqual(
                operation.accessIntent, expected,
                "\(operation) must state what it touches"
            )
        }

        // The census. If this number moves, a case was added and the table
        // above has to grow with it.
        XCTAssertEqual(table.count, 7, "an Operation was added without stating its access intent")
    }

    /// The two operations whose current behaviour this table contradicts, named
    /// so the contradiction is on the record before anything consumes it.
    ///
    /// `execute(.erase)` is `try await tag.writeNDEF([])` with no credential,
    /// and `dumpMemory` reads every page with no credential. Both say here that
    /// they need one on a gated tag. Nothing reads `accessIntent` yet, so this
    /// commit changes no behaviour; it states the target.
    func test_eraseAndDumpBothDeclareAGatedTagNeedsACredential() {
        let gated = TagProtection(passwordProtect: true, protectFromPage: 4, readProtect: true)
        XCTAssertTrue(
            OperationsFlowModel.Operation.erase.accessIntent
                .needsCredential(given: gated, ndefUpperBound: 39)
        )
        XCTAssertTrue(
            OperationsFlowModel.Operation.memoryDump.accessIntent
                .needsCredential(given: gated, ndefUpperBound: 39)
        )
    }
}
