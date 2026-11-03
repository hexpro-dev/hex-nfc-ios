import Foundation
import Observation

/// The feedback form: what the user has typed, whether it may be sent, and
/// how sending went.
///
/// Opened from the review card's "Send Feedback" and from Settings. A failed
/// send keeps the draft, and offers the same message by email instead, so a
/// person who took the time to write is never left with nothing.
@Observable
@MainActor
public final class FeedbackFormModel {
    public enum Phase: Equatable, Sendable {
        case editing
        case sending
        case sent
        case failed(FeedbackClient.Outcome)
    }

    public var message = ""
    public var email = ""
    public private(set) var phase: Phase = .editing
    public let context: FeedbackContext

    /// The service's own limit. Counted in UTF-16 units because that is how the
    /// service, which runs on JavaScript, measures a string.
    public static let maxLength = 5000
    /// Where "Email us instead" writes to: the same inbox the service delivers
    /// into, so a message sent either way lands in one place.
    static let inbox = "feedback+nfc@hex.pro"

    private let send: @MainActor (FeedbackClient.Submission) async -> FeedbackClient.Outcome

    public init(
        context: FeedbackContext = .current,
        send: @escaping @MainActor (FeedbackClient.Submission) async -> FeedbackClient.Outcome = {
            await FeedbackClient().send($0)
        }
    ) {
        self.context = context
        self.send = send
    }

    var trimmedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `nil` when the field is empty, which means "no reply wanted".
    var trimmedEmail: String? {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public var isTooLong: Bool {
        trimmedMessage.utf16.count > Self.maxLength
    }

    /// Loose on purpose: the service runs the strict check, and this only
    /// catches the typo the user can fix before tapping Send. An empty field
    /// is fine.
    public var emailLooksValid: Bool {
        guard let address = trimmedEmail else { return true }
        return address.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil
    }

    public var canSend: Bool {
        switch phase {
        case .sending, .sent:
            false

        case .editing, .failed:
            !trimmedMessage.isEmpty && !isTooLong && emailLooksValid
        }
    }

    public func submit() async {
        guard canSend else { return }
        phase = .sending
        let outcome = await send(FeedbackClient.Submission(
            message: trimmedMessage,
            email: trimmedEmail,
            context: context
        ))
        phase = outcome == .sent ? .sent : .failed(outcome)
    }

    /// The draft as an email, for when the service can't be reached.
    ///
    /// The subject and the detail labels stay in English: they are addressed
    /// to the inbox, where they sort and get read, not to the person sending.
    /// The message itself is the user's own words, untouched.
    public var mailtoURL: URL? {
        let details = [
            "",
            "--",
            "App version: \(context.appVersion)",
            "iOS version: \(context.osVersion)",
            "Device: \(context.deviceModel)",
            "Language: \(context.localization)",
        ]
        let body = ([trimmedMessage] + details).joined(separator: "\n")
        return URL(
            string: "mailto:\(Self.inbox)?subject=\(Self.mailEncoded("Hex NFC feedback"))&body=\(Self.mailEncoded(body))"
        )
    }

    /// RFC 6068 wants everything but the unreserved set encoded in a header
    /// value, and `URLComponents` leaves `+` and `&` alone, which some mail
    /// apps then read as a space and a new field. Spelled out as ASCII because
    /// `CharacterSet.alphanumerics` also lets through every non-Latin letter,
    /// and a Japanese message would then make no URL at all.
    private static let unreserved = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
    )

    private static func mailEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}
