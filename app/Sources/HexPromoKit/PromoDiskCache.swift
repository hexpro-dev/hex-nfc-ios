import Foundation

/// On-disk cache for resolved promos and their media.
///
/// Two things live on disk:
///  - A metadata index (`index.json`) mapping cache key -> `ResolvedPromo`.
///  - One media file per creative, named by its `etag`, so media is reused
///    across fetches whenever the etag is unchanged.
///
/// The cache is an `actor` so all disk I/O happens off the main actor and is
/// serialised without locks. It is intentionally decoupled from any UI so it
/// can be unit-tested against a temp directory.
actor PromoDiskCache {
    private let fileManager = FileManager.default
    private let directory: URL
    private let indexURL: URL

    private var index: [String: ResolvedPromo] = [:]
    private var loaded = false

    init(directory: URL) {
        self.directory = directory
        self.indexURL = directory.appendingPathComponent("index.json")
    }

    /// Default cache location under the system Caches directory.
    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("HexPromo", isDirectory: true)
    }

    // MARK: - Lazy load

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        guard
            let data = try? Data(contentsOf: indexURL),
            let decoded = try? JSONDecoder().decode([String: ResolvedPromo].self, from: data)
        else { return }
        index = decoded
    }

    // MARK: - Reads

    /// The cached promo for a slot, if any (metadata only; media may or may not exist).
    func cachedPromo(for key: String) -> ResolvedPromo? {
        ensureLoaded()
        return index[key]
    }

    /// Local file URL for a promo's media if it is already downloaded, else nil.
    func existingMediaURL(for promo: ResolvedPromo) -> URL? {
        ensureLoaded()
        let url = mediaFileURL(for: promo)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// Whether media for the given etag/type is already on disk.
    func hasMedia(for promo: ResolvedPromo) -> Bool {
        existingMediaURL(for: promo) != nil
    }

    // MARK: - Writes

    /// Persist downloaded media bytes for a promo and return the local file URL.
    @discardableResult
    func storeMedia(for promo: ResolvedPromo, data: Data) throws -> URL {
        ensureLoaded()
        let url = mediaFileURL(for: promo)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Insert/replace the metadata entry for a slot. If the etag changed, the
    /// previous media file is removed when no other slot references it.
    func upsert(key: String, promo: ResolvedPromo) {
        ensureLoaded()
        let previous = index[key]
        index[key] = promo
        persist()
        if let previous, previous.etag != promo.etag {
            deleteMediaIfOrphaned(previous)
        }
    }

    /// Null eviction: drop the metadata entry AND its media file (if unreferenced).
    func evict(key: String) {
        ensureLoaded()
        guard let removed = index.removeValue(forKey: key) else { return }
        persist()
        deleteMediaIfOrphaned(removed)
    }

    // MARK: - Internals

    /// Deterministic file URL for a promo's media, named by a filesystem-safe etag.
    private func mediaFileURL(for promo: ResolvedPromo) -> URL {
        let ext = Self.fileExtension(for: promo)
        let name = "\(Self.sanitize(promo.etag)).\(ext)"
        return directory.appendingPathComponent(name)
    }

    /// Delete a promo's media file only if no remaining entry shares its etag.
    private func deleteMediaIfOrphaned(_ promo: ResolvedPromo) {
        let stillReferenced = index.values.contains { $0.etag == promo.etag }
        guard !stillReferenced else { return }
        try? fileManager.removeItem(at: mediaFileURL(for: promo))
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    // MARK: - Test helpers

    func allKeys() -> [String] {
        ensureLoaded()
        return Array(index.keys)
    }

    func mediaExists(for promo: ResolvedPromo) -> Bool {
        ensureLoaded()
        return fileManager.fileExists(atPath: mediaFileURL(for: promo).path)
    }

    // MARK: - Naming

    /// Replace any character that is not URL/file safe with an underscore.
    static func sanitize(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let mapped = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let result = String(mapped)
        return result.isEmpty ? "media" : result
    }

    /// File extension for a promo's media: prefer the URL's extension, fall back by type.
    static func fileExtension(for promo: ResolvedPromo) -> String {
        if let url = URL(string: promo.mediaUrl) {
            let ext = url.pathExtension
            if !ext.isEmpty { return ext }
        }
        return promo.mediaType == .video ? "mp4" : "img"
    }
}
