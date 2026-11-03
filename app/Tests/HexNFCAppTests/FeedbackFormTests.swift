@testable import HexNFCApp
import XCTest

/// The feedback form and the request it sends.
///
/// The service's contract (`pro/api/v1/contact/app-feedback.ts` in hex-web)
/// counts the message in UTF-16 units, treats an absent email as "no reply
/// wanted", and answers 429 at its rate limit. These pin the app's half.
@MainActor
final class FeedbackFormTests: XCTestCase {
    private let context = FeedbackContext(
        appVersion: "1.0.2 (52)",
        osVersion: "26.1",
        deviceModel: "iPhone17,2",
        localization: "ja"
    )

    private func form(
        answering outcome: FeedbackClient.Outcome = .sent,
        sent: @escaping (FeedbackClient.Submission) -> Void = { _ in }
    ) -> FeedbackFormModel {
        FeedbackFormModel(context: context) { submission in
            sent(submission)
            return outcome
        }
    }

    // MARK: - What may be sent

    func test_emptyOrBlankMessage_cannotBeSent() {
        let model = form()
        XCTAssertFalse(model.canSend)
        model.message = "  \n "
        XCTAssertFalse(model.canSend)
        model.message = "The write failed on my NTAG216."
        XCTAssertTrue(model.canSend)
    }

    /// The limit is the service's, in UTF-16 units: 5000 two-unit characters is
    /// twice what it takes.
    func test_tooLong_isMeasuredInUTF16Units() {
        let model = form()
        model.message = String(repeating: "a", count: FeedbackFormModel.maxLength)
        XCTAssertTrue(model.canSend)

        model.message = String(repeating: "😀", count: FeedbackFormModel.maxLength / 2 + 1)
        XCTAssertTrue(model.isTooLong)
        XCTAssertFalse(model.canSend)
    }

    func test_email_isOptional_butMustLookLikeOneWhenGiven() {
        let model = form()
        model.message = "Hello"
        XCTAssertTrue(model.canSend, "no email is fine")

        model.email = "not an address"
        XCTAssertFalse(model.emailLooksValid)
        XCTAssertFalse(model.canSend)

        model.email = " someone@example.com "
        XCTAssertTrue(model.canSend)
    }

    // MARK: - Sending

    func test_submit_sendsTrimmedTextAndTheShownContext() async {
        var captured: FeedbackClient.Submission?
        let model = form { captured = $0 }
        model.message = "  The card keeps dropping.  \n"
        model.email = " someone@example.com "

        await model.submit()

        XCTAssertEqual(model.phase, .sent)
        XCTAssertEqual(captured?.app, "hex-nfc")
        XCTAssertEqual(captured?.message, "The card keeps dropping.")
        XCTAssertEqual(captured?.email, "someone@example.com")
        XCTAssertEqual(captured?.appVersion, "1.0.2 (52)")
        XCTAssertEqual(captured?.osVersion, "26.1")
        XCTAssertEqual(captured?.deviceModel, "iPhone17,2")
        XCTAssertEqual(captured?.locale, "ja")
    }

    func test_submit_failure_keepsTheDraftAndAllowsAnotherGo() async {
        let model = form(answering: .unreachable)
        model.message = "Hello"

        await model.submit()

        XCTAssertEqual(model.phase, .failed(.unreachable))
        XCTAssertEqual(model.message, "Hello")
        XCTAssertTrue(model.canSend)
    }

    func test_submit_afterSending_doesNotSendTwice() async {
        var sends = 0
        let model = form { _ in sends += 1 }
        model.message = "Hello"

        await model.submit()
        await model.submit()

        XCTAssertEqual(sends, 1)
    }

    // MARK: - The request

    /// No email means the key is absent, which the service reads as "no reply
    /// wanted", rather than an empty string it would have to interpret.
    func test_request_omitsAnAbsentEmail() throws {
        let submission = FeedbackClient.Submission(message: "Hello", email: nil, context: context)
        let request = try XCTUnwrap(FeedbackClient.request(for: submission))
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.hex.pro/v1/contact/app-feedback")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(json["email"])
        XCTAssertEqual(json, [
            "app": "hex-nfc",
            "message": "Hello",
            "appVersion": "1.0.2 (52)",
            "osVersion": "26.1",
            "deviceModel": "iPhone17,2",
            "locale": "ja",
        ])
    }

    func test_outcome_mapsTheServicesStatuses() {
        XCTAssertEqual(FeedbackClient.outcome(forStatus: 200), .sent)
        XCTAssertEqual(FeedbackClient.outcome(forStatus: 429), .rateLimited)
        XCTAssertEqual(FeedbackClient.outcome(forStatus: 400), .rejected)
        XCTAssertEqual(FeedbackClient.outcome(forStatus: 503), .unreachable)
    }

    func test_osVersion_dropsAZeroPatch() {
        let plain = OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0)
        let patched = OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 2)
        XCTAssertEqual(FeedbackContext.osVersion(plain), "26.1")
        XCTAssertEqual(FeedbackContext.osVersion(patched), "26.1.2")
    }

    // MARK: - Email instead

    /// The fallback carries the message and the same details, and survives
    /// characters that are not ASCII and characters a mail app would misread.
    func test_mailto_carriesTheMessageAndDetails() throws {
        let model = form()
        model.message = "タグが読めません & 1+1"

        let url = try XCTUnwrap(model.mailtoURL)
        XCTAssertTrue(url.absoluteString.hasPrefix("mailto:feedback+nfc@hex.pro?subject=Hex%20NFC%20feedback&body="))
        let body = try XCTUnwrap(url.absoluteString.components(separatedBy: "&body=").last?.removingPercentEncoding)
        XCTAssertTrue(body.hasPrefix("タグが読めません & 1+1\n"))
        XCTAssertTrue(body.contains("App version: 1.0.2 (52)"))
        XCTAssertTrue(body.contains("Device: iPhone17,2"))
        XCTAssertFalse(url.absoluteString.contains("&1"), "the ampersand in the message is encoded")
    }
}
