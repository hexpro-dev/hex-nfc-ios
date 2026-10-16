import Foundation

/// Recovered-vs-total development costs, surfaced on the home screen.
///
/// The figure is owned by the Hex Pro costs API so the app and the
/// apps.hex.pro website stay in sync; this is the in-app representation of
/// that single source of truth.
public struct DonationProgress: Sendable, Equatable {
    public let donated: Double
    public let total: Double
    public let currency: String

    public init(donated: Double, total: Double, currency: String) {
        self.donated = donated
        self.total = total
        self.currency = currency
    }

    /// Shown before the network responds, and whenever the API is unreachable.
    /// The donation figure is live (Stripe → costs API), so the offline
    /// fallback is $0 rather than a stale number. Mirrors `apps/api/v1/costs/data.ts`.
    public static let fallback = DonationProgress(donated: 0, total: 280.02, currency: "AUD")

    /// Recovered share, clamped to `0...1`.
    public var fraction: Double {
        total > 0 ? min(max(donated / total, 0), 1) : 0
    }

    public var percent: Int {
        Int((fraction * 100).rounded())
    }

    public var donatedText: String {
        Self.formatted(donated)
    }

    public var totalText: String {
        Self.formatted(total)
    }

    /// Plain "$" prefix — the figure is AUD and we don't disambiguate the
    /// symbol (the device locale would otherwise render it as "A$"/"US$").
    private static func formatted(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        let number = formatter.string(from: NSNumber(value: value)) ?? "\(value)"
        return "$\(number)"
    }
}

/// Fetches the shared development-costs figure from the Hex Pro costs API,
/// falling back to ``DonationProgress/fallback`` on any error so the UI
/// always has a sensible value to render.
public enum CostsClient {
    public static let endpoint = URL(string: "https://api.apps.hex.pro/v1/costs/hex-nfc")!

    private struct Payload: Decodable {
        let totalCost: Double
        let totalDonations: Double
        let currency: String
    }

    public static func fetch(
        url: URL = endpoint,
        session: URLSession = .shared
    ) async -> DonationProgress {
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            return decode(data: data, response: response)
        } catch {
            return .fallback
        }
    }

    /// Pure decode step, split out so it can be unit-tested without a network.
    static func decode(data: Data, response: URLResponse?) -> DonationProgress {
        guard
            let http = response as? HTTPURLResponse,
            (200 ..< 300).contains(http.statusCode),
            let payload = try? JSONDecoder().decode(Payload.self, from: data),
            payload.totalCost > 0
        else {
            return .fallback
        }
        return DonationProgress(
            donated: payload.totalDonations,
            total: payload.totalCost,
            currency: payload.currency
        )
    }
}
