import Foundation
import Observation

@MainActor
@Observable
public final class HomeViewModel {

    public private(set) var content: HomeContent = .empty
    public private(set) var isBuilding = false

    private let repository: any CatalogQuerying
    private let watchProgress: WatchProgressStore
    private let preferences: PreferencesStore
    private let metadata: MetadataService
    private let channelHistory: ChannelHistoryStore
    private let favorites: FavoritesStore

    /// During a staged import the catalog + metadata revisions bump many times a
    /// second. Without coalescing, every bump spawns another full-catalog shaping
    /// pass; a handful running at once is enough to jetsam the app on device.
    private var pendingRebuild: Task<Void, Never>?

    public init(repository: any CatalogQuerying,
                watchProgress: WatchProgressStore,
                preferences: PreferencesStore,
                metadata: MetadataService,
                channelHistory: ChannelHistoryStore,
                favorites: FavoritesStore) {
        self.repository = repository
        self.watchProgress = watchProgress
        self.preferences = preferences
        self.metadata = metadata
        self.channelHistory = channelHistory
        self.favorites = favorites
    }

    /// The provider whose snapshot this screen belongs to — set by the view so
    /// a cached screen is never shown for a different provider's library.
    private var snapshotProviderID: String?

    /// Paint the last shaped screen from disk. Returns `true` when something was
    /// restored, so the caller knows the first frame is already populated.
    @discardableResult
    public func restoreSnapshot(providerID: String) -> Bool {
        snapshotProviderID = providerID
        guard content.isEmpty, let cached = HomeSnapshotStore.load(providerID: providerID) else { return false }
        content = cached
        return true
    }

