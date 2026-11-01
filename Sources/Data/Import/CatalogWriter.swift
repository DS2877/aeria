import Foundation

/// Streams a provider import into `CatalogDatabase`. Each staged slice is
/// normalised and inserted **in small chunks**, so peak memory is one chunk —
/// flat regardless of how large the provider's library is.
///
/// Every row written this import is stamped with a fresh generation number.
/// `finish()` then deletes anything an earlier generation left behind — the
/// provider's removed titles, aged-out EPG — without a destructive up-front wipe,
/// so a background refresh never blanks the screen.
public actor CatalogWriter {

    private let database: CatalogDatabase
    private let normalizer: Normalizer
    private let providerID: String
    private let homeRegions: Set<String>

    /// The generation this import stamps. Resolved in `begin()`.
    private var generation = 1

    /// EPG ids of the channels this import kept — guide data for dropped
    /// (foreign-market) channels is skipped too.
    private var keptEPGIDs: Set<String> = []
    /// The parts this import has ingested — `finish()` prunes only these.
    private var ingested: ImportParts = []

    private var channelCount = 0
    private var movieCount = 0
    private var seriesCount = 0
    private var epgCount = 0

    private static let vodChunk = 2_000
    private static let epgChunk = 5_000
    private static let channelChunk = 5_000

    public init(database: CatalogDatabase, normalizer: Normalizer, providerID: String, homeRegions: Set<String>) {
        self.database = database
        self.normalizer = normalizer
        self.providerID = providerID
        self.homeRegions = homeRegions
    }

    // MARK: - Import lifecycle

    /// Start an import. `fresh` (a cold start / provider switch) wipes the store
    /// first; a refresh writes over the top and lets `finish()` prune the rest.
    public func begin(fresh: Bool) async throws {
        generation = await database.nextGeneration()
        if fresh { try await database.clearCatalog() }
        try await database.setMeta(CatalogDatabase.MetaKey.providerID, providerID)
        try await database.setMeta(CatalogDatabase.MetaKey.importComplete, "0")
    }

    public func finish() async throws {
        try await database.finishGeneration(generation, parts: ingested)
        try await database.refreshFacetCache()
        let now = String(Date().timeIntervalSince1970)
        // Rules apply per row at import — only a full import re-filters it all.
        if ingested == .all {
            try await database.setMeta(CatalogDatabase.MetaKey.relevanceRules, RelevanceFilter.rulesVersion)
        }
        if ingested.contains(.channels) {
            try await database.setMeta(CatalogDatabase.MetaKey.channelCount, String(channelCount))
        }
        if ingested.contains(.vod) {
            try await database.setMeta(CatalogDatabase.MetaKey.movieCount, String(movieCount))
            try await database.setMeta(CatalogDatabase.MetaKey.seriesCount, String(seriesCount))
        }
        if ingested.contains(.guide) {
            try await database.setMeta(CatalogDatabase.MetaKey.epgCount, String(epgCount))
        }
        for part in [ImportParts.channels, .vod, .guide] where ingested.contains(part) {
            try await database.setMeta(CatalogDatabase.MetaKey.importedAt + "." + part.key, now)
        }
        try await database.setMeta(CatalogDatabase.MetaKey.importedAt, now)
        try await database.setMeta(CatalogDatabase.MetaKey.importComplete, "1")
        try? await database.optimize()
    }

    // MARK: - Staged ingest

    public func ingest(_ stage: RawStage) async throws {
        ingested.insert(stage.part)
        switch stage {
        case .channels(let raw):
            try await ingestChannels(raw)
        case .vod(let movies, let shells, let episodes):
            try await ingestVOD(movies: movies, shells: shells, episodes: episodes)
        case .guide(let raw):
            try await ingestGuide(raw)
        case .guidePreview(let raw):
            try await ingestGuide(raw, counts: false)
        }
    }

    // Swedish market only: foreign-market sections are dropped before they're
    // normalised, and every normalised row must pass `RelevanceFilter` — what
    // fails never reaches the store, so no screen or search can show it.

    private func ingestChannels(_ raw: [RawChannel]) async throws {
        let wanted = raw.filter { !RelevanceFilter.isForeignSection($0.groupTitle) }
        for chunk in wanted.chunked(Self.channelChunk) {
            let channels = await normalizer.normalizeChannels(chunk, providerID: providerID)
                .filter { Self.isRelevant($0) }
            try await database.insertChannels(channels, homeRegions: homeRegions, generation: generation)
            keptEPGIDs.formUnion(channels.compactMap(\.epgID))
            channelCount += channels.count
        }
    }

    private func ingestVOD(movies: [RawVODItem], shells: [RawSeriesShell], episodes: [RawSeriesEpisode]) async throws {
        let movies = movies.filter { !RelevanceFilter.isForeignSection($0.groupTitle) }
        let shells = shells.filter { !RelevanceFilter.isForeignSection($0.groupTitle) }
        let episodes = episodes.filter { !RelevanceFilter.isForeignSection($0.groupTitle) }

        for chunk in movies.chunked(Self.vodChunk) {
            let result = await normalizer.normalizeVOD(movies: chunk, shells: [], episodes: [], providerID: providerID)
            let kept = result.movies.filter { Self.isRelevant($0) }
            try await database.insertMovies(kept, generation: generation)
            movieCount += kept.count
        }

        if !shells.isEmpty {
            for chunk in shells.chunked(Self.vodChunk) {
                let result = await normalizer.normalizeVOD(movies: [], shells: chunk, episodes: [], providerID: providerID)
                let kept = result.series.filter { Self.isRelevant($0) }
                try await database.insertSeries(kept, generation: generation)
                seriesCount += kept.count
            }
        }

        if !episodes.isEmpty {
            let result = await normalizer.normalizeVOD(movies: [], shells: [], episodes: episodes, providerID: providerID)
            let kept = result.series.filter { Self.isRelevant($0) }
            for chunk in kept.chunked(500) {
                try await database.insertSeries(chunk, generation: generation)
            }
            seriesCount += kept.count
        }
    }

    private static func isRelevant(_ c: Channel) -> Bool {
        RelevanceFilter.isRelevant(countryCode: c.countryCode, name: c.name, category: c.category,
                                   audioLanguages: c.audioLanguages, subtitleLanguages: c.subtitleLanguages)
    }

    private static func isRelevant(_ m: Movie) -> Bool {
        RelevanceFilter.isRelevant(countryCode: m.countryCode, name: m.title,
                                   category: m.genres.first?.displayName ?? "",
                                   audioLanguages: m.audioLanguages, subtitleLanguages: m.subtitleLanguages)
    }

    private static func isRelevant(_ s: Series) -> Bool {
        RelevanceFilter.isRelevant(countryCode: s.countryCode, name: s.title,
                                   category: s.genres.first?.displayName ?? "",
                                   audioLanguages: s.audioLanguages, subtitleLanguages: s.subtitleLanguages)
    }

    private func ingestGuide(_ raw: [RawEPGEvent], counts: Bool = true) async throws {
        let window = EPGWindow.current()
        // Only guide data for kept channels: this import's, or — on a
        // guide-only refresh — the ones already in the store.
        if keptEPGIDs.isEmpty {
            keptEPGIDs = (try? await database.channelEPGIDs()) ?? []
        }
        let keep = keptEPGIDs
        for chunk in raw.chunked(Self.epgChunk) {
            var events = await normalizer.normalizeGuide(chunk)
            if !keep.isEmpty { events = events.filter { keep.contains($0.channelEPGID) } }
            try await database.insertEPG(events, window: window, generation: generation)
            if counts { epgCount += events.count }
        }
    }

    // MARK: - On-demand episodes (Xtream series)

    public func attachSeasons(rawEpisodes: [RawSeriesEpisode], seriesID: CatalogID) async throws -> [Season] {
        let seasons = normalizer.seasons(forEpisodes: rawEpisodes, seriesID: seriesID, providerID: providerID)
        try await database.replaceSeasons(seasons, seriesID: seriesID)
        return seasons
    }
}

// MARK: - Chunking

extension Array {
    /// Split into consecutive sub-arrays of at most `size` elements.
    func chunked(_ size: Int) -> [[Element]] {
        guard size > 0, count > size else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map { start in
            Array(self[start ..< Swift.min(start + size, count)])
        }
    }
}
