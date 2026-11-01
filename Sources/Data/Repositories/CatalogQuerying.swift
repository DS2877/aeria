import Foundation

/// The read model the feature layer depends on, backed by `CatalogDatabase`.
///
/// This is the SQLite-era replacement for `CatalogRepository`. The whole-catalog
/// escape hatches (`snapshot()`, `epgIndex()`) are gone — every screen is served
/// by a bounded query so memory never scales with library size.
///
/// Every method is `async`: the implementation hops to the database actor.
public protocol CatalogQuerying: Sendable {

    /// A completed import exists.
    func isReady() async -> Bool

    // MARK: Visibility

    /// Exclude adult-flagged items from every query.
    func setHideAdult(_ hide: Bool) async
    /// Hide foreign-region items everywhere (see `RelevanceFilter`).
    func setRegionLimit(_ limited: Bool) async
    /// How wide a net Live TV / Guide / the Home live rows cast for channels.
    func setChannelRegionScope(_ scope: ChannelRegionScope) async
    /// The viewer's home country codes — channels from these sort first.
    func setHomeRegions(_ regions: Set<String>) async
    /// Recently-watched channel ids, most recent first — they float to the top
    /// of the "for you" channel order.
    func setRecentChannels(_ ids: [CatalogID]) async

    // MARK: Channels

    func channels(in category: String?, sort: ChannelSort, page: Int, pageSize: Int) async -> [Channel]
    func channelsCount(in category: String?) async -> Int
    func channelTitleAnchors(in category: String?) async -> [BrowseAnchor]
    func allChannelCategories() async -> [String]
    func channel(id: CatalogID) async -> Channel?

    // MARK: Movies / series

    func movies(filter: CatalogFilter, page: Int, pageSize: Int) async -> [Movie]
    func series(filter: CatalogFilter, page: Int, pageSize: Int) async -> [Series]
    func moviesCount(filter: CatalogFilter) async -> Int
    func seriesCount(filter: CatalogFilter) async -> Int
    func movieTitleAnchors(filter: CatalogFilter) async -> [BrowseAnchor]
    func seriesTitleAnchors(filter: CatalogFilter) async -> [BrowseAnchor]

    func movie(id: CatalogID) async -> Movie?
    /// The series with its full season / episode tree attached.
    func series(id: CatalogID) async -> Series?

    /// A random visible movie / series matching `filter` — for "Surprise Me".
    func randomMovie(filter: CatalogFilter) async -> Movie?
    func randomSeries(filter: CatalogFilter) async -> Series?
    /// Replace one series' episodes after an on-demand fetch (Xtream).
    func attachSeasons(_ seasons: [Season], toSeriesID id: CatalogID) async
    func hasEpisodes(seriesID: CatalogID) async -> Bool

    // MARK: Facets

    func availableGenres() async -> [Genre]
    /// Category browsing for Movies (`series == false`) or Series: the
    /// provider's own sections and the genres, each with a count and artwork.
    func browseCategories(series: Bool) async -> (collections: [BrowseCategory], genres: [BrowseCategory])
    func availableAudioLanguages() async -> [Language]
    func availableSubtitleLanguages() async -> [Language]

    // MARK: Batch id lookups (Favorites, History, Top Shelf)

    func movies(ids: [CatalogID]) async -> [Movie]
    func series(ids: [CatalogID]) async -> [Series]
    /// Series without their season / episode trees — for cards / shelves that
    /// only show the title + poster (much cheaper than `series(ids:)`).
    func seriesShells(ids: [CatalogID]) async -> [Series]
    func channels(ids: [CatalogID]) async -> [Channel]
    func episode(id: CatalogID) async -> Episode?

    // MARK: EPG

    func epgEvents(forEPGID epgID: String, in window: DateInterval) async -> [EPGEvent]
    func nowPlaying(forEPGID epgID: String, at date: Date) async -> EPGEvent?
    /// EPG for a set of channels inside a window, grouped by EPG id.
    func epgIndex(forEPGIDs epgIDs: [String], in window: DateInterval) async -> [String: [EPGEvent]]
    /// Channels that carry a guide, "for you" order, capped.
    func guideChannels(limit: Int) async -> [Channel]

    // MARK: Home / discovery

    func recentlyAdded(limit: Int) async -> [SearchResult.Item]
    func newestMovies(limit: Int) async -> [Movie]
    func newestSeries(limit: Int) async -> [Series]
    func topGenres(limit: Int) async -> [Genre]
    func moviesInGenre(_ genre: Genre, limit: Int) async -> [Movie]
    func seriesInGenre(_ genre: Genre, limit: Int) async -> [Series]
    func moviesInAudioLanguages(_ languages: [Language], limit: Int) async -> [Movie]
    func moviesInSubtitleLanguage(_ language: Language, limit: Int) async -> [Movie]
    func similarMovies(to id: CatalogID, genres: [Genre], limit: Int) async -> [Movie]
    func similarSeries(to id: CatalogID, genres: [Genre], limit: Int) async -> [Series]

    /// Continue-Watching / Up-Next, resolved against the stored catalog.
    func resumePoints(progress: [WatchProgress], limit: Int) async -> [ResumePoint]

    // MARK: Search

    func search(_ intent: SearchIntent, limit: Int) async -> [SearchResult]
    /// TV-guide programmes whose title matches `text`, on now or later today.
    func searchProgrammes(text: String, limit: Int) async -> [ProgrammeHit]
    /// The library-derived vocabulary a query parser resolves against.
    func searchVocabulary() async -> SearchVocabulary

    // MARK: Metadata warm-up

    func artworkSeeds(movieLimit: Int, seriesLimit: Int) async -> [ArtworkSeed]
}
