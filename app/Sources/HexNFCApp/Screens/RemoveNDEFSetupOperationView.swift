#if os(iOS)
import HexNFCDesign
import HexNFCKit
import SwiftUI

/// Remove NDEF setup: the undo for Format on a MIFARE DESFire.
///
/// Like every tile in the sheet it is opened before a tag is tapped, so its
/// copy has to hold for whatever card turns up. What it promises is narrow on
/// purpose: it acts only on a card whose sole application is the NDEF setup this
/// app makes and whose master key is still the factory key, and the first tap
/// refuses anything else before the user is asked to type a UID.
struct RemoveNDEFSetupOperationView: View {
    @Bindable var appModel: AppModel
    var onTagChanged: (TagObservation) -> Void = { _ in }
    @State private var model: OperationsFlowModel

    init(appModel: AppModel, onTagChanged: @escaping (TagObservation) -> Void = { _ in }) {
        self.appModel = appModel
        self.onTagChanged = onTagChanged
        _model = State(initialValue: OperationsFlowModel(
            factory: appModel.sessionFactory,
            operation: .removeNDEFSetup,
            credentials: appModel.library.tagCredentials,
            activity: appModel.reviewPrompt
        ))
    }

    var body: some View {
        OperationContainer(
            title: "Remove NDEF setup",
            intro: "Return a MIFARE DESFire card that Format set up for NDEF to blank, with no applications on it. Use it to start a card over or to give it back all its memory.\n\nIt works only on a card whose sole application is the NDEF setup Hex NFC makes, and whose master key is still the factory key. Any other card is left as it is."
        ) {
            destructiveBody(
                model: model,
                alert: String(localized: "Hold card to remove its NDEF setup."),
                actionTitle: "Remove NDEF setup",
                warning: "This deletes the card's NDEF application and every record in it. The card is left blank.",
                onTagChanged: onTagChanged
            )
        }
        .operationMoments(model)
    }
}
#endif
