import Foundation
import Observation

@MainActor
@Observable
public final class VODBrowseViewModel {
    public let kind: BrowseKind

    public private(set) var cards: [BrowseCard] = []
    public private(set) var total = 0
    public private(set) var isLoading = false
    public private(set) var canLoadMore = true

    public private(set) var availableGenres: [Genre] = []
    /// Category browsing: the provider's own sections and the genres.
    public private(set) var collections: [BrowseCategory] = []
    public private(set) var genreCategories: [BrowseCategory] = []
    public private(set) var availableAudio: [Language] = []
    public private(set) var availableSubtitles: [Language] = []
    /// A–Z jump targets — populated only when sorting alphabetically.
    public private(set) var anchors: [BrowseAnchor] = []

    public var filter = CatalogFilter()

    private let repository: any CatalogQuerying
    private let watchProgress: WatchProgressStore
    /// Supplies the "For You" ranking inputs; refreshed on every reload so
    /// what you watched last changes the order next time.
    public var forYouProvider: (@MainActor () async -> ForYouProfile)?
    private var forYouProfile: ForYouProfile?
    private let pageSize = 60
    private var page = 0
    private var reloadTask: Task<Void, Never>?

    public init(kind: BrowseKind, repository: any CatalogQuerying, watchProgress: WatchProgressStore) {
        self.kind = kind
        self.repository = repository
        self.watchProgress = watchProgress
    }

    /// Whether this screen still needs a load is tracked by `SectionModels`
    /// (which also knows the catalog revision it last loaded against).
    public func start() async {
        // Cards first — the facets fill the chip row in behind them.
        await reload()
    }

    public func clearFilters() {
        filter = CatalogFilter(sort: filter.sort)
    }

    /// Show one category: replaces any other category or genre choice.
    public func open(_ category: BrowseCategory) {
        var next = CatalogFilter(sort: filter.sort)
        switch category.kind {
        case .collection(let name): next.collections = [name]
        case .genre(let genre):     next.genres = [genre]
        }
        filter = next
    }

    /// Recent Surprise Me picks — not offered again for a while.
    private var recentSurprises: [CatalogID] = []

    /// "Surprise Me", but worth watching: drawn from the top of the For You
    /// ranking within the current filter — with artwork and a description,
    /// not already started, never a title TMDB rates poorly — and weighted
    /// towards the well-rated and the best-ranked. Not the same pick twice in
    /// a row.
    public func surprisePick(ratings: [String: Double]) async -> AppRoute? {
        var query = filter
        query.sort = .forYou
        if forYouProfile == nil, let forYouProvider { forYouProfile = await forYouProvider() }
        query.forYou = forYouProfile

        struct Candidate { let id: CatalogID; let route: AppRoute; let hasSynopsis: Bool; let rank: Int }
        let pool: [Candidate]
        switch kind {
        case .movies:
            pool = await repository.movies(filter: query, page: 0, pageSize: 120).enumerated()
                .filter { $0.element.posterURL != nil }
                .map { Candidate(id: $0.element.id, route: .movie($0.element.id),
                                 hasSynopsis: !($0.element.synopsis ?? "").isEmpty, rank: $0.offset) }
        case .series:
            pool = await repository.series(filter: query, page: 0, pageSize: 120).enumerated()
                .filter { $0.element.posterURL != nil }
                .map { Candidate(id: $0.element.id, route: .series($0.element.id),
                                 hasSynopsis: !($0.element.synopsis ?? "").isEmpty, rank: $0.offset) }
        }

        func score(_ c: Candidate) -> Double? {
            if watchProgress.progress(for: c.id) != nil { return nil }       // already seen / started
            if recentSurprises.contains(c.id) { return nil }
            let rating = ratings[c.id.rawValue]
            if let rating, rating < 6.0 { return nil }                       // known to be weak
            var s = 120.0 - Double(c.rank)                                   // For You order
            if let rating { s += (rating - 6.0) * 25 }                       // 7.5 ⇒ +37
            if c.hasSynopsis { s += 15 }
            return s
        }
        var ranked = pool.compactMap { c in score(c).map { (c, $0) } }.sorted { $0.1 > $1.1 }
        if ranked.isEmpty, !recentSurprises.isEmpty {
            // A small category: every good title was offered recently — start over.
            recentSurprises.removeAll()
            ranked = pool.compactMap { c in score(c).map { (c, $0) } }.sorted { $0.1 > $1.1 }
        }
        if ranked.isEmpty {   // nothing passes — fall back to the plain For You top
            ranked = pool.map { ($0, 1.0) }
        }
        let top = Array(ranked.prefix(15))
        guard !top.isEmpty else { return nil }
        // Weighted draw: the better the score, the likelier.
        let floor = (top.last?.1 ?? 0) - 1
        let weights = top.map { max(1, $0.1 - floor) }
        var roll = Double.random(in: 0..<weights.reduce(0, +))
        var pick = top[0].0
        for (candidate, weight) in zip(top.map(\.0), weights) {
            if roll < weight { pick = candidate; break }
            roll -= weight
        }
        recentSurprises.append(pick.id)
        while recentSurprises.count > min(12, max(1, ranked.count / 2)) { recentSurprises.removeFirst() }
        return pick.route
    }

    /// The name of what's shown when it's one category ("Netflix", "Horror").
    public var categoryTitle: String? {
        if filter.collections.count == 1, filter.genres.isEmpty { return filter.collections[0] }
        if filter.genres.count == 1, filter.collections.isEmpty { return filter.genres[0].displayName }
        return nil
    }

