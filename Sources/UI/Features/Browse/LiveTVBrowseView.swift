import SwiftUI
import Observation

public struct LiveChannelRow: Identifiable, Sendable {
    public let id: CatalogID
    public let name: String
    public let logoURL: URL?
    public let quality: VideoQuality
    public let nowTitle: String?
    public let nowProgress: Double?
    public let number: Int
}

@MainActor
@Observable
public final class LiveTVBrowseViewModel {
    public private(set) var categories: [String] = ["All"]
    public private(set) var rows: [LiveChannelRow] = []
    public private(set) var total = 0
    public private(set) var isLoading = false
    public private(set) var canLoadMore = true
    public private(set) var anchors: [BrowseAnchor] = []

    public var selectedCategory = "All"
    public var sort: ChannelSort = .number
    /// Shows only channels the user has hearted — a bounded, curated set, so it
    /// skips the paged/category query entirely and fetches by id.
    public var favoritesOnly = false

    private let repository: any CatalogQuerying
    private let favorites: FavoritesStore
    private let pageSize = 90
    private var page = 0
    private var reloadTask: Task<Void, Never>?
    /// Set when a catalog change arrived while Favorites mode skipped the
    /// category query; the next normal reload refetches the chips.
    private var categoriesStale = false

    public init(repository: any CatalogQuerying, favorites: FavoritesStore) {
        self.repository = repository
        self.favorites = favorites
    }

    /// Whether this screen still needs a load is tracked by `SectionModels`.
    public func start() async {
        // Channels first; the category chips and the count fill in behind them.
        await reload()
    }

