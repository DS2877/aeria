import Foundation

/// In-memory `CatalogQuerying` — the test double. Holds a normalised `Catalog`
/// behind an actor and answers queries with plain array operations. The shipping
/// app uses `SQLiteCatalogRepository`; this stays for fast, disk-free tests.
public actor InMemoryCatalogRepository: CatalogQuerying {

    /// Full imported catalog.
    private var source: Catalog
    /// `source` with adult items removed when `hideAdult` is on — every query
    /// reads this.
    private var catalog: Catalog
    private var ready: Bool
    private var hideAdult = false
    /// When on, foreign-region channels / movies / series are hidden everywhere
    /// (see `RelevanceFilter`). The app switches this on from `UserPreferences`
    /// via `applyPreferences()`; off here so tests see the raw catalog.
    private var regionLimited = false

    // Indexes rebuilt whenever `catalog` changes — keep large-library queries
    // off the O(n) path. The id→item maps store *array indices*, not struct
    // copies: a `[CatalogID: Movie]` for a 50k-title library duplicates ~20 MB
    // of value types for nothing.
    private var epgByChannel: [String: [EPGEvent]] = [:]   // each list sorted by start
    private var movieIndexByID: [CatalogID: Int] = [:]
    private var seriesIndexByID: [CatalogID: Int] = [:]
    private var channelIndexByID: [CatalogID: Int] = [:]
    private var facetGenres: [Genre] = []
    private var facetAudio: [Language] = []
    private var facetSubtitles: [Language] = []
    private var facetCategories: [String] = ["All"]

    public init(catalog: Catalog = Catalog(), ready: Bool = false) {
        self.source = catalog
        self.catalog = catalog
        self.ready = ready
        rebuildVisible()
    }

    public func load(_ catalog: Catalog) {
        self.source = catalog
        self.ready = true
        rebuildVisible()
    }

    /// Phase 1 of a cached start: channels only → the app is interactive.
    public func loadChannelsOnly(_ channels: [Channel]) {
        self.source = Catalog(channels: channels)
        self.ready = true
        rebuildVisible()
    }

    /// Phase 2: movies + series stream in from the cache.
    public func mergeVOD(movies: [Movie], series: [Series]) {
        source.movies = movies
        source.series = series
        rebuildVisible()
    }

    /// Phase 3: EPG. Only re-indexes the guide, not the whole catalog.
    public func mergeEPG(_ events: [EPGEvent]) {
        source.epg = events
        catalog.epg = events
        var index: [String: [EPGEvent]] = [:]
        for event in events { index[event.channelEPGID, default: []].append(event) }
        for key in index.keys { index[key]?.sort { $0.start < $1.start } }
        epgByChannel = index
    }

    public func setHideAdult(_ hide: Bool) {
        guard hide != hideAdult else { return }
        hideAdult = hide
        rebuildVisible()
    }

    public func setRegionLimit(_ limited: Bool) {
        guard limited != regionLimited else { return }
        regionLimited = limited
        rebuildVisible()
    }

    /// Off here (like `regionLimited`) so tests see the raw catalog; the app
    /// sets it from `UserPreferences` via `applyPreferences()`.
    private var channelCountries: Set<String>?

    public func setChannelRegionScope(_ scope: ChannelRegionScope) {
        let next = RelevanceFilter.channelCountryCodes(for: scope, home: homeRegions)
        guard next != channelCountries else { return }
        channelCountries = next
        channelOrderCache = nil
    }

    private func rebuildVisible() {
        movieOrderCache = nil
        seriesOrderCache = nil
        channelOrderCache = nil

        let keepChannel: (Channel) -> Bool = { [hideAdult, regionLimited] c in
            if hideAdult && c.isAdult { return false }
            if regionLimited && !RelevanceFilter.isRelevant(
                countryCode: c.countryCode, name: c.name, category: c.category,
                audioLanguages: c.audioLanguages, subtitleLanguages: c.subtitleLanguages) { return false }
            return true
        }
        let keepMovie: (Movie) -> Bool = { [hideAdult, regionLimited] m in
            if hideAdult && m.isAdult { return false }
            if regionLimited && !RelevanceFilter.isRelevant(
                countryCode: m.countryCode, name: m.title, category: m.genres.first?.displayName ?? "",
                audioLanguages: m.audioLanguages, subtitleLanguages: m.subtitleLanguages) { return false }
            return true
        }
        let keepSeries: (Series) -> Bool = { [hideAdult, regionLimited] s in
            if hideAdult && s.isAdult { return false }
            if regionLimited && !RelevanceFilter.isRelevant(
                countryCode: s.countryCode, name: s.title, category: s.genres.first?.displayName ?? "",
                audioLanguages: s.audioLanguages, subtitleLanguages: s.subtitleLanguages) { return false }
            return true
        }

        if hideAdult || regionLimited {
            catalog = Catalog(
                channels: source.channels.filter(keepChannel),
                movies: source.movies.filter(keepMovie),
                series: source.series.filter(keepSeries),
                epg: source.epg
            )
        } else {
            catalog = source
        }
        rebuildIndexes()
    }

    private func rebuildIndexes() {
        movieIndexByID = Dictionary(catalog.movies.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        seriesIndexByID = Dictionary(catalog.series.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        channelIndexByID = Dictionary(catalog.channels.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })

        var epg: [String: [EPGEvent]] = [:]
        for event in catalog.epg { epg[event.channelEPGID, default: []].append(event) }
        for key in epg.keys { epg[key]?.sort { $0.start < $1.start } }
        epgByChannel = epg

        let genres = Set(catalog.movies.flatMap(\.genres)) .union(catalog.series.flatMap(\.genres))
        facetGenres = Genre.allCases.filter(genres.contains)
        facetAudio = Array(Set(catalog.movies.flatMap(\.audioLanguages)).union(catalog.series.flatMap(\.audioLanguages))).sorted()
        facetSubtitles = Array(Set(catalog.movies.flatMap(\.subtitleLanguages)).union(catalog.series.flatMap(\.subtitleLanguages))).sorted()
        facetCategories = ["All"] + Set(catalog.channels.map(\.category)).sorted()
    }

    public func isReady() -> Bool { ready }

    // MARK: - Channels

    // A one-deep cache of the last sorted+filtered result, stored as *indices*
    // into `catalog.channels` (a few KB) rather than a copy of every struct
    // (megabytes). Browse paginates by asking for page after page of the same
    // query; without a cache each page re-sorts the whole library.
    private var channelOrderCache: (category: String?, sort: ChannelSort, order: [Int])?
    /// The viewer's home country codes (from chosen languages) — channels from
    /// these sort first in `.number` mode. Set via `applyPreferences()`.
    private var homeRegions: Set<String> = ["SE"]
    /// Recently-watched channel ids → recency rank (0 = most recent). These float
    /// to the very top of `.number` mode.
    private var recentChannelRank: [CatalogID: Int] = [:]

    public func setHomeRegions(_ regions: Set<String>) {
        guard regions != homeRegions else { return }
        homeRegions = regions
        channelOrderCache = nil
    }

    public func setRecentChannels(_ ids: [CatalogID]) {
        let rank = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        guard rank != recentChannelRank else { return }
        recentChannelRank = rank
        channelOrderCache = nil
    }

    /// Indices into `catalog.channels`, filtered by category and sorted.
    private func channelOrder(in rawCategory: String?, sort: ChannelSort) -> [Int] {
        let category = (rawCategory == "All") ? nil : rawCategory   // same result either way
        if let c = channelOrderCache, c.category == category, c.sort == sort { return c.order }

        let ch = catalog.channels
        var order = Array(ch.indices)
        if let category {
            order = order.filter { ch[$0].category == category }
        }
        if let allowed = channelCountries {
            order = order.filter { i in
                guard let code = ch[i].countryCode else { return true }   // generic feeds always pass
                return allowed.contains(code)
            }
        }
        switch sort {
        case .number:
            let home = homeRegions
            let recent = recentChannelRank
            order.sort { a, b in
                let lhs = ch[a], rhs = ch[b]
                // 1. channels the viewer actually watches, most recent first
                let lr = recent[lhs.id], rr = recent[rhs.id]
                if (lr != nil) != (rr != nil) { return lr != nil }
                if let lr, let rr, lr != rr { return lr < rr }
                // 2. home country, then other Nordic, then English, then the rest
                let lp = RelevanceFilter.priority(countryCode: lhs.countryCode, home: home)
                let rp = RelevanceFilter.priority(countryCode: rhs.countryCode, home: home)
                if lp != rp { return lp < rp }
                // 3. the provider's channel number, then name
                if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
                return lhs.name.localizedCompare(rhs.name) == .orderedAscending
            }
        case .nameAsc:
            order.sort { ch[$0].name.localizedCompare(ch[$1].name) == .orderedAscending }
        }
        channelOrderCache = (category: category, sort: sort, order: order)
        return order
    }

    public func channels(in category: String?, sort: ChannelSort, page: Int, pageSize: Int) -> [Channel] {
        let ch = catalog.channels
        return channelOrder(in: category, sort: sort).page(page, size: pageSize).map { ch[$0] }
    }

    public func channelTitleAnchors(in category: String?) -> [BrowseAnchor] {
        let ch = catalog.channels
        return Self.anchors(channelOrder(in: category, sort: .nameAsc).map { ch[$0].name })
    }

    public func allChannelCategories() -> [String] { facetCategories }

    // MARK: - Movies / Series

    // Same one-deep index cache as channels above.
    private var movieOrderCache: (filter: CatalogFilter, order: [Int])?
    private var seriesOrderCache: (filter: CatalogFilter, order: [Int])?

    /// Indices into `catalog.movies`, filtered and sorted.
    private func movieOrder(_ filter: CatalogFilter) -> [Int] {
        if let c = movieOrderCache, c.filter == filter { return c.order }
        let mv = catalog.movies
        let order = mv.indices
            .filter { filter.matches(movie: mv[$0]) }
            .sorted { a, b in
                Self.order(mv[a].title, mv[a].year, mv[a].addedAt,
                           mv[b].title, mv[b].year, mv[b].addedAt, filter.sort)
            }
        movieOrderCache = (filter: filter, order: order)
        return order
    }

    private func seriesOrder(_ filter: CatalogFilter) -> [Int] {
        if let c = seriesOrderCache, c.filter == filter { return c.order }
        let sr = catalog.series
        let order = sr.indices
            .filter { filter.matches(series: sr[$0]) }
            .sorted { a, b in
                Self.order(sr[a].title, sr[a].year, sr[a].addedAt,
                           sr[b].title, sr[b].year, sr[b].addedAt, filter.sort)
            }
        seriesOrderCache = (filter: filter, order: order)
        return order
    }

    public func movies(filter: CatalogFilter, page: Int, pageSize: Int) -> [Movie] {
        let mv = catalog.movies
        return movieOrder(filter).page(page, size: pageSize).map { mv[$0] }
    }

    public func series(filter: CatalogFilter, page: Int, pageSize: Int) -> [Series] {
        let sr = catalog.series
        return seriesOrder(filter).page(page, size: pageSize).map { sr[$0] }
    }

    public func moviesCount(filter: CatalogFilter) -> Int { movieOrder(filter).count }
    public func seriesCount(filter: CatalogFilter) -> Int { seriesOrder(filter).count }

    /// First-letter jump targets for an A–Z browse list: the index in the
    /// sorted+filtered result where each initial letter starts.
    public func movieTitleAnchors(filter: CatalogFilter) -> [BrowseAnchor] {
        let mv = catalog.movies
        return Self.anchors(movieOrder(filter).map { mv[$0].title })
    }
    public func seriesTitleAnchors(filter: CatalogFilter) -> [BrowseAnchor] {
        let sr = catalog.series
        return Self.anchors(seriesOrder(filter).map { sr[$0].title })
    }

    private static func anchors(_ titles: [String]) -> [BrowseAnchor] {
        var result: [BrowseAnchor] = []
        var seen = Set<String>()
        for (index, title) in titles.enumerated() {
            let letter = anchorLetter(for: title)
            if seen.insert(letter).inserted {
                result.append(BrowseAnchor(letter: letter, index: index))
            }
        }
        return result
    }

    private static func anchorLetter(for title: String) -> String {
        let stripped = title.folding(options: .diacriticInsensitive, locale: nil)
            .drop { !$0.isLetter && !$0.isNumber }
        guard let first = stripped.first else { return "#" }
        return first.isNumber ? "#" : first.uppercased()
    }
    public func channelsCount(in category: String?) -> Int {
        channelOrder(in: category, sort: .number).count
    }

    public func availableGenres() -> [Genre] { facetGenres }
    public func availableAudioLanguages() -> [Language] { facetAudio }
    public func availableSubtitleLanguages() -> [Language] { facetSubtitles }

    private static func order(_ lt: String, _ ly: Int?, _ la: Date?,
                              _ rt: String, _ ry: Int?, _ ra: Date?,
                              _ sort: BrowseSort) -> Bool {
        switch sort {
        case .recentlyAdded:
            let l = la ?? .distantPast, r = ra ?? .distantPast
            if l != r { return l > r }
            return lt.localizedCompare(rt) == .orderedAscending
        case .titleAscending:
            // Same key the SQLite store sorts on (`title_fold`), so the in-memory
            // repo (tests, demo) pages and anchors in the same order.
            let lf = lt.foldedForSearch(), rf = rt.foldedForSearch()
            if lf != rf { return lf < rf }
            return (ly ?? Int.max) < (ry ?? Int.max)
        case .newest:
            if (ly ?? 0) != (ry ?? 0) { return (ly ?? 0) > (ry ?? 0) }
            return lt.localizedCompare(rt) == .orderedAscending
        case .oldest:
            if (ly ?? Int.max) != (ry ?? Int.max) { return (ly ?? Int.max) < (ry ?? Int.max) }
            return lt.localizedCompare(rt) == .orderedAscending
        }
    }

    public func movie(id: CatalogID) -> Movie? { movieIndexByID[id].map { catalog.movies[$0] } }
    public func series(id: CatalogID) -> Series? { seriesIndexByID[id].map { catalog.series[$0] } }
    public func channel(id: CatalogID) -> Channel? { channelIndexByID[id].map { catalog.channels[$0] } }

    public func randomMovie(filter: CatalogFilter) -> Movie? {
        movieOrder(filter).randomElement().map { catalog.movies[$0] }
    }

    public func randomSeries(filter: CatalogFilter) -> Series? {
        seriesOrder(filter).randomElement().map { catalog.series[$0] }
    }

    public func attachSeasons(_ seasons: [Season], toSeriesID id: CatalogID) {
        if let i = source.series.firstIndex(where: { $0.id == id }) { source.series[i].seasons = seasons }
        // `series(id:)` reads `catalog.series[idx]` live, so mutating it here is
        // enough — no cached struct to refresh.
        if let j = seriesIndexByID[id] { catalog.series[j].seasons = seasons }
        seriesOrderCache = nil
    }

    public func recentlyAdded(limit: Int) -> [SearchResult.Item] {
        let movies = catalog.movies.suffix(limit).reversed().map { SearchResult.Item.movie($0) }
        let series = catalog.series.suffix(limit).reversed().map { SearchResult.Item.series($0) }
        return Array((movies + series).prefix(limit))
    }

    // MARK: - EPG (indexed — each channel's events are pre-sorted by start)

    public func epgEvents(forEPGID epgID: String, in window: DateInterval) -> [EPGEvent] {
        epgByChannel.events(forChannel: epgID, in: window)
    }

    public func nowPlaying(forEPGID epgID: String, at date: Date) -> EPGEvent? {
        epgByChannel.nowPlaying(forChannel: epgID, at: date)
    }

    public func epgIndex() -> [String: [EPGEvent]] { epgByChannel }

    public func snapshot() -> Catalog { catalog }

    /// The full, unfiltered catalog — for persisting to the on-disk cache after
    /// a staged import.
    public func exportCatalog() -> Catalog { source }

    // MARK: - "More Like This"

    public func similarMovies(to id: CatalogID, genres: [Genre], limit: Int) -> [Movie] {
        guard !genres.isEmpty else { return [] }
        let want = Set(genres)
        return catalog.movies
            .filter { $0.id != id && !want.isDisjoint(with: $0.genres) }
            .sorted { lhs, rhs in
                let l = want.intersection(lhs.genres).count
                let r = want.intersection(rhs.genres).count
                if l != r { return l > r }
                return (lhs.addedAt ?? .distantPast) > (rhs.addedAt ?? .distantPast)
            }
            .prefix(limit).map { $0 }
    }

    public func similarSeries(to id: CatalogID, genres: [Genre], limit: Int) -> [Series] {
        guard !genres.isEmpty else { return [] }
        let want = Set(genres)
        return catalog.series
            .filter { $0.id != id && !want.isDisjoint(with: $0.genres) }
            .sorted { lhs, rhs in
                let l = want.intersection(lhs.genres).count
                let r = want.intersection(rhs.genres).count
                if l != r { return l > r }
                return (lhs.addedAt ?? .distantPast) > (rhs.addedAt ?? .distantPast)
            }
            .prefix(limit).map { $0 }
    }

    /// Seeds for the background TMDB enrichment sweep — most recently added
    /// first, since that's what the user browses before anything else.
    public func artworkSeeds(movieLimit: Int, seriesLimit: Int) -> [ArtworkSeed] {
        let movies = catalog.movies
            .sorted { ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }
            .prefix(movieLimit)
            .map { ArtworkSeed(id: $0.id, title: $0.title, year: $0.year, isSeries: false) }
        let series = catalog.series
            .sorted { ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }
            .prefix(seriesLimit)
            .map { ArtworkSeed(id: $0.id, title: $0.title, year: $0.year, isSeries: true) }
        return Array(movies) + Array(series)
    }

    // MARK: - CatalogQuerying (SQLite-era additions)

    public func hasEpisodes(seriesID id: CatalogID) -> Bool {
        guard let index = seriesIndexByID[id] else { return false }
        return catalog.series[index].hasEpisodes
    }

    public func movies(ids: [CatalogID]) -> [Movie] {
        let want = Set(ids)
        return catalog.movies.filter { want.contains($0.id) }
    }

    public func series(ids: [CatalogID]) -> [Series] {
        let want = Set(ids)
        return catalog.series.filter { want.contains($0.id) }
    }

    public func seriesShells(ids: [CatalogID]) -> [Series] { series(ids: ids) }

    public func channels(ids: [CatalogID]) -> [Channel] {
        let want = Set(ids)
        return catalog.channels.filter { want.contains($0.id) }
    }

    public func episode(id: CatalogID) -> Episode? {
        for series in catalog.series {
            for season in series.seasons where season.episodes.contains(where: { $0.id == id }) {
                return season.episodes.first { $0.id == id }
            }
        }
        return nil
    }

    public func epgIndex(forEPGIDs epgIDs: [String], in window: DateInterval) -> [String: [EPGEvent]] {
        var out: [String: [EPGEvent]] = [:]
        for epgID in epgIDs {
            let events = epgByChannel.events(forChannel: epgID, in: window)
            if !events.isEmpty { out[epgID] = events }
        }
        return out
    }

    public func guideChannels(limit: Int) -> [Channel] {
        let channels = catalog.channels
        var result: [Channel] = []
        for index in channelOrder(in: nil, sort: .number) {
            let channel = channels[index]
            guard channel.epgID?.isEmpty == false else { continue }
            result.append(channel)
            if result.count >= limit { break }
        }
        return result
    }

    public func newestMovies(limit: Int) -> [Movie] {
        catalog.movies
            .sorted { ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }
            .prefix(limit).map { $0 }
    }

    public func newestSeries(limit: Int) -> [Series] {
        catalog.series
            .sorted { ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }
            .prefix(limit).map { $0 }
    }

    public func topGenres(limit: Int) -> [Genre] {
        var counts: [Genre: Int] = [:]
        for m in catalog.movies { for g in m.genres { counts[g, default: 0] += 1 } }
        for s in catalog.series { for g in s.genres { counts[g, default: 0] += 1 } }
        return counts.sorted { $0.value > $1.value }.prefix(limit).map(\.key)
    }

    public func moviesInGenre(_ genre: Genre, limit: Int) -> [Movie] {
        newestMovies(limit: .max).filter { $0.genres.contains(genre) }.prefix(limit).map { $0 }
    }

    public func seriesInGenre(_ genre: Genre, limit: Int) -> [Series] {
        newestSeries(limit: .max).filter { $0.genres.contains(genre) }.prefix(limit).map { $0 }
    }

    public func moviesInAudioLanguages(_ languages: [Language], limit: Int) -> [Movie] {
        let want = Set(languages)
        return newestMovies(limit: .max)
            .filter { !want.isDisjoint(with: $0.audioLanguages) }
            .prefix(limit).map { $0 }
    }

    public func moviesInSubtitleLanguage(_ language: Language, limit: Int) -> [Movie] {
        newestMovies(limit: .max)
            .filter { $0.subtitleLanguages.contains(language) }
            .prefix(limit).map { $0 }
    }

    public func resumePoints(progress: [WatchProgress], limit: Int) -> [ResumePoint] {
        UpNext.resumePoints(catalog: catalog, progress: progress, limit: limit)
    }

    public func search(_ intent: SearchIntent, limit: Int) -> [SearchResult] {
        SearchEngine().search(intent, in: catalog, limit: limit)
    }

    public func searchVocabulary() -> SearchVocabulary {
        SearchVocabulary.from(catalog: catalog)
    }
}

// MARK: - Filtering

extension CatalogFilter {
    func matches(movie m: Movie) -> Bool {
        matchesCommon(
            genres: m.genres, audio: m.audioLanguages, subs: m.subtitleLanguages,
            year: m.year, quality: m.quality, duration: m.durationMinutes, title: m.title
        )
    }

    func matches(series s: Series) -> Bool {
        matchesCommon(
            genres: s.genres, audio: s.audioLanguages, subs: s.subtitleLanguages,
            year: s.year, quality: s.quality, duration: nil, title: s.title
        )
    }

    private func matchesCommon(
        genres itemGenres: [Genre],
        audio: [Language],
        subs: [Language],
        year: Int?,
        quality: VideoQuality,
        duration: Int?,
        title: String
    ) -> Bool {
        if !genres.isEmpty, Set(genres).isDisjoint(with: Set(itemGenres)) { return false }
        if !audioLanguages.isEmpty, Set(audioLanguages).isDisjoint(with: Set(audio)) { return false }
        if !subtitleLanguages.isEmpty, Set(subtitleLanguages).isDisjoint(with: Set(subs)) { return false }
        if let minYear { guard let y = year, y >= minYear else { return false } }
        if let maxYear { guard let y = year, y <= maxYear else { return false } }
        if let minQuality, quality < minQuality { return false }
        if let maxDurationMinutes {
            if let d = duration, d > maxDurationMinutes { return false }
        }
        if !text.isEmpty {
            let needle = text.foldedForSearch()
            if !needle.isEmpty, !title.foldedForSearch().contains(needle) { return false }
        }
        return true
    }
}

// MARK: - Pagination

extension Array {
    func page(_ page: Int, size: Int) -> [Element] {
        guard size > 0, page >= 0 else { return [] }
        let start = page * size
        guard start < count else { return [] }
        return Array(self[start..<Swift.min(start + size, count)])
    }
}