    /// Coming back from a detail screen, the only thing that can have changed is
    /// how far through something you are. Re-mapping the cards in place keeps
    /// scroll position and focus exactly where you left them — re-running the
    /// query would rebuild the grid and throw both away.
    public func refreshProgress() {
        guard !cards.isEmpty, kind == .movies else { return }
        var changed = false
        let updated = cards.map { card -> BrowseCard in
            let fresh = progressFraction(for: card.id)
            if fresh == card.progress { return card }
            changed = true
            return BrowseCard(id: card.id, route: card.route, title: card.title,
                              subtitle: card.subtitle, posterURL: card.posterURL,
                              progress: fresh, year: card.year, isSeries: card.isSeries, isNew: card.isNew)
        }
        if changed { cards = updated }
    }

    /// Debounced — the filter UI calls this on every chip tap; only the settled
    /// filter runs a query. Also the catalog-revision path, so facets get a
    /// refresh on the next pass.
    /// `refreshFacets` (the library changed) also re-reads the genre / language
    /// facets and the category tiles; a filter change doesn't need them.
    public func scheduleReload(refreshFacets: Bool = false) {
        if refreshFacets { facetsAreStale = true }
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    /// The first page is the only thing between the viewer and a populated
    /// grid, so it goes first. The count, the A–Z rail and the filter facets
    /// are all *decorations around* that grid — they land a beat later without
    /// anyone waiting on them.
    ///
    /// This matters most on a big library: the A–Z rail needs every matching
    /// title in sort order (tens of thousands of rows), which is far more work
    /// than the 60 cards actually on screen.
    public func reload() async {
        isLoading = true
        page = 0
        canLoadMore = true
        let snapshotFilter = filter
        if filter.sort == .forYou, let forYouProvider {
            forYouProfile = await forYouProvider()
        }

        // 1. Paint.
        await loadPage(replacing: true, filter: snapshotFilter)
        isLoading = false
        guard !Task.isCancelled, filter == snapshotFilter else { return }

        // 2. Decorate.
        decorationTask?.cancel()
        decorationTask = Task { [weak self] in
            await self?.loadDecorations(for: snapshotFilter)
        }
    }

    /// Count, A–Z anchors and filter facets — everything the grid itself
    /// doesn't need in order to render.
    private func loadDecorations(for snapshotFilter: CatalogFilter) async {
        switch kind {
        case .movies: total = await repository.moviesCount(filter: snapshotFilter)
        case .series: total = await repository.seriesCount(filter: snapshotFilter)
        }
        guard !Task.isCancelled, filter == snapshotFilter else { return }

        if snapshotFilter.sort == .titleAscending {
            switch kind {
            case .movies: anchors = await repository.movieTitleAnchors(filter: snapshotFilter)
            case .series: anchors = await repository.seriesTitleAnchors(filter: snapshotFilter)
            }
        } else {
            anchors = []
        }
        guard !Task.isCancelled, filter == snapshotFilter else { return }

        // Facets describe the whole library, not the current filter, so they
        // only need refreshing while an import is still adding to it.
        if availableGenres.isEmpty || facetsAreStale {
            let categories = await repository.browseCategories(series: kind == .series)
            collections = categories.collections
            genreCategories = categories.genres
            availableGenres = await repository.availableGenres()
            availableAudio = await repository.availableAudioLanguages()
            availableSubtitles = await repository.availableSubtitleLanguages()
            facetsAreStale = false
        }
    }

    /// Set when the catalog revision bumps — the next reload refreshes facets.
    private var facetsAreStale = true
    private var decorationTask: Task<Void, Never>?

    /// Load pages until the item at `anchor.index` is in `cards`, then return
    /// its id so the view can scroll to it. Pages are O(1) slices of a cached
    /// sorted list, so walking to a deep letter is cheap.
    public func jump(to anchor: BrowseAnchor) async -> CatalogID? {
        let target = filter
        while cards.count <= anchor.index, canLoadMore, filter == target {
            let before = cards.count
            await loadPage(replacing: false, filter: target)
            if cards.count == before { break }
        }
        return cards.indices.contains(anchor.index) ? cards[anchor.index].id : cards.last?.id
    }

    public func loadMoreIfNeeded(currentItem: BrowseCard) async {
        guard canLoadMore, !isLoading,
              let idx = cards.firstIndex(where: { $0.id == currentItem.id }),
              idx >= cards.count - 25
        else { return }
        await loadPage(replacing: false, filter: filter)
    }

    private func loadPage(replacing: Bool, filter: CatalogFilter) async {
        isLoading = true
        defer { isLoading = false }

        var query = filter
        query.forYou = forYouProfile
        let newCards: [BrowseCard]
        switch kind {
        case .movies:
            let movies = await repository.movies(filter: query, page: page, pageSize: pageSize)
            newCards = movies.map { BrowseCard(movie: $0, progress: progressFraction(for: $0.id)) }
        case .series:
            let series = await repository.series(filter: query, page: page, pageSize: pageSize)
            newCards = series.map { BrowseCard(series: $0) }
        }
        guard !Task.isCancelled, filter == self.filter else { return }

        if replacing { cards = newCards } else { cards.append(contentsOf: newCards) }
        // Decode the next screenful's posters before they scroll into view.
        ImageCache.shared.prefetch(newCards.prefix(30).compactMap(\.posterURL))
        page += 1
        canLoadMore = newCards.count == pageSize
    }

    private func progressFraction(for id: CatalogID) -> Double? {
        let f = watchProgress.fraction(for: id)
        return f > 0 ? f : nil
    }
}