    /// Coalesced (280 ms) — the catalog revision bumps repeatedly during import.
    public func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled, let self else { return }
            if self.favoritesOnly {
                // Chips are hidden in Favorites mode — defer the category query
                // to the next normal reload instead of running it on every
                // import revision.
                self.categoriesStale = true
            } else {
                self.categories = await self.repository.allChannelCategories()
                self.categoriesStale = false
            }
            await self.reload()
        }
    }

    /// First page of channels first; the count, the A–Z rail and the category
    /// chips follow. The rail in particular needs every matching channel name in
    /// sort order, which on a 15k-channel provider dwarfs the 90 rows on screen.
    public func reload() async {
        isLoading = true
        page = 0
        canLoadMore = true

        if favoritesOnly {
            await loadFavorites()
            isLoading = false
            return
        }

        let category = selectedCategory
        let sort = self.sort

        await loadPage(replacing: true, category: category, sort: sort)
        isLoading = false
        guard !Task.isCancelled, category == selectedCategory, sort == self.sort, !favoritesOnly else { return }

        decorationTask?.cancel()
        decorationTask = Task { [weak self] in
            await self?.loadDecorations(category: category, sort: sort)
        }
    }

    /// Favourites are few by construction, so this loads them all in one shot
    /// (by id, via the store's own list) instead of the category/page query —
    /// no pagination, no category chips, no A–Z rail.
    private func loadFavorites() async {
        let ids = favorites.all().filter { $0.kind == .liveChannel }.map(\.itemID)
        let channels = await repository.channels(ids: ids)
        guard !Task.isCancelled, favoritesOnly else { return }

        let now = Date()
        let window = DateInterval(start: now.addingTimeInterval(-4 * 3600),
                                  end: now.addingTimeInterval(4 * 3600))
        let epg = await repository.epgIndex(forEPGIDs: channels.compactMap(\.epgID), in: window)
        guard !Task.isCancelled, favoritesOnly else { return }

        let ordered = sort == .nameAsc
            ? channels.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            : channels.sorted { $0.sortIndex < $1.sortIndex }

        rows = ordered.map { channel in
            let event = channel.epgID.flatMap { epg.nowPlaying(forChannel: $0, at: now) }
            return LiveChannelRow(
                id: channel.id, name: channel.name, logoURL: channel.logoURL,
                quality: channel.quality, nowTitle: event?.title,
                nowProgress: event?.progress(at: now), number: channel.sortIndex
            )
        }
        total = rows.count
        canLoadMore = false
        anchors = []
    }

    private func loadDecorations(category: String, sort: ChannelSort) async {
        total = await repository.channelsCount(in: category)
        guard !Task.isCancelled, category == selectedCategory, sort == self.sort else { return }

        anchors = sort == .nameAsc ? await repository.channelTitleAnchors(in: category) : []
        guard !Task.isCancelled, category == selectedCategory, sort == self.sort else { return }

        if categories.count <= 1 || categoriesStale {
            categories = await repository.allChannelCategories()
            categoriesStale = false
        }
    }

    private var decorationTask: Task<Void, Never>?

    public func loadMoreIfNeeded(currentItem: LiveChannelRow) async {
        guard canLoadMore, !isLoading,
              let idx = rows.firstIndex(where: { $0.id == currentItem.id }),
              idx >= rows.count - 15
        else { return }
        await loadPage(replacing: false, category: selectedCategory, sort: sort)
    }

    /// Page in until the channel at `anchor.index` is loaded; return its id.
    public func jump(to anchor: BrowseAnchor) async -> CatalogID? {
        let category = selectedCategory, sort = self.sort
        while rows.count <= anchor.index, canLoadMore,
              category == selectedCategory, sort == self.sort {
            let before = rows.count
            await loadPage(replacing: false, category: category, sort: sort)
            if rows.count == before { break }
        }
        return rows.indices.contains(anchor.index) ? rows[anchor.index].id : rows.last?.id
    }

    private func loadPage(replacing: Bool, category: String, sort: ChannelSort) async {
        isLoading = true
        defer { isLoading = false }

        let channels = await repository.channels(in: category, sort: sort, page: page, pageSize: pageSize)
        guard !Task.isCancelled, category == selectedCategory, sort == self.sort else { return }

        // One windowed query for the whole page, not one per channel — a page is
        // 90 channels, and 90 round-trips to the store is what made paging feel
        // heavy no matter how fast each individual lookup was.
        let now = Date()
        let window = DateInterval(start: now.addingTimeInterval(-4 * 3600),
                                  end: now.addingTimeInterval(4 * 3600))
        let epg = await repository.epgIndex(forEPGIDs: channels.compactMap(\.epgID), in: window)
        guard !Task.isCancelled, category == selectedCategory, sort == self.sort else { return }

        let built: [LiveChannelRow] = channels.map { channel in
            let event = channel.epgID.flatMap { epg.nowPlaying(forChannel: $0, at: now) }
            return LiveChannelRow(
                id: channel.id, name: channel.name, logoURL: channel.logoURL,
                quality: channel.quality, nowTitle: event?.title,
                nowProgress: event?.progress(at: now), number: channel.sortIndex
            )
        }
        guard category == selectedCategory else { return }
        if replacing { rows = built } else { rows.append(contentsOf: built) }
        page += 1
        canLoadMore = channels.count == pageSize
    }
}