    /// Coalesced: rapid callers (import revisions, preference changes) collapse
    /// into a single shaping pass ~300 ms after the last trigger.
    ///
    /// The **first** build skips the debounce entirely — on launch there is
    /// nothing to coalesce, and 300 ms of dead time before the first query is
    /// exactly the stall this screen must not have.
    public func rebuild(now: Date = .now) async {
        pendingRebuild?.cancel()
        let immediate = !hasBuiltOnce
        hasBuiltOnce = true
        let task = Task { [weak self] in
            if !immediate { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled, let self else { return }
            await self.performRebuild(now: now)
        }
        pendingRebuild = task
        await task.value
        if pendingRebuild == task { pendingRebuild = nil }
    }

    /// Gates the debounce only. A restored snapshot doesn't count — the first
    /// *live* build still runs immediately. (Whether re-entering Home needs a
    /// rebuild at all is `SectionModels`' business, not this flag's.)
    private var hasBuiltOnce = false

    /// How much of the library each shelf query pulls.
    ///
    /// Split in two: the **fast** pass fetches only what the top of the screen
    /// shows and paints it; the **full** pass tops up the shelves below the
    /// fold. Both are bounded, so Home's working set never scales with the
    /// library — the whole reason for the SQLite store.
    private enum Slice {
        /// Fast pass — the hero pool and the first shelves. `makeContent` only
        /// ever renders `prefix(30)` of these, so anything more is wasted decode.
        static let fastMovies = 90
        static let fastSeries = 40
        static let liveNow = 18

        /// Full pass.
        static let perGenreMovies = 20
        static let perGenreSeries = 8
        static let topGenres = 5
        static let languageShelf = 24
        static let guideChannels = 60
    }

    private func performRebuild(now: Date) async {
        isBuilding = true
        defer { isBuilding = false }
        // Timed so a "Home is slow" report can be pinned to a phase from the
        // device console (filter: subsystem com.aeriaplus.appletv, category app).
        let startedAt = Date()

        let prefs = preferences.preferences
        let progress = watchProgress.allEntries()
        let recentChannelIDs = channelHistory.recent(limit: 16)
        // Favourite movies / series, most recently hearted first — the "My List" row.
        let favoriteIDs = favorites.all().filter { $0.kind != .liveChannel }.map(\.itemID)

        guard await repository.isReady() else {
            if content.isEmpty { content = .empty }
            return
        }
        guard !Task.isCancelled else { return }

        // ── Fast pass ────────────────────────────────────────────────────────
        // A handful of small queries, then paint. Everything visible without
        // scrolling comes from here.
        let newestMovies = await repository.newestMovies(limit: Slice.fastMovies)
        let newestSeries = await repository.newestSeries(limit: Slice.fastSeries)
        let liveNow = await repository.channels(in: nil, sort: .number, page: 0, pageSize: Slice.liveNow)
        guard !Task.isCancelled else { return }

        let resume = await repository.resumePoints(progress: progress, limit: 12)
        let ratings = await metadata.ratingsSnapshot()
        // My List sits near the top, so its containers are resolved in the fast
        // pass. Favourites are deliberate and few — two bounded id-batch lookups,
        // and the series come back as shells (the cards only show a poster).
        let favMovies = await repository.movies(ids: favoriteIDs)
        let favSeries = await repository.seriesShells(ids: favoriteIDs)
        guard !Task.isCancelled else { return }

        // Only the Live Now strip needs "on now" for the first paint.
        let nowWindow = DateInterval(start: now.addingTimeInterval(-3600),
                                     end: now.addingTimeInterval(6 * 3600))
        let liveEPG = await repository.epgIndex(forEPGIDs: liveNow.compactMap(\.epgID), in: nowWindow)
        guard !Task.isCancelled else { return }

        let fastCatalog = Catalog(channels: liveNow,
                                  movies: Self.uniqued(favMovies + newestMovies),
                                  series: Self.uniqued(favSeries + newestSeries),
                                  epg: liveEPG.values.flatMap { $0 })
        let fastInputs = ShapeInputs(catalog: fastCatalog, epg: liveEPG, liveNow: liveNow,
                                     recentChannelIDs: recentChannelIDs, resume: resume,
                                     favoriteIDs: favoriteIDs)
        let fastContent = await Self.shape(fastInputs, progress: progress, prefs: prefs,
                                           ratings: ratings, now: now)
        guard !Task.isCancelled else { return }
        content = fastContent
        AppLog.app.info("Home fast pass painted in \(Int(Date().timeIntervalSince(startedAt) * 1000), privacy: .public) ms · \(self.content.rows.count, privacy: .public) rows")

        // ── Full pass ────────────────────────────────────────────────────────
        // Everything below the fold. The screen is already interactive; this
        // only ever adds rows.
        guard !Task.isCancelled else { return }

        let guideChannels = await repository.guideChannels(limit: Slice.guideChannels)

        let topGenres = await repository.topGenres(limit: Slice.topGenres)
        var genreMovies: [Movie] = []
        var genreSeries: [Series] = []
        for genre in topGenres {
            genreMovies += await repository.moviesInGenre(genre, limit: Slice.perGenreMovies)
            genreSeries += await repository.seriesInGenre(genre, limit: Slice.perGenreSeries)
            guard !Task.isCancelled else { return }
        }

        let langMovies = prefs.preferredAudioLanguages.isEmpty ? []
            : await repository.moviesInAudioLanguages(prefs.preferredAudioLanguages, limit: Slice.languageShelf)
        let subMovies: [Movie]
        if let sub = prefs.preferredSubtitleLanguage {
            subMovies = await repository.moviesInSubtitleLanguage(sub, limit: Slice.languageShelf)
        } else {
            subMovies = []
        }
        guard !Task.isCancelled else { return }

        // "Because You Watched" — genre-similar to up to 2 recently played
        // titles (Home shows a row per anchor). The resume points already name
        // the containers, so no extra lookup pass beyond the anchors themselves.
        var becauseMovies: [Movie] = []
        var becauseSeries: [Series] = []
        for anchor in await watchedAnchors(resume: resume, limit: Self.becauseYouWatchedAnchorLimit) {
            becauseMovies += await repository.similarMovies(to: anchor.id, genres: anchor.genres, limit: 20)
            becauseSeries += await repository.similarSeries(to: anchor.id, genres: anchor.genres, limit: 12)
        }
        guard !Task.isCancelled else { return }

        // Continue Watching containers, so the shaper can resolve their cards.
        let resumeMovies = await repository.movies(ids: resume.filter { !$0.isSeries }.map(\.containerID))
        let resumeSeries = await repository.seriesShells(ids: resume.filter(\.isSeries).map(\.containerID))
        guard !Task.isCancelled else { return }

        let allMovies = Self.uniqued(favMovies + newestMovies + resumeMovies + genreMovies + langMovies + subMovies + becauseMovies)
        let allSeries = Self.uniqued(favSeries + newestSeries + resumeSeries + genreSeries + becauseSeries)
        let channels = Self.uniqued(liveNow + guideChannels)

        let fullWindow = DateInterval(start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(18 * 3600))
        let epg = await repository.epgIndex(forEPGIDs: channels.compactMap(\.epgID), in: fullWindow)
        guard !Task.isCancelled else { return }

        let fullCatalog = Catalog(channels: channels, movies: allMovies, series: allSeries,
                                  epg: epg.values.flatMap { $0 })
        let fullInputs = ShapeInputs(catalog: fullCatalog, epg: epg, liveNow: liveNow,
                                     recentChannelIDs: recentChannelIDs, resume: resume,
                                     favoriteIDs: favoriteIDs)
        let shaped = await Self.shape(fullInputs, progress: progress, prefs: prefs,
                                      ratings: ratings, now: now)
        guard !Task.isCancelled else { return }
        content = shaped
        lastInputs = fullInputs
        AppLog.app.info("Home full pass in \(Int(Date().timeIntervalSince(startedAt) * 1000), privacy: .public) ms · \(shaped.rows.count, privacy: .public) rows · ~\(RuntimeStats.memoryHeadroomMB, privacy: .public) MB headroom")

        // Cache the finished screen for the next launch. Throttled: the catalog
        // revision bumps repeatedly during an import, and each save is a JSON
        // encode of several hundred cards. The last one before the app closes is
        // the only one that matters.
        if let providerID = snapshotProviderID,
           Date().timeIntervalSince(lastSnapshotSave) > Self.snapshotInterval {
            lastSnapshotSave = Date()
            let toCache = shaped
            Task.detached(priority: .background) {
                HomeSnapshotStore.save(toCache, providerID: providerID)
            }
        }
    }

    private var lastSnapshotSave = Date.distantPast

    /// Everything the last full pass fetched from the store. Kept so changes
    /// that only affect *shaping* (new TMDB ratings) re-run the pure builder
    /// over what's already in memory instead of ~20 store queries.
    private var lastInputs: ShapeInputs?

    struct ShapeInputs: Sendable {
        let catalog: Catalog
        let epg: EPGIndex
        let liveNow: [Channel]
        let recentChannelIDs: [CatalogID]
        let resume: [ResumePoint]
        let favoriteIDs: [CatalogID]
    }

    /// Runs `makeContent` off the main actor — sorting and shaping a few
    /// hundred titles is real work, and doing it on the main thread is what
    /// makes focus movement hitch while Home refreshes.
    nonisolated private static func shape(
        _ inputs: ShapeInputs, progress: [WatchProgress], prefs: UserPreferences,
        ratings: [String: Double], now: Date
    ) async -> HomeContent {
        await Task.detached(priority: .userInitiated) {
            HomeViewModel.makeContent(catalog: inputs.catalog, epg: inputs.epg, progress: progress,
                        prefs: prefs, ratings: ratings, liveNow: inputs.liveNow,
                        recentChannelIDs: inputs.recentChannelIDs, now: now,
                        resumePoints: inputs.resume, favoriteIDs: inputs.favoriteIDs)
        }.value
    }

    /// New TMDB ratings landed (the background sweep). Only the Top Rated row
    /// and hero ordering can change, so re-shape what's already fetched rather
    /// than rebuilding from the store. Falls back to a full rebuild when
    /// nothing has been fetched yet.
    public func refreshRatings() async {
        // A rebuild already queued will read the new ratings itself.
        guard pendingRebuild == nil else { return }
        guard let inputs = lastInputs else {
            await rebuild()
            return
        }
        let ratings = await metadata.ratingsSnapshot()
        let shaped = await Self.shape(inputs, progress: watchProgress.allEntries(),
                                      prefs: preferences.preferences, ratings: ratings, now: .now)
        // A full rebuild that started meanwhile wins — it has fresher inputs.
        guard pendingRebuild == nil else { return }
        content = shaped
    }

    /// How many recently watched titles get their own "Because You Watched"
    /// row. Shared by the actor-side prefetch (`watchedAnchors`) and the pure
    /// row builder (`mostRecentWatchedAnchors`) so the two can't drift apart.
    nonisolated static let becauseYouWatchedAnchorLimit = 2
    private static let snapshotInterval: TimeInterval = 20

    /// Up to `limit` distinct recently played titles that still carry genre
    /// tags, newest first — each is a "Because You Watched" anchor, resolved
    /// from the resume points the store already built.
    ///
    /// Series come back as shells in one id-batch lookup — only `.genres` is
    /// read here, so pulling each show's full season tree (what `series(id:)`
    /// does) is wasted decode on the launch path.
    private func watchedAnchors(resume: [ResumePoint], limit: Int) async -> [(id: CatalogID, genres: [Genre])] {
        let ordered = resume.sorted { $0.lastWatched > $1.lastWatched }
        let shells = await repository.seriesShells(ids: ordered.filter(\.isSeries).map(\.containerID))
        let shellByID = Dictionary(shells.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<CatalogID> = []
        var anchors: [(id: CatalogID, genres: [Genre])] = []
        for point in ordered {
            guard anchors.count < limit else { break }
            guard seen.insert(point.containerID).inserted else { continue }
            if point.isSeries {
                if let show = shellByID[point.containerID], !show.genres.isEmpty {
                    anchors.append((id: show.id, genres: show.genres))
                }
            } else if let movie = await repository.movie(id: point.containerID), !movie.genres.isEmpty {
                anchors.append((id: movie.id, genres: movie.genres))
            }
        }
        return anchors
    }

    /// De-dupe by id, keeping first-seen order.
    nonisolated private static func uniqued<T: Identifiable>(_ items: [T]) -> [T] where T.ID: Hashable {
        var seen = Set<T.ID>()
        return items.filter { seen.insert($0.id).inserted }
    }

    // MARK: - Pure builder (runs off the main actor)

    /// `resumePoints` lets the caller pass points the store already resolved
    /// (the app path). When `nil` they're derived from `catalog` + `progress`,
    /// which is what the tests and any in-memory caller do.
    nonisolated static func makeContent(
        catalog: Catalog, epg: EPGIndex, progress: [WatchProgress],
        prefs: UserPreferences, ratings: [String: Double], liveNow: [Channel],
        recentChannelIDs: [CatalogID] = [], now: Date,
        resumePoints: [ResumePoint]? = nil,
        favoriteIDs: [CatalogID] = []
    ) -> HomeContent {
        let enabled = Set(prefs.homeRows)
        var rows: [HomeRow] = []

        func add(_ kind: HomeRowKind, _ title: String, _ cards: [HomeCard], subtitle: String? = nil,
                 style: HomeRow.Style = .poster) {
            guard enabled.contains(kind), !cards.isEmpty else { return }
            rows.append(HomeRow(id: kind.rawValue, title: title, subtitle: subtitle, cards: cards, style: style))
        }

        // Movies sorted by recency once, reused for the shelf + hero.
        let moviesByRecency = catalog.movies.sorted { lhs, rhs in
            let l = lhs.addedAt ?? .distantPast, r = rhs.addedAt ?? .distantPast
            if l != r { return l > r }
            return (lhs.year ?? 0) > (rhs.year ?? 0)
        }

        let points = resumePoints ?? UpNext.resumePoints(catalog: catalog, progress: progress, limit: 12)
        add(.continueWatching, "Continue Watching", continueWatchingCards(points), style: .landscape)

        // "My List" — favourited movies + series, in the order they were hearted.
        // Shown regardless of the saved row list (the option post-dates them).
        let myListRow: HomeRow? = {
            guard !favoriteIDs.isEmpty else { return nil }
            let movieByID = Dictionary(catalog.movies.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let seriesByID = Dictionary(catalog.series.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var cards: [HomeCard] = []
            for id in favoriteIDs {
                if let m = movieByID[id] { cards.append(card(for: m)) }
                else if let s = seriesByID[id] { cards.append(card(for: s)) }
            }
            guard !cards.isEmpty else { return nil }
            return HomeRow(id: HomeRowKind.myList.rawValue, title: "My List",
                           subtitle: nil, cards: Array(cards.prefix(24)))
        }()

        let liveCards = liveNow.prefix(16).map { channelCard($0, epg: epg, now: now) }
        add(.liveNow, "Live Now", Array(liveCards))

        // "Recently Watched" live channels — the viewer's own tune-in history.
        let recentChannelRow: HomeRow? = {
            guard !recentChannelIDs.isEmpty else { return nil }
            let byID = Dictionary(catalog.channels.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let cards = recentChannelIDs.compactMap { byID[$0] }.map { channelCard($0, epg: epg, now: now) }
            guard cards.count >= 2 else { return nil }
            return HomeRow(id: "recent-channels", title: "Recently Watched", subtitle: nil, cards: cards)
        }()

        let seriesByRecency = catalog.series.sorted { ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }

        // "Because You Watched X" — genre-similar titles to up to 2 of the most
        // recent things the viewer has played. Floated just under Continue
        // Watching below. A title already used as siblings in an earlier row
        // (or as its own anchor) is excluded from a later row so the shelves
        // don't just repeat each other.
        let becauseRows: [HomeRow] = {
            var built: [HomeRow] = []
            var excluded: Set<CatalogID> = []
            for anchor in mostRecentWatchedAnchors(progress: progress, catalog: catalog,
                                                       limit: Self.becauseYouWatchedAnchorLimit) {
                let cards = similarTitles(toGenres: anchor.genres, excluding: anchor.id,
                                          movies: moviesByRecency, series: seriesByRecency, limit: 20)
                    .filter { !excluded.contains($0.id) }
                guard cards.count >= 5 else { continue }
                built.append(HomeRow(id: "because-\(anchor.id.rawValue)",
                                     title: "Because You Watched \(anchor.title)", subtitle: nil, cards: cards))
                excluded.formUnion(cards.map(\.id))
                excluded.insert(anchor.id)
            }
            return built
        }()

        var recent = Array(moviesByRecency.prefix(12)).map { card(for: $0) }
        recent += Array(seriesByRecency.prefix(6)).map { card(for: $0) }
        add(.recentlyAdded, "Recently Added", Array(recent.prefix(16)))

        if !prefs.preferredAudioLanguages.isEmpty {
            let want = Set(prefs.preferredAudioLanguages)
            var cards = catalog.movies.filter { !want.isDisjoint(with: $0.audioLanguages) }.prefix(20).map { card(for: $0) }
            cards += catalog.series.filter { !want.isDisjoint(with: $0.audioLanguages) }.prefix(10).map { card(for: $0) }
            add(.inYourLanguages, "In Your Languages", cards)
        }
        if let sub = prefs.preferredSubtitleLanguage {
            var cards = catalog.movies.filter { $0.subtitleLanguages.contains(sub) }.prefix(20).map { card(for: $0) }
            cards += catalog.series.filter { $0.subtitleLanguages.contains(sub) }.prefix(10).map { card(for: $0) }
            add(.withYourSubtitles, "With \(sub.displayName) Subtitles", cards)
        }

        // Top Rated — TMDB ratings, best first. Shown whenever we have enough
        // rated titles, regardless of the saved row toggles (it's new).
        let ratedMovies = catalog.movies.compactMap { m in
            ratings[m.id.rawValue].map { (card: card(for: m), score: $0) }
        }
        let ratedSeries = catalog.series.compactMap { s in
            ratings[s.id.rawValue].map { (card: card(for: s), score: $0) }
        }
        let ratedCards = ratedMovies + ratedSeries
        let topRated = ratedCards
            .filter { $0.score >= 7.0 }
            .sorted { $0.score > $1.score }
            .prefix(10)
            .map(\.card)
        if topRated.count >= 5 {
            rows.append(HomeRow(id: HomeRowKind.topRated.rawValue, title: "Top 10 in Your Library",
                                subtitle: "Ranked by TMDB rating", cards: Array(topRated), style: .ranked))
        }
        if let myListRow { rows.append(myListRow) }
        rows.append(contentsOf: becauseRows)
        if let recentChannelRow { rows.append(recentChannelRow) }

        // Genre shelves — the biggest few genres in the library. Like "Top
        // Rated" these are new, so they're shown regardless of the saved row
        // list (which predates the option); a future opt-out can gate them.
        var genreRows: [HomeRow] = []
        do {
            var counts: [Genre: Int] = [:]
            for movie in catalog.movies { for g in movie.genres { counts[g, default: 0] += 1 } }
            for series in catalog.series { for g in series.genres { counts[g, default: 0] += 1 } }
            let topGenres = counts.sorted { $0.value > $1.value }.prefix(5).map(\.key)
            for genre in topGenres where counts[genre, default: 0] >= 8 {
                var cards = Array(moviesByRecency.lazy.filter { $0.genres.contains(genre) }.prefix(18))
                    .map { card(for: $0) }
                cards += Array(seriesByRecency.lazy.filter { $0.genres.contains(genre) }.prefix(6))
                    .map { card(for: $0) }
                if cards.count >= 5 {
                    genreRows.append(HomeRow(id: "genre-\(genre.rawValue)", title: genre.displayName,
                                             subtitle: nil, cards: Array(cards.prefix(22))))
                }
            }
        }

        add(.movies, "Movies", Array(moviesByRecency.prefix(30)).map { card(for: $0) })
        add(.series, "Series", Array(catalog.series.prefix(30)).map { card(for: $0) })

        // Match the user's preferred row order.
        rows.sort { lhs, rhs in
            (prefs.homeRows.firstIndex { $0.rawValue == lhs.id } ?? 99)
                < (prefs.homeRows.firstIndex { $0.rawValue == rhs.id } ?? 99)
        }

        // Float the position-less rows up just below Continue Watching, in a
        // deliberate order: My List, Top Rated, Because You Watched, Recently Watched.
        var floatIDs: [String] = []
        if myListRow != nil { floatIDs.append(HomeRowKind.myList.rawValue) }
        floatIDs.append(HomeRowKind.topRated.rawValue)
        floatIDs.append(contentsOf: becauseRows.map(\.id))
        if let recentID = recentChannelRow?.id { floatIDs.append(recentID) }
        var placedFloats: Set<String> = []
        for floatID in floatIDs {
            guard let idx = rows.firstIndex(where: { $0.id == floatID }) else { continue }
            let row = rows.remove(at: idx)
            let insertAt = rows.lastIndex { $0.id == HomeRowKind.continueWatching.rawValue
                || placedFloats.contains($0.id) }
                .map { $0 + 1 } ?? 0
            rows.insert(row, at: Swift.min(insertAt, rows.count))
            placedFloats.insert(floatID)
        }

        // Genre shelves sit just above the generic Movies / Series shelves.
        if !genreRows.isEmpty {
            let anchor = rows.firstIndex {
                $0.id == HomeRowKind.movies.rawValue || $0.id == HomeRowKind.series.rawValue
            } ?? rows.count
            rows.insert(contentsOf: genreRows, at: anchor)
        }

        // Featured heroes — highest TMDB rating first, then newest, drawn from
        // both movies and series. The banner resolves the real backdrop +
        // synopsis from TMDB itself.
        let heroMovies: [(card: HomeCard, score: Double, added: Date)] =
            moviesByRecency.prefix(120).map { m in
                (card: HomeCard(id: m.id, kind: .movie, title: m.title, subtitle: m.synopsis,
                                artworkURL: m.backdropURL ?? m.posterURL, year: m.year,
                                eyebrow: metadataSubtitle(for: m)),
                 score: ratings[m.id.rawValue] ?? 0,
                 added: m.addedAt ?? .distantPast)
            }
        let heroSeries: [(card: HomeCard, score: Double, added: Date)] =
            seriesByRecency.prefix(40).map { s in
                (card: HomeCard(id: s.id, kind: .series, title: s.title, subtitle: s.synopsis,
                                artworkURL: s.backdropURL ?? s.posterURL, year: s.year,
                                eyebrow: heroEyebrow(for: s)),
                 score: ratings[s.id.rawValue] ?? 0,
                 added: s.addedAt ?? .distantPast)
            }
        let heroPool = heroMovies + heroSeries
        let heroes: [HomeCard] = heroPool
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.added > rhs.added
            }
            .prefix(5)
            .map { entry in
                // Lead the eyebrow with the rating when there is one — it's the
                // single most persuasive fact about a featured title.
                guard entry.score > 0 else { return entry.card }
                let c = entry.card
                let rating = String(format: "★ %.1f", entry.score)
                let eyebrow = [rating, c.eyebrow].compactMap { $0 }.filter { !$0.isEmpty }
                    .joined(separator: " · ")
                return HomeCard(id: c.id, kind: c.kind, title: c.title, subtitle: c.subtitle,
                                artworkURL: c.artworkURL, year: c.year, eyebrow: eyebrow)
            }

        let tonight = prefs.isRowEnabled(.tonight)
            ? buildTonight(channels: catalog.channels, epg: epg, now: now) : []

        return HomeContent(heroes: heroes, rows: rows.filter { !$0.cards.isEmpty }, tonight: tonight)
    }

    nonisolated private static func continueWatchingCards(_ points: [ResumePoint]) -> [HomeCard] {
        points.map { point in
            HomeCard(id: point.containerID, kind: point.isSeries ? .series : .movie,
                     title: point.primaryTitle, subtitle: point.secondaryText,
                     artworkURL: point.artworkURL, progress: point.fraction > 0 ? point.fraction : nil,
                     resumeItemID: point.itemID)
        }
    }

    nonisolated static func buildTonight(channels: [Channel], epg: EPGIndex, now: Date) -> [TonightItem] {
        let cal = Calendar(identifier: .gregorian)
        let endWindow = cal.date(bySettingHour: 23, minute: 59, second: 0, of: now) ?? now
        let window = DateInterval(start: now, end: max(now, endWindow))
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"

        var items: [TonightItem] = []
        for channel in channels {
            guard let epgID = channel.epgID, epg[epgID] != nil else { continue }
            for event in epg.events(forChannel: epgID, in: window).prefix(3) {
                items.append(TonightItem(id: event.id, channelID: channel.id,
                                         time: formatter.string(from: event.start),
                                         programTitle: event.title, channelName: channel.name,
                                         isLiveNow: event.isLive(at: now)))
            }
            if items.count > 60 { break }
        }
        return Array(items.sorted { $0.time < $1.time }.prefix(12))
    }

    nonisolated static func card(for movie: Movie) -> HomeCard {
        HomeCard(id: movie.id, kind: .movie, title: movie.title,
                 subtitle: metadataSubtitle(for: movie), artworkURL: movie.posterURL, year: movie.year,
                 isNew: CatalogFreshness.isNew(movie.addedAt))
    }

    nonisolated static func channelCard(_ channel: Channel, epg: EPGIndex, now: Date) -> HomeCard {
        let event = channel.epgID.flatMap { epg.nowPlaying(forChannel: $0, at: now) }
        return HomeCard(id: channel.id, kind: .channel, title: channel.name,
                        subtitle: event?.title ?? channel.category,
                        artworkURL: channel.logoURL, badge: event != nil ? "LIVE" : nil,
                        liveProgress: event?.progress(at: now))
    }

    nonisolated static func card(for series: Series) -> HomeCard {
        // Shelf series come from the store without their season tree loaded;
        // `cardSubtitle` falls back to year / genre when the count isn't known.
        HomeCard(id: series.id, kind: .series, title: series.title,
                        subtitle: series.cardSubtitle, artworkURL: series.posterURL, year: series.year,
                        isNew: CatalogFreshness.isNew(series.addedAt))
    }

    /// The newest movie / series the viewer has played that still carries genre
    /// tags — the anchor for the "Because You Watched" row.
    nonisolated static func mostRecentWatched(
        progress: [WatchProgress], catalog: Catalog
    ) -> (id: CatalogID, title: String, genres: [Genre])? {
        mostRecentWatchedAnchors(progress: progress, catalog: catalog, limit: 1).first
    }

    /// Up to `limit` distinct recently-played titles that still carry genre
    /// tags, newest first — each anchors its own "Because You Watched" row.
    /// Multiple resume points for the same series (different episodes) count
    /// once, at their most recent watch.
    nonisolated static func mostRecentWatchedAnchors(
        progress: [WatchProgress], catalog: Catalog, limit: Int
    ) -> [(id: CatalogID, title: String, genres: [Genre])] {
        let moviesByID = Dictionary(catalog.movies.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var seriesByEpisode: [CatalogID: Series] = [:]
        for s in catalog.series {
            for season in s.seasons { for e in season.episodes { seriesByEpisode[e.id] = s } }
        }
        var seen: Set<CatalogID> = []
        var anchors: [(id: CatalogID, title: String, genres: [Genre])] = []
        for entry in progress.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            guard anchors.count < limit else { break }
            switch entry.kind {
            case .movie:
                if let m = moviesByID[entry.itemID], !m.genres.isEmpty, seen.insert(m.id).inserted {
                    anchors.append((id: m.id, title: m.title, genres: m.genres))
                }
            case .series:
                if let s = seriesByEpisode[entry.itemID], !s.genres.isEmpty, seen.insert(s.id).inserted {
                    anchors.append((id: s.id, title: s.title, genres: s.genres))
                }
            case .liveChannel:
                break
            }
        }
        return anchors
    }

    /// Movies + series that share a genre with `genres`, ranked by shared-genre
    /// count (ties keep the incoming recency order). Excludes the anchor itself.
    nonisolated static func similarTitles(
        toGenres genres: [Genre], excluding excludeID: CatalogID,
        movies: [Movie], series: [Series], limit: Int
    ) -> [HomeCard] {
        guard !genres.isEmpty else { return [] }
        let want = Set(genres)
        func overlap(_ g: [Genre]) -> Int { Set(g).intersection(want).count }

        var scored: [(card: HomeCard, score: Int)] = []
        for m in movies where m.id != excludeID {
            let o = overlap(m.genres); if o > 0 { scored.append((card: card(for: m), score: o)) }
        }
        for s in series where s.id != excludeID {
            let o = overlap(s.genres); if o > 0 { scored.append((card: card(for: s), score: o)) }
        }
        return scored.sorted { $0.score > $1.score }.prefix(limit).map(\.card)
    }

    nonisolated static func heroEyebrow(for series: Series) -> String {
        var parts: [String] = []
        if let year = series.year { parts.append(String(year)) }
        if let genre = series.genres.first { parts.append(genre.displayName) }
        if !series.seasons.isEmpty {
            parts.append("\(series.seasons.count) season\(series.seasons.count == 1 ? "" : "s")")
        }
        if series.quality > .unknown { parts.append(series.quality.shortLabel) }
        return parts.joined(separator: " · ")
    }

    nonisolated static func metadataSubtitle(for movie: Movie) -> String {
        var parts: [String] = []
        if let year = movie.year { parts.append(String(year)) }
        if let genre = movie.genres.first { parts.append(genre.displayName) }
        if let d = movie.durationMinutes { parts.append("\(d / 60)h \(d % 60)m") }
        if movie.quality > .unknown { parts.append(movie.quality.shortLabel) }
        return parts.joined(separator: " · ")
    }
}
