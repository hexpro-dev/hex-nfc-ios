import Foundation

/// Sends a feedback message from the app to Hex Pro.
///
/// The message goes to the contact service on api.hex.pro, which stores it and
/// mails it to feedback+nfc@hex.pro. That service sends nothing back to the
/// address the user typed: with no captcha in front of it, a reply-by-mail
/// would let anyone use our domain to flood a stranger's inbox.
///
/// **Privacy (load-bearing):** the payload is the message and the optional
/// reply address the user typed, plus the four values the form shows them
/// beside the Send button (app version, iOS version, device model, app
/// language). Nothing read from a tag, nothing from history, and no trace. Every
/// call is **user-initiated**: the user taps Send.
public struct FeedbackClient: Sendable {
    static let endpoint = URL(string: "https://api.hex.pro/v1/contact/app-feedback")

    public struct Submission: Encodable, Sendable, Equatable {
        /// The service routes on this; it maps to the inbox address server-side,
        /// so no address the client sends is ever trusted.
        public let app: String
        public let message: String
        /// Omitted from the JSON when the user gave none.
        public let email: String?
        public let appVersion: String
        public let osVersion: String
        public let deviceModel: String
        public let locale: String

        public init(
            message: String,
            email: String?,
            context: FeedbackContext
        ) {
            app = "hex-nfc"
            self.message = message
            self.email = email
            appVersion = context.appVersion
            osVersion = context.osVersion
            deviceModel = context.deviceModel
            locale = context.localization
        }
    }

    public enum Outcome: Sendable, Equatable {
        case sent
        /// The service's per-address limit: a few messages an hour.
        case rateLimited
        /// The service looked at the message and refused it, which a form that
        /// validates first should only see when the two disagree.
        case rejected
        /// No answer at all: offline, a timeout, or the service down.
        case unreachable
    }

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Never throws and never blocks the UI.
    public func send(_ submission: Submission) async -> Outcome {
        guard let request = Self.request(for: submission) else { return .unreachable }
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unreachable }
            return Self.outcome(forStatus: http.statusCode)
        } catch {
            return .unreachable
        }
    }

    static func request(for submission: Submission) -> URLRequest? {
        guard let endpoint, let body = try? JSONEncoder().encode(submission) else { return nil }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        return request
    }

    static func outcome(forStatus status: Int) -> Outcome {
        switch status {
        case 200 ... 299: .sent
        case 429: .rateLimited
        case 400 ... 499: .rejected
        default: .unreachable
        }
    }
}

/// The four values that travel with a feedback message, gathered once so the
/// form can show the user exactly what it will send.
public struct FeedbackContext: Sendable, Equatable {
    /// "1.0.2 (52)": marketing version and build, as Settings shows them.
    public let appVersion: String
    /// "26.1", or "26.1.2" when there is a patch number.
    public let osVersion: String
    /// The hardware identifier, "iPhone17,2". NFC behaviour differs by
    /// antenna, so this is often the first question about a bad read.
    public let deviceModel: String
    /// The localisation the app's own strings resolved to ("en", "ja",
    /// "zh-Hans"), which is the language the message is most likely in.
    public let localization: String

    public init(appVersion: String, osVersion: String, deviceModel: String, localization: String) {
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.deviceModel = deviceModel
        self.localization = localization
    }

    public static var current: FeedbackContext {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        return FeedbackContext(
            appVersion: "\(version) (\(build))",
            osVersion: osVersion(ProcessInfo.processInfo.operatingSystemVersion),
            deviceModel: hardwareModel(),
            localization: Bundle.main.preferredLocalizations.first ?? "en"
        )
    }

    static func osVersion(_ version: OperatingSystemVersion) -> String {
        let base = "\(version.majorVersion).\(version.minorVersion)"
        return version.patchVersion == 0 ? base : "\(base).\(version.patchVersion)"
    }

    /// `utsname.machine`. On a simulator that is the Mac's architecture, which
    /// is honest about where the message came from.
    private static func hardwareModel() -> String {
        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: &system.machine) { buffer in
            String(bytes: buffer.prefix { $0 != 0 }, encoding: .utf8) ?? ""
        }
        return machine.isEmpty ? "unknown" : machine
    }
}