struct LiveTVBrowseView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(SectionModels.self) private var models
    @State private var model: LiveTVBrowseViewModel?
    @State private var path: [AppRoute] = []

    private let columns = Array(repeating: GridItem(.fixed(Metrics.wideCardWidth), spacing: Metrics.cardSpacing),
                                count: 4)

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let model {
                    content(model)
                } else {
                    LibraryLoadingPlaceholder()
                }
            }
            .appThemeBackground()
            .appRouteDestinations()
        }
        .task(id: models.generation) {
            let shared = models.liveTV(env)
            model = shared
            guard models.needsLoad(.liveTV, revision: env.catalogRevision) else { return }
            let revision = env.catalogRevision
            await shared.start()
            guard !Task.isCancelled else { return }
            models.markLoaded(.liveTV, revision: revision)
        }
        .onChange(of: env.catalogRevision) { _, revision in
            models.markLoaded(.liveTV, revision: revision)
            model?.scheduleReload()
        }
    }

    @ViewBuilder
    private func content(_ model: LiveTVBrowseViewModel) -> some View {
        ScrollViewReader { proxy in
        VStack(spacing: 0) {
            // Fixed bar, flush to the top. `zIndex(1)` keeps it over the grid —
            // the ScrollView below disables clipping (focused cards scale past
            // the edge), which otherwise lets rows scroll over the header.
            header(model, proxy: proxy)
                .background(Palette.canvas)
                .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
                .zIndex(1)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: Metrics.space3) {
                    Color.clear.frame(height: Metrics.space3).id("live-top")
                    if model.rows.isEmpty && !model.isLoading && env.loadState.isImporting {
                        LibraryLoadingPlaceholder().frame(minHeight: 400)
                    } else if model.rows.isEmpty && !model.isLoading {
                        EmptyStateView(
                            icon: model.favoritesOnly ? "star" : "tv",
                            title: model.favoritesOnly ? "No favorite channels" : "No channels",
                            message: model.favoritesOnly
                                ? "Heart a channel from its detail screen to see it here."
                                : "No channels in this category."
                        )
                        .frame(minHeight: 400)
                    } else {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: Metrics.gridSpacing) {
                            ForEach(model.rows) { row in
                                ChannelCard(
                                    name: row.name,
                                    logoURL: row.logoURL,
                                    nowTitle: row.nowTitle,
                                    quality: row.quality,
                                    nowProgress: row.nowProgress,
                                    channelNumber: row.number,
                                    action: { path.append(.channel(row.id)) }
                                )
                                .id(row.id)
                                .task { await model.loadMoreIfNeeded(currentItem: row) }
                            }
                        }
                        .padding(.horizontal, Metrics.screenMargin)
                        .padding(.bottom, Metrics.space7)
                    }
                }
            }
            .scrollClipDisabled()
            .focusSection()
        }
        .onChange(of: model.selectedCategory) { _, _ in
            withAnimation { proxy.scrollTo("live-top", anchor: .top) }
            Task { await model.reload() }
        }
        .onChange(of: model.sort) { _, _ in
            withAnimation { proxy.scrollTo("live-top", anchor: .top) }
            Task { await model.reload() }
        }
        .onChange(of: model.favoritesOnly) { _, _ in
            withAnimation { proxy.scrollTo("live-top", anchor: .top) }
            Task { await model.reload() }
        }
        }
    }

    private func header(_ model: LiveTVBrowseViewModel, proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: Metrics.space2) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.space2) {
                Text("Live TV").font(.dsTitle).accessibilityAddTraits(.isHeader)
                Text("\(model.total)").font(.dsCardTitle).foregroundStyle(Palette.textTertiary)
                Spacer()
                HStack(spacing: Metrics.space1) {
                    FilterChip(label: "★ Favorites", isSelected: model.favoritesOnly) {
                        model.favoritesOnly.toggle()
                    }
                    ForEach(ChannelSort.allCases, id: \.self) { option in
                        FilterChip(label: option.label, isSelected: model.sort == option) {
                            model.sort = option
                        }
                    }
                }
            }
            if !model.favoritesOnly, model.categories.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Metrics.space1) {
                        ForEach(model.categories, id: \.self) { category in
                            FilterChip(label: category, isSelected: model.selectedCategory == category) {
                                model.selectedCategory = category
                            }
                        }
                    }
                    .padding(.vertical, Metrics.space1)
                    .padding(.horizontal, 2)
                }
                .scrollClipDisabled()
                .focusSection()
            }

            if model.sort == .nameAsc && model.anchors.count > 2 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Metrics.space1) {
                        ForEach(model.anchors) { anchor in
                            FilterChip(label: anchor.letter, isSelected: false) {
                                Task {
                                    if let id = await model.jump(to: anchor) {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            proxy.scrollTo(id, anchor: UnitPoint(x: 0, y: 0.12))
                                        }
                                    }
                                }
                            }
                            .accessibilityLabel("Jump to \(anchor.letter)")
                        }
                    }
                    .padding(.vertical, Metrics.space1)
                    .padding(.horizontal, 2)
                }
                .scrollClipDisabled()
                .focusSection()
                .accessibilityLabel("Jump to letter")
            }
        }
        .padding(.horizontal, Metrics.screenMargin)
        .padding(.top, Metrics.space3)
        .padding(.bottom, Metrics.space2)
        .focusSection()
    }
}
