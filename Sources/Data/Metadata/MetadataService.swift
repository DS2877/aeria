import Foundation

/// TMDB-sourced enrichment for one catalog item. Kept as an overlay looked up by
/// `CatalogID` at display time — never merged into the catalog itself.
public struct EnrichedMetadata: Codable, Sendable, Equatable {
    public let tmdbID: Int          // -1 = we searched and found nothing
    public let posterURL: URL?
    public let backdropURL: URL?
    public let overview: String?
    public let rating: Double?       // 0…10
    public let fetchedAt: Date

    // Second-pass detail fields (from /movie/{id} or /tv/{id}). Optional so old
    // cache files still decode.
    public var tagline: String?
    public var genres: [String]?
    public var cast: [String]?
    public var castCredits: [TMDBClient.CastCredit]?
    public var runtime: Int?          // minutes
    public var voteCount: Int?
    public var detailsFetchedAt: Date?

    public var matched: Bool { tmdbID > 0 }
    public var hasDetails: Bool { detailsFetchedAt != nil }

    public init(tmdbID: Int, posterURL: URL?, backdropURL: URL?, overview: String?,
                rating: Double?, fetchedAt: Date,
                tagline: String? = nil, genres: [String]? = nil, cast: [String]? = nil,
                castCredits: [TMDBClient.CastCredit]? = nil,
                runtime: Int? = nil, voteCount: Int? = nil, detailsFetchedAt: Date? = nil) {
        self.tmdbID = tmdbID
        self.posterURL = posterURL
        self.backdropURL = backdropURL
        self.overview = overview
        self.rating = rating
        self.fetchedAt = fetchedAt
        self.tagline = tagline
        self.genres = genres
        self.cast = cast
        self.castCredits = castCredits
        self.runtime = runtime
        self.voteCount = voteCount
        self.detailsFetchedAt = detailsFetchedAt
    }
}

