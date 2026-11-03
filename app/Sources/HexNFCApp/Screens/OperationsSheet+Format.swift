#if os(iOS)
import HexNFCDesign
import HexNFCKit
import SwiftUI

// Split from `OperationsSheet.swift`, which reached its length limit. The
// Format screen sits in the sheet's Dangerous Actions grid like the rest; it
// lives here only so the sheet's file has room for the operations that follow.

struct FormatOperationView: View {
    @Bindable var appModel: AppModel
    var onTagChanged: (TagObservation) -> Void = { _ in }
    @State private var model: OperationsFlowModel

    init(appModel: AppModel, onTagChanged: @escaping (TagObservation) -> Void = { _ in }) {
        self.appModel = appModel
        self.onTagChanged = onTagChanged
        _model = State(initialValue: OperationsFlowModel(
            factory: appModel.sessionFactory,
            operation: .format,
            credentials: appModel.library.tagCredentials,
            activity: appModel.reviewPrompt
        ))
    }

    var body: some View {
        OperationContainer(
            title: "Format",
            // Scoped the same way the Erase intro is, and for the same reason:
            // no chip is known until the tap, so every sentence has to hold for
            // both families. "It does not touch the data area." was true of the
            // Type-2 path and false of the Type-5 one, which wrote an empty
            // message over block 1 and took a SLIX2 owner's records with it
            // (2026-09-22). `Type5Formatter` now seeds that empty message only
            // into a blank area, so the promise holds everywhere and the user is
            // sent to the operation that does mean to clear a tag.
            intro: "Write the Capability Container so the chip declares itself as an NDEF tag. Use this on a fresh chip that wasn't shipped pre-formatted.\n\nRecords already on the tag stay where they are. A tag that has never held a message gets an empty one, so a reader sees a blank tag rather than a broken one. To clear a tag that has records on it, use Erase.\n\nOn a blank MIFARE DESFire card, Format creates the NDEF application the card needs before it can hold records. Remove NDEF setup takes it off again."
        ) {
            destructiveBody(
                model: model,
                alert: String(localized: "Hold tag to format."),
                actionTitle: "Format tag",
                // The old warning ("Existing NDEF records become unreadable
                // until rewritten") contradicted the intro above and was not
                // true of either family: Type-2 refuses the write outright
                // unless page 3 is still blank, and a Type-5 tag reads the same
                // records back through the CC this writes. What is worth saying
                // is the part that cannot be taken back.
                warning: "This writes the Capability Container. On the chips that keep it in a write-once page there is no second attempt. Your records are left in place.",
                onTagChanged: onTagChanged
            )
        }
        .operationMoments(model)
    }
}
#endif
