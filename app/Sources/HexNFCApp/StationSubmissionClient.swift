import Foundation

/// Best-effort client for crowd-sourced station-name suggestions.
///
/// When a scanned transit card shows a station the bundled pack can't name, the
/// user can type which station they're at and submit it. Submissions go to the
/// project's web API, where the maintainer reviews and triangulates them before
/// they ship in a later app version — so only vetted data is ever bundled. The
/// user has necessarily *been* to the stop (it's on their card), which makes the
/// suggestion a first-party observation rather than a copied table entry.
///
/// **Privacy (load-bearing):** the payload is ONLY the saibane line/station
/// codes and the name the user typed. The card's IDm/serial, balance, and
/// transaction history are never sent. Every call is **user-initiated** (the
/// user taps Submit), in keeping with the project's no-background-network rule.
public struct StationSubmissionClient: Sendable {
    /// Where suggestions are posted — the shared Hex Pro apps API (same host as
    /// `CostsClient`'s `…/v1/costs/hex-nfc`). `nil` disables submission
    /// gracefully (the UI still accepts the tap and shows "Thanks!", it just
    /// doesn't reach the network).
    private static let endpoint = URL(string: "https://api.apps.hex.pro/v1/station-suggestions")

    public init() {}

    public struct Suggestion: Encodable, Sendable {
        public let line: Int
        public let station: Int
        public let area: Int?
        public let name: String
        /// Card system context (e.g. "0x0003"). Scopes the code for the
        /// maintainer; not card-identifying.
        public let systemCode: String

        public init(line: Int, station: Int, area: Int?, name: String, systemCode: String) {
            self.line = line
            self.station = station
            self.area = area
            self.name = name
            self.systemCode = systemCode
        }
    }

    /// Submit a suggestion. Best-effort: returns `true` on a 2xx, `false`
    /// otherwise (including no endpoint / no network). Never throws, never
    /// blocks the UI.
    @discardableResult
    public func submit(_ suggestion: Suggestion) async -> Bool {
        guard let endpoint = Self.endpoint else { return false }
        guard let body = try? JSONEncoder().encode(suggestion) else { return false }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200 ... 299).contains(http.statusCode)
        } catch {
            return false
        }
    }
}
