import Foundation

// MARK: - Platform

/// The platform reported to the Hex Promo API. This SDK ships for iOS, but the
/// value is configurable so a Mac Catalyst / AppKit host can report "macos".
public enum PromoPlatform: String, Codable, Sendable, CaseIterable {
    case ios
    case android
    case web
    case macos
}

// MARK: - Media type

/// Kind of creative served in a promo slot.
///
/// Decoding is lenient: an unrecognised value falls back to `.image` so a single
/// unexpected creative type never fails the whole batch response.
public enum PromoMediaType: String, Codable, Sendable {
    case image
    case video

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PromoMediaType(rawValue: raw) ?? .image
    }
}

// MARK: - Link type

/// How a promo's tap link should be opened.
///
/// Decoding is lenient: an unrecognised value falls back to `.none` (not
/// tappable) so a future link type never fails decoding or opens the wrong URL.
public enum PromoLinkType: String, Codable, Sendable {
    case web
    case appStore = "app_store"
    case playStore = "play_store"
    case none

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PromoLinkType(rawValue: raw) ?? .none
    }
}

// MARK: - Resolved promo

/// A single active promo returned for a slot. Mirrors the API contract exactly.
public struct ResolvedPromo: Codable, Sendable, Equatable, Identifiable {
    public let creativeId: String
    public let mediaType: PromoMediaType
    /// Absolute URL to the raw media (edge-cached, immutable, content-addressed).
    public let mediaUrl: String
    /// Intrinsic pixel size. May be null in the contract.
    public let width: Int?
    public let height: Int?
    /// Aspect ratio the banner must reserve layout at (e.g. 1200 x 300).
    public let aspectWidth: Int
    public let aspectHeight: Int
    /// Tap target. May be null.
    public let linkUrl: String?
    public let linkType: PromoLinkType
    /// Strong change token used to reuse cached media without re-downloading.
    public let etag: String

    public var id: String { creativeId }

    public init(
        creativeId: String,
        mediaType: PromoMediaType,
        mediaUrl: String,
        width: Int?,
        height: Int?,
        aspectWidth: Int,
        aspectHeight: Int,
        linkUrl: String?,
        linkType: PromoLinkType,
        etag: String
    ) {
        self.creativeId = creativeId
        self.mediaType = mediaType
        self.mediaUrl = mediaUrl
        self.width = width
        self.height = height
        self.aspectWidth = aspectWidth
        self.aspectHeight = aspectHeight
        self.linkUrl = linkUrl
        self.linkType = linkType
        self.etag = etag
    }

    /// Aspect ratio (width / height). Guards against a zero denominator.
    public var aspectRatio: Double {
        aspectHeight == 0 ? 1 : Double(aspectWidth) / Double(aspectHeight)
    }

    /// Whether tapping the banner should open a link.
    public var isTappable: Bool {
        linkType != .none && (linkUrl?.isEmpty == false)
    }
}

// MARK: - Batch result / response

/// One entry in the batch response: the resolved promo for a slot, or `nil`.
public struct PromoResult: Codable, Sendable {
    public let bundleId: String
    public let platform: String
    public let locationId: String
    public let promo: ResolvedPromo?

    /// Cache key identifying this slot: `"bundleId|platform|locationId"`.
    public var cacheKey: String {
        PromoCacheKey.make(bundleId: bundleId, platform: platform, locationId: locationId)
    }
}

/// Top-level batch response body.
public struct BatchResponse: Codable, Sendable {
    public let results: [PromoResult]
}

// MARK: - Batch request

/// A single slot the SDK asks the API to resolve.
struct PromoRequestItem: Codable, Sendable, Hashable {
    let bundleId: String
    let platform: String
    let locationId: String

    var cacheKey: String {
        PromoCacheKey.make(bundleId: bundleId, platform: platform, locationId: locationId)
    }
}

/// Top-level batch request body.
struct BatchRequest: Codable, Sendable {
    let requests: [PromoRequestItem]
}

// MARK: - Cache key

/// Canonical cache key builder, shared by requests, results and the disk cache.
public enum PromoCacheKey {
    public static func make(bundleId: String, platform: String, locationId: String) -> String {
        "\(bundleId)|\(platform)|\(locationId)"
    }
}