/// Enriches the catalog from TMDB in the background: deduped, rate-limited,
/// persisted to disk. A card asks for its poster on appear; the result fades in
/// when it arrives. No key configured → does nothing and every caller gets nil.
public actor MetadataService {

    private var byID: [String: EnrichedMetadata] = [:]
    private var inFlight: [String: Task<EnrichedMetadata?, Never>] = [:]
    private var detailsInFlight: [String: Task<EnrichedMetadata?, Never>] = [:]
    private var seasonStills: [String: [Int: URL]] = [:]           // "tvID-season" -> [episodeNumber: still]
    private var seasonInFlight: [String: Task<[Int: URL], Never>] = [:]
    private var client: TMDBClient?
    private var lastRequestAt = Date.distantPast
    private var dirty = false
    private var saveTask: Task<Void, Never>?
    private var sweepTask: Task<Void, Never>?

    /// ~8 requests/sec — comfortably inside TMDB's limits.
    private let minInterval: TimeInterval = 0.13
    /// Retry a "no match" after a week in case the title cleaned up.
    private let noMatchRetryAfter: TimeInterval = 7 * 24 * 3600

    private let fileURL: URL

    /// The on-disk cache is decoded on first use, not in `init`.
    ///
    /// `init` runs at the construction site — the main actor, during the first
    /// view build — and after a warm-up sweep this file holds hundreds of
    /// entries. Decoding it there stalled the very first frame. Deferring it
    /// moves the work onto this actor's executor, off the main thread, and it
    /// overlaps with the catalog queries that run at the same moment.
    private var didLoadFromDisk = false

    public init() {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)) ?? URL.temporaryDirectory
        self.fileURL = base.appendingPathComponent("tmdb-metadata.v1.json")
    }

    private func loadFromDiskIfNeeded() {
        guard !didLoadFromDisk else { return }
        didLoadFromDisk = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: EnrichedMetadata].self, from: data)
        else { return }
        byID = decoded
    }

    public func setKey(_ key: String?) {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        client = trimmed.isEmpty ? nil : TMDBClient(apiKey: trimmed)
    }

    public var isEnabled: Bool { client != nil }

    /// Cached value if present; otherwise fetch (deduped). Returns nil when no
    /// key is configured or nothing matched.
    public func metadata(for id: CatalogID, title: String, year: Int?, isSeries: Bool) async -> EnrichedMetadata? {
        loadFromDiskIfNeeded()
        let key = id.rawValue

        if let existing = byID[key] {
            if existing.matched { return existing }
            if Date().timeIntervalSince(existing.fetchedAt) < noMatchRetryAfter { return nil }
        }
        guard client != nil else { return nil }

        if let running = inFlight[key] { return await running.value }

        let task = Task<EnrichedMetadata?, Never> { [weak self] in
            await self?.fetch(key: key, title: title, year: year, isSeries: isSeries) ?? nil
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    /// Full record including cast/genres/runtime/tagline. Does the base search
    /// first if needed, then a second `/movie/{id}` call. For detail screens.
    public func details(for id: CatalogID, title: String, year: Int?, isSeries: Bool) async -> EnrichedMetadata? {
        loadFromDiskIfNeeded()
        let key = id.rawValue

        // Cached with details already? Done. (`castCredits == nil` means the
        // record predates cast-photo support — refetch it once.)
        if let existing = byID[key], existing.matched, existing.hasDetails,
           existing.castCredits != nil {
            return existing
        }
        guard client != nil else { return byID[key]?.matched == true ? byID[key] : nil }

        if let running = detailsInFlight[key] { return await running.value }

        let task = Task<EnrichedMetadata?, Never> { [weak self] in
            guard let self else { return nil }
            let base = await self.metadata(for: id, title: title, year: year, isSeries: isSeries)
            guard let base, base.matched else { return base }
            return await self.fetchDetails(key: key, base: base, isSeries: isSeries)
        }
        detailsInFlight[key] = task
        let result = await task.value
        detailsInFlight[key] = nil
        return result
    }

    /// Per-episode still images for one season, keyed by episode number.
    /// In-memory only (one request per season the user opens).
    public func episodeStills(seriesTMDBID: Int, season: Int) async -> [Int: URL] {
        let key = "\(seriesTMDBID)-\(season)"
        if let cached = seasonStills[key] { return cached }
        guard client != nil else { return [:] }
        if let running = seasonInFlight[key] { return await running.value }

        let task = Task<[Int: URL], Never> { [weak self] in
            await self?.fetchSeasonStills(key: key, tmdbID: seriesTMDBID, season: season) ?? [:]
        }
        seasonInFlight[key] = task
        let result = await task.value
        seasonInFlight[key] = nil
        return result
    }

    private func fetchSeasonStills(key: String, tmdbID: Int, season: Int) async -> [Int: URL] {
        guard let client else { return [:] }
        await throttle()
        let episodes: [TMDBClient.EpisodeStill]
        do { episodes = try await client.season(tvID: tmdbID, seasonNumber: season) }
        catch { return [:] }
        var map: [Int: URL] = [:]
        for episode in episodes {
            if let url = episode.stillURL { map[episode.episodeNumber] = url }
        }
        seasonStills[key] = map
        return map
    }

    /// Crawl the library filling in artwork without waiting for the user to
    /// scroll. Cheap entries first; already-cached ones skip instantly.
    /// `onBatch` fires periodically so the UI can refresh as data lands.
    public func warmUp(_ items: [ArtworkSeed], onBatch: @escaping @Sendable () -> Void = {}) {
        guard client != nil, sweepTask == nil else { return }
        sweepTask = Task(priority: .background) { [weak self] in
            // Let the first screen have the network to itself. The sweep is
            // invisible work; the posters the viewer is looking at are not.
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            var sinceRefresh = 0
            for item in items {
                if Task.isCancelled { break }
                _ = await self?.metadata(for: item.id, title: item.title,
                                         year: item.year, isSeries: item.isSeries)
                sinceRefresh += 1
                if sinceRefresh >= 120 {
                    sinceRefresh = 0
                    onBatch()
                }
            }
            onBatch()
            await self?.endSweep()
        }
    }

    private func endSweep() { sweepTask = nil }

    public func cancelWarmUp() {
        sweepTask?.cancel()
        sweepTask = nil
    }

    private func fetch(key: String, title: String, year: Int?, isSeries: Bool) async -> EnrichedMetadata? {
        guard let client else { return nil }

        await throttle()

        let match: TMDBClient.Match?
        do {
            match = try await client.search(title: title, year: year, isSeries: isSeries)
        } catch {
            return nil   // transient — don't cache a failure, let it retry later
        }

        let record: EnrichedMetadata
        if let match {
            record = EnrichedMetadata(tmdbID: match.tmdbID, posterURL: match.posterURL,
                                      backdropURL: match.backdropURL, overview: match.overview,
                                      rating: match.rating, fetchedAt: Date())
        } else {
            record = EnrichedMetadata(tmdbID: -1, posterURL: nil, backdropURL: nil,
                                      overview: nil, rating: nil, fetchedAt: Date())
        }

        byID[key] = record
        scheduleSave()
        return record.matched ? record : nil
    }

    private func fetchDetails(key: String, base: EnrichedMetadata, isSeries: Bool) async -> EnrichedMetadata? {
        guard let client else { return base }

        await throttle()

        let details: TMDBClient.Details?
        do {
            details = try await client.details(tmdbID: base.tmdbID, isSeries: isSeries)
        } catch {
            return base
        }

        var updated = base
        updated.tagline = details?.tagline
        updated.genres = details?.genres
        updated.cast = details?.cast
        updated.castCredits = details?.castCredits
        updated.runtime = details?.runtime
        updated.voteCount = details?.voteCount
        updated.detailsFetchedAt = Date()

        byID[key] = updated
        scheduleSave()
        return updated
    }

    private func throttle() async {
        let wait = minInterval - Date().timeIntervalSince(lastRequestAt)
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        lastRequestAt = Date()
    }

    private func scheduleSave() {
        dirty = true
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            await self?.flush()
        }
    }

    /// The enrichment cache is bounded. It grows one entry per title the viewer
    /// browses (each with cast credits and overviews), it's re-decoded on every
    /// launch, and on a 40k-title library it would otherwise grow forever.
    /// Trimming keeps the most recently fetched — those are what the viewer is
    /// actually looking at, and a dropped entry costs one re-fetch.
    private static let maxCachedRecords = 4_000

    private func trimIfNeeded() {
        guard byID.count > Self.maxCachedRecords else { return }
        let keep = byID.sorted { $0.value.fetchedAt > $1.value.fetchedAt }
            .prefix(Self.maxCachedRecords * 3 / 4)
        byID = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }

    private func flush() {
        saveTask = nil
        guard dirty else { return }
        dirty = false
        trimIfNeeded()
        if let data = try? JSONEncoder().encode(byID) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// All known TMDB ratings, keyed by `CatalogID.rawValue`. For the Home
    /// "Top Rated" row — cheap, reads the in-memory map.
    #if DEBUG
    /// UI-test screenshots only: fake TMDB ratings so the rating-driven rows
    /// (Top 10, hero ordering) appear without a network key. In-memory —
    /// never saved.
    public func debugSeedRatings(_ ratings: [CatalogID: Double]) {
        loadFromDiskIfNeeded()
        for (id, rating) in ratings {
            byID[id.rawValue] = EnrichedMetadata(tmdbID: 1, posterURL: nil, backdropURL: nil,
                                                 overview: nil, rating: rating, fetchedAt: Date())
        }
    }
    #endif

    public func ratingsSnapshot() -> [String: Double] {
        loadFromDiskIfNeeded()
        var out: [String: Double] = [:]
        for (key, value) in byID where value.matched {
            if let rating = value.rating { out[key] = rating }
        }
        return out
    }

    public func clear() {
        byID.removeAll()
        didLoadFromDisk = true      // nothing on disk worth reading any more
        cancelWarmUp()
        try? FileManager.default.removeItem(at: fileURL)
    }
}

/// Lightweight, `Sendable` seed for the background enrichment sweep.
public struct ArtworkSeed: Sendable, Equatable {
    public let id: CatalogID
    public let title: String
    public let year: Int?
    public let isSeries: Bool

    public init(id: CatalogID, title: String, year: Int?, isSeries: Bool) {
        self.id = id
        self.title = title
        self.year = year
        self.isSeries = isSeries
    }
}
