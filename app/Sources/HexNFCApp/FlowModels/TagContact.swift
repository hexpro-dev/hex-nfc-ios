import HexNFCKit

/// How a session ended when it ended with no tag ever in play.
///
/// Neither is a failure. The user closed an empty sheet, or held nothing to
/// the phone until iOS gave up, and there is nothing about a tag to report
/// because there was never a tag. A reviewer with no NFC tag to hand meets
/// one of these on the app's main button, and a red "Scan failed" was the
/// answer they got.
public enum NoTagEnd: Equatable, Sendable {
    /// The user closed the system NFC sheet.
    case cancelled
    /// iOS ended the session at its time limit.
    case timedOut
}

/// Whether a flow has had a tag in play, across every session it has opened.
///
/// A cancel or a timeout is reported quietly only while this says no tag has
/// ever been in play, and that is kept per flow rather than per session on
/// purpose. The same two errors reach a flow on the second tap of a two-tap
/// write, on the re-tap after an unlock prompt and on a retry after a slipped
/// tag, and an earlier session of that flow may already have written records,
/// burned lock bits or changed a password. Dismissing that quietly would hide a
/// half-finished change behind a closed sheet, which is the report CLAUDE.md
/// forbids: a partial commit is reported as partial.
///
/// Three things keep the answer on the careful side:
///
///  * A tag handed up by any session marks the flow for good. Nothing clears
///    it, not a retry, not a cancel back to the start: a flow model lives for
///    one presentation of its screen, and a new presentation builds a new one.
///    The one screen that replaces its model inside a presentation is Set
///    attempt limit, whose Start over hands the limit back to the stepper. It
///    passes the old model's answer to the new one
///    (`OperationsFlowModel.init(..., earlierRunMayHaveTouchedATag:)`), so the
///    recovery tap after an arm that slipped is reported like any other.
///  * The error has to vouch for itself. `TagError.endedBeforeAnyTag` is set
///    only by the session that would have seen a tag, so a cancel that lands
///    while a detected tag is still being identified keeps today's report.
///  * Any other ending counts as contact. An error this type cannot account
///    for may have come from a tag, so it is treated as though it did.
struct TagContact {
    /// `true` once any session of this flow has had a tag, or has ended in a
    /// way that cannot rule one out.
    private(set) var mayHaveTouchedATag: Bool

    /// A fresh flow, or one that carries on from an earlier model of the same
    /// presentation and must keep what that model knew.
    init(mayHaveTouchedATag: Bool = false) {
        self.mayHaveTouchedATag = mayHaveTouchedATag
    }

    /// A session handed a tag up.
    mutating func tagArrived() {
        mayHaveTouchedATag = true
    }

    /// How a session that ended in `error` should be reported.
    ///
    /// `nil` means exactly as it always has been, with the error on screen.
    /// A value means the session ended with nothing in the field and nothing
    /// earlier in the flow touched a tag either, so there is no failure to
    /// report. Any `nil` answer also records contact, so every later ending in
    /// this flow is reported in full.
    mutating func quietEnding(for error: Error) -> NoTagEnd? {
        guard !mayHaveTouchedATag,
              let error = error as? TagError,
              error.endedBeforeAnyTag
        else {
            mayHaveTouchedATag = true
            return nil
        }
        switch error.kind {
        case .sessionCancelled:
            return .cancelled

        case .sessionTimeout:
            return .timedOut

        default:
            mayHaveTouchedATag = true
            return nil
        }
    }
}
