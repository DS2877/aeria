import Foundation

/// `CatalogQuerying` over `CatalogDatabase`. Owns the visibility state
/// (adult / region / home regions / recent channels) and translates it into
/// the `Scope` every query takes.
///
/// An `actor` for its small mutable state; the heavy work runs on the database
/// actor it calls into, which serialises SQLite access.
public actor SQLiteCatalogRepository: CatalogQuerying {

    private let database: CatalogDatabase
    private let searchEngine: SearchEngine

    private var hideAdult = false
    private var regionLimited = false
    private var homeRegions: Set<String> = ["SE"]
    /// Country codes a channel may carry to be visible in Live TV / Guide / the
    /// Home live rows. `nil` = no channel-country filter. Set from
    /// `UserPreferences` on every launch before the app goes interactive.
    private var channelCountries: Set<String>?

    public init(database: CatalogDatabase, searchEngine: SearchEngine = SearchEngine()) {
        self.database = database
        self.searchEngine = searchEngine
    }

    private var scope: CatalogDatabase.Scope {
        CatalogDatabase.Scope(showAdult: !hideAdult, allRegions: !regionLimited,
                              channelCountries: channelCountries)
    }

    /// Run a throwing database read, logging and falling back on failure — a
    /// query hiccup should degrade a screen, never crash it.
    private func read<T>(_ fallback: T, _ body: () async throws -> T) async -> T {
        do { return try await body() }
        catch {
            AppLog.app.error("Catalog query failed: \(String(describing: error))")
            return fallback
        }
    }

    /// `read` for queries that return an optional — nothing found and a query
    /// error both yield `nil`.
    private func readOptional<T>(_ body: () async throws -> T?) async -> T? {
        do { return try await body() }
        catch {
            AppLog.app.error("Catalog query failed: \(String(describing: error))")
            return nil
        }
    }

    // MARK: - Readiness

    public func isReady() async -> Bool {
        await database.importIsComplete()
    }

    // MARK: - Visibility

    public func setHideAdult(_ hide: Bool) async { hideAdult = hide }
    public func setRegionLimit(_ limited: Bool) async { regionLimited = limited }

    /// How wide a net channel queries cast, resolved against the current home
    /// regions. Purely a query-time filter — no re-import, no column rewrite.
    public func setChannelRegionScope(_ scope: ChannelRegionScope) async {
        channelCountries = RelevanceFilter.channelCountryCodes(for: scope, home: homeRegions)
    }

    /// Both of these rewrite a column across the whole `channel` table, so they
    /// are gated on the value actually changing — otherwise every launch pays a
    /// full-table scan for nothing. The last-applied values live in `meta`, so
    /// the gate survives a relaunch, not just this process.
    public func setHomeRegions(_ regions: Set<String>) async {
        guard regions != homeRegions else { return }
        homeRegions = regions
        let stamp = regions.sorted().joined(separator: ",")
        let applied = (try? await database.metaValue(Self.homeRegionsKey)) ?? nil
        guard applied != stamp else { return }
        try? await database.updateRegionPriorities(homeRegions: regions)
        try? await database.setMeta(Self.homeRegionsKey, stamp)
    }

    public func setRecentChannels(_ ids: [CatalogID]) async {
        let stamp = ids.map(\.rawValue).joined(separator: ",")
        guard stamp != lastRecentStamp else { return }
        lastRecentStamp = stamp
        let applied = (try? await database.metaValue(Self.recentChannelsKey)) ?? nil
        guard applied != stamp else { return }
        try? await database.updateRecentChannels(ids)
        try? await database.setMeta(Self.recentChannelsKey, stamp)
    }

    private var lastRecentStamp: String?
    private static let homeRegionsKey = "applied_home_regions"
    private static let recentChannelsKey = "applied_recent_channels"

    // MARK: - Channels

    public func channels(in category: String?, sort: ChannelSort, page: Int, pageSize: Int) async -> [Channel] {
        await read([]) { try await database.channels(category: category, sort: sort, scope, page: page, pageSize: pageSize) }
    }

    public func channelsCount(in category: String?) async -> Int {
        await read(0) { try await database.channelCount(category: category, scope) }
    }

    public func channelTitleAnchors(in category: String?) async -> [BrowseAnchor] {
        await read([]) { try await database.channelNameAnchors(category: category, scope) }
    }

    public func allChannelCategories() async -> [String] {
        await read(["All"]) { try await database.channelCategories() }
    }

    public func channel(id: CatalogID) async -> Channel? {
        await readOptional { try await database.channel(id: id) }
    }

    // MARK: - Movies / series

    public func movies(filter: CatalogFilter, page: Int, pageSize: Int) async -> [Movie] {
        await read([]) { try await database.movies(filter, scope, page: page, pageSize: pageSize) }
    }

    public func series(filter: CatalogFilter, page: Int, pageSize: Int) async -> [Series] {
        await read([]) { try await database.series(filter, scope, page: page, pageSize: pageSize) }
    }

    public func moviesCount(filter: CatalogFilter) async -> Int {
        await read(0) { try await database.movieCount(filter, scope) }
    }

    public func seriesCount(filter: CatalogFilter) async -> Int {
        await read(0) { try await database.seriesCount(filter, scope) }
    }

    public func movieTitleAnchors(filter: CatalogFilter) async -> [BrowseAnchor] {
        await read([]) { try await database.movieTitleAnchors(filter, scope) }
    }

    public func seriesTitleAnchors(filter: CatalogFilter) async -> [BrowseAnchor] {
        await read([]) { try await database.seriesTitleAnchors(filter, scope) }
    }

    public func movie(id: CatalogID) async -> Movie? {
        await readOptional { try await database.movie(id: id) }
    }

    public func series(id: CatalogID) async -> Series? {
        await readOptional { try await database.series(id: id) }
    }

    public func randomMovie(filter: CatalogFilter) async -> Movie? {
        await readOptional { try await database.randomMovie(filter, scope) }
    }

    public func randomSeries(filter: CatalogFilter) async -> Series? {
        await readOptional { try await database.randomSeries(filter, scope) }
    }

    public func attachSeasons(_ seasons: [Season], toSeriesID id: CatalogID) async {
        try? await database.replaceSeasons(seasons, seriesID: id)
    }

    public func hasEpisodes(seriesID: CatalogID) async -> Bool {
        await read(false) { try await database.hasEpisodes(seriesID: seriesID) }
    }

    // MARK: - Facets

    public func browseCategories(series: Bool) async -> (collections: [BrowseCategory], genres: [BrowseCategory]) {
        let collections = await read([]) { try await database.collections(series: series, scope) }
        let genres = await read([]) { try await database.genreCategories(series: series, scope) }
        return (collections, genres)
    }

    public func availableGenres() async -> [Genre] {
        await read([]) { try await database.presentGenres() }
    }

    public func availableAudioLanguages() async -> [Language] {
        await read([]) { try await database.presentLanguages(subtitles: false) }
    }

    public func availableSubtitleLanguages() async -> [Language] {
        await read([]) { try await database.presentLanguages(subtitles: true) }
    }

    // MARK: - Batch id lookups

    public func movies(ids: [CatalogID]) async -> [Movie] {
        await read([]) { try await database.moviesByID(ids) }
    }

    public func series(ids: [CatalogID]) async -> [Series] {
        await read([]) { try await database.seriesWithSeasons(ids: ids) }
    }

    public func seriesShells(ids: [CatalogID]) async -> [Series] {
        await read([]) { try await database.seriesByID(ids) }
    }

    public func channels(ids: [CatalogID]) async -> [Channel] {
        await read([]) { try await database.channelsByID(ids) }
    }

    public func episode(id: CatalogID) async -> Episode? {
        await readOptional { try await database.episode(id: id) }
    }

    // MARK: - EPG

    public func epgEvents(forEPGID epgID: String, in window: DateInterval) async -> [EPGEvent] {
        await read([]) { try await database.epgEvents(epgID: epgID, in: window) }
    }

    public func nowPlaying(forEPGID epgID: String, at date: Date) async -> EPGEvent? {
        await readOptional { try await database.nowPlaying(epgID: epgID, at: date) }
    }

    /// Guide programmes matching `text`, on now or starting within a day.
    public func searchProgrammes(text: String, limit: Int) async -> [ProgrammeHit] {
        let now = Date()
        let window = DateInterval(start: now, end: now.addingTimeInterval(24 * 3600))
        return await read([]) { try await database.searchProgrammes(text: text, in: window, scope, limit: limit) }
    }

    public func epgIndex(forEPGIDs epgIDs: [String], in window: DateInterval) async -> [String: [EPGEvent]] {
        await read([:]) { try await database.epgIndex(epgIDs: epgIDs, in: window) }
    }

    public func guideChannels(limit: Int) async -> [Channel] {
        await read([]) { try await database.guideChannels(limit: limit, scope) }
    }

    // MARK: - Home / discovery

    public func recentlyAdded(limit: Int) async -> [SearchResult.Item] {
        await read([]) {
            let movies = try await database.recentlyAddedMovies(limit: limit, scope).map { SearchResult.Item.movie($0) }
            let series = try await database.recentlyAddedSeries(limit: limit, scope).map { SearchResult.Item.series($0) }
            return Array((movies + series).prefix(limit))
        }
    }

    public func newestMovies(limit: Int) async -> [Movie] {
        await read([]) { try await database.recentlyAddedMovies(limit: limit, scope) }
    }

    public func newestSeries(limit: Int) async -> [Series] {
        await read([]) { try await database.recentlyAddedSeries(limit: limit, scope) }
    }

    public func topGenres(limit: Int) async -> [Genre] {
        await read([]) { Array(try await database.genreCounts(scope).prefix(limit).map(\.genre)) }
    }

    public func moviesInGenre(_ genre: Genre, limit: Int) async -> [Movie] {
        await read([]) { try await database.moviesInGenre(genre, scope, limit: limit) }
    }

    public func seriesInGenre(_ genre: Genre, limit: Int) async -> [Series] {
        await read([]) { try await database.seriesInGenre(genre, scope, limit: limit) }
    }

    public func moviesInAudioLanguages(_ languages: [Language], limit: Int) async -> [Movie] {
        await read([]) { try await database.moviesInAudioLanguages(languages, scope, limit: limit) }
    }

    public func moviesInSubtitleLanguage(_ language: Language, limit: Int) async -> [Movie] {
        await read([]) { try await database.moviesInSubtitleLanguage(language, scope, limit: limit) }
    }

    public func similarMovies(to id: CatalogID, genres: [Genre], limit: Int) async -> [Movie] {
        await read([]) { try await database.similarMovies(to: id, genres: genres, scope, limit: limit) }
    }

    public func similarSeries(to id: CatalogID, genres: [Genre], limit: Int) async -> [Series] {
        await read([]) { try await database.similarSeries(to: id, genres: genres, scope, limit: limit) }
    }

    public func resumePoints(progress: [WatchProgress], limit: Int) async -> [ResumePoint] {
        await read([]) {
            let movieIDs = progress.filter { $0.kind == .movie }.map(\.itemID)
            let episodeIDs = progress.filter { $0.kind == .series }.map(\.itemID)

            let movies = try await database.moviesByID(movieIDs)
            let episodes = try await database.episodesByID(episodeIDs)
            let seriesIDs = Array(Set(episodes.map(\.seriesID)))
            let series = try await database.seriesWithSeasons(ids: seriesIDs)

            let miniCatalog = Catalog(channels: [], movies: movies, series: series)
            return UpNext.resumePoints(catalog: miniCatalog, progress: progress, limit: limit)
        }
    }

    // MARK: - Search

    public func search(_ intent: SearchIntent, limit: Int) async -> [SearchResult] {
        await read([]) {
            let filter = CatalogFilter(intent: intent)
            let wantMovies = intent.kinds.isEmpty || intent.kinds.contains(.movie)
            let wantSeries = intent.kinds.isEmpty || intent.kinds.contains(.series)
            let wantChannels = intent.kinds.contains(.liveChannel)
                || (intent.kinds.isEmpty && !intent.freeText.isEmpty)

            let candidateCap = Swift.max(limit * 4, 400)
            let movies = wantMovies ? try await database.movieCandidates(filter, scope, limit: candidateCap) : []
            let series = wantSeries ? try await database.seriesCandidates(filter, scope, limit: candidateCap) : []
            let channels = wantChannels
                ? try await database.channelCandidates(text: intent.freeText, scope, limit: candidateCap)
                : []

            let candidates = Catalog(channels: channels, movies: movies, series: series)
            return searchEngine.search(intent, in: candidates, limit: limit)
        }
    }

    public func searchVocabulary() async -> SearchVocabulary {
        await read(SearchVocabulary()) {
            let genres = try await database.presentGenres()
            let audio = try await database.presentLanguages(subtitles: false)
            let subs = try await database.presentLanguages(subtitles: true)
            return SearchVocabulary(
                genres: genres.isEmpty ? Genre.allCases : genres.sorted { $0.rawValue < $1.rawValue },
                audioLanguages: audio,
                subtitleLanguages: subs,
                hasMovies: try await database.hasRows("movie"),
                hasSeries: try await database.hasRows("series"),
                hasLiveTV: try await database.hasRows("channel")
            )
        }
    }

    // MARK: - Metadata warm-up

    public func artworkSeeds(movieLimit: Int, seriesLimit: Int) async -> [ArtworkSeed] {
        await read([]) { try await database.artworkSeeds(movieLimit: movieLimit, seriesLimit: seriesLimit) }
    }
}
