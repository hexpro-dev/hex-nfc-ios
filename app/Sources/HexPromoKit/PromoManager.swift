import Foundation
import Combine

// MARK: - Resolution state

/// The observable state of a single promo slot.
public enum PromoResolution: Sendable, Equatable {
    /// Not yet known. The banner renders nothing (collapsed).
    case unresolved
    /// Resolved to no active promo. The banner stays collapsed.
    case empty
    /// An active promo whose media is available at `mediaURL` (a local file).
    case resolved(ResolvedPromo, mediaURL: URL)

    public var promo: ResolvedPromo? {
        if case let .resolved(promo, _) = self { return promo }
        return nil
    }
}

// MARK: - PromoManager

/// Singleton that batches slot registrations into one API call, caches results
/// and media to disk, and publishes the resolved state per slot.
///
/// Lifecycle for a banner:
/// 1. On appear it calls ``register(bundleId:platform:locationId:)``.
/// 2. The manager immediately serves any cached result (offline-first).
/// 3. Registrations are debounced (~250 ms) and sent as ONE batch request.
/// 4. Results update `promos`; media is downloaded (reusing by etag); nulls evict.
@MainActor
public final class PromoManager: ObservableObject {

    /// Production default base URL.
    public static let defaultBaseURL = "https://api.p.hex.pro"

    /// Shared singleton. Banners read state from here; `configure` is optional.
    public static let shared = PromoManager()

    /// Published resolution per cache key (`"bundleId|platform|locationId"`).
    @Published public private(set) var promos: [String: PromoResolution] = [:]

    private var baseURL: URL
    private let session: URLSession
    private let cache: PromoDiskCache
    private let debounceNanos: UInt64

    /// All slots currently registered, keyed by cache key.
    private var registrations: [String: PromoRequestItem] = [:]
    private var pendingFetch: Task<Void, Never>?

    // MARK: Init

    private init() {
        self.baseURL = URL(string: PromoManager.defaultBaseURL)!
        let configuration = URLSessionConfiguration.default
        // The SDK owns its media cache; don't double-cache batch responses.
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: configuration)
        self.cache = PromoDiskCache(directory: PromoDiskCache.defaultDirectory())
        self.debounceNanos = 250_000_000
    }

    /// Designated initializer used by tests to inject a base URL, session
    /// (with a URLProtocol stub) and cache directory.
    init(
        baseURL: URL,
        session: URLSession,
        cache: PromoDiskCache,
        debounceNanos: UInt64 = 250_000_000
    ) {
        self.baseURL = baseURL
        self.session = session
        self.cache = cache
        self.debounceNanos = debounceNanos
    }

    // MARK: Configuration

    /// Override the API base URL. Optional; defaults to production.
    public func configure(baseURL: URL) {
        self.baseURL = baseURL
    }

    /// Convenience string overload.
    public func configure(baseURLString: String) {
        if let url = URL(string: baseURLString) {
            self.baseURL = url
        }
    }

    // MARK: Registration

    /// Register a slot. Idempotent; safe to call every time a banner appears.
    public func register(bundleId: String, platform: PromoPlatform = .ios, locationId: String) {
        let item = PromoRequestItem(
            bundleId: bundleId,
            platform: platform.rawValue,
            locationId: locationId
        )
        let key = item.cacheKey
        registrations[key] = item
        if promos[key] == nil {
            promos[key] = .unresolved
        }
        // Serve any cached result immediately (offline-first).
        Task { await serveCached(key: key) }
        scheduleFetch()
    }

    /// Current resolution for a slot (unresolved if unknown).
    public func resolution(for key: String) -> PromoResolution {
        promos[key] ?? .unresolved
    }

    // MARK: Debounced batch fetch

    private func scheduleFetch() {
        pendingFetch?.cancel()
        let delay = debounceNanos
        pendingFetch = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            if Task.isCancelled { return }
            await self?.performBatchFetch()
        }
    }

    /// Force an immediate batch fetch, bypassing the debounce (used in tests).
    func flushNow() async {
        pendingFetch?.cancel()
        await performBatchFetch()
    }

    private func performBatchFetch() async {
        let items = Array(registrations.values)
        guard !items.isEmpty else { return }

        let url = baseURL.appendingPathComponent("v1/promos/batch")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONEncoder().encode(BatchRequest(requests: items))
            let (data, response) = try await session.data(for: request)
            guard
                let http = response as? HTTPURLResponse,
                (200..<300).contains(http.statusCode)
            else {
                throw URLError(.badServerResponse)
            }
            let decoded = try JSONDecoder().decode(BatchResponse.self, from: data)
            await apply(results: decoded.results)
        } catch {
            // Network/parse failure -> offline fallback from cache.
            await applyOfflineFallback(for: items)
        }
    }

    // MARK: Applying results

    private func apply(results: [PromoResult]) async {
        for result in results {
            let key = result.cacheKey
            // Ignore results for slots that unregistered in the meantime.
            guard registrations[key] != nil else { continue }

            if let promo = result.promo {
                await resolve(key: key, promo: promo)
            } else {
                // Null eviction: drop metadata + media, then collapse.
                await cache.evict(key: key)
                setState(.empty, for: key)
            }
        }
    }

    private func resolve(key: String, promo: ResolvedPromo) async {
        do {
            let mediaURL = try await downloadMediaIfNeeded(promo)
            await cache.upsert(key: key, promo: promo)
            guard registrations[key] != nil else { return }
            setState(.resolved(promo, mediaURL: mediaURL), for: key)
        } catch {
            // Media download failed; fall back to any cached media for this slot.
            if let cached = await cache.cachedPromo(for: key),
               let mediaURL = await cache.existingMediaURL(for: cached) {
                setState(.resolved(cached, mediaURL: mediaURL), for: key)
            }
            // Otherwise leave prior state (collapsed) untouched.
        }
    }

    /// Reuse the cached media file if the etag is unchanged, else download it.
    private func downloadMediaIfNeeded(_ promo: ResolvedPromo) async throws -> URL {
        if let existing = await cache.existingMediaURL(for: promo) {
            return existing
        }
        guard let mediaURL = URL(string: promo.mediaUrl) else {
            throw URLError(.badURL)
        }
        let (data, response) = try await session.data(from: mediaURL)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try await cache.storeMedia(for: promo, data: data)
    }

    private func applyOfflineFallback(for items: [PromoRequestItem]) async {
        for item in items {
            let key = item.cacheKey
            if case .resolved = promos[key] { continue }
            if let cached = await cache.cachedPromo(for: key),
               let mediaURL = await cache.existingMediaURL(for: cached) {
                setState(.resolved(cached, mediaURL: mediaURL), for: key)
            }
            // Nothing cached -> stay collapsed (unresolved renders nothing).
        }
    }

    private func setState(_ state: PromoResolution, for key: String) {
        guard promos[key] != state else { return }
        promos[key] = state
    }

    private func serveCached(key: String) async {
        // Only fill in from cache while still unresolved; never clobber live state.
        guard case .unresolved = resolution(for: key) else { return }
        guard
            let cached = await cache.cachedPromo(for: key),
            let mediaURL = await cache.existingMediaURL(for: cached)
        else { return }
        guard case .unresolved = resolution(for: key) else { return }
        setState(.resolved(cached, mediaURL: mediaURL), for: key)
    }
}
