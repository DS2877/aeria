import SwiftUI

struct VODBrowseView: View {
    let kind: BrowseKind

    @Environment(AppEnvironment.self) private var env
    @Environment(SectionModels.self) private var models
    @State private var model: VODBrowseViewModel?
    @State private var showFilters = false
    @State private var path: [AppRoute] = []
    /// Index of the focused card — Menu deep in the grid jumps to the top
    /// first (the Apple TV convention), then a second Menu opens the sidebar.
    /// Only flips when crossing the first row, so moving around the grid
    /// doesn't re-render the screen on every focus change.
    @State private var isDeepInGrid = false
    /// Bumped to send focus to the first card (the same mechanism a sidebar
    /// click uses).
    @State private var topToken = 0
    /// Bumped just after the scroll to the top, once the first card exists
    /// again (the lazy grid drops cards far off screen).
    @State private var focusTopToken = 0
    /// A category was opened: focus its first title once its cards are in.
    @State private var focusFirstAfterLoad = false
    @Environment(\.sectionDiveToken) private var shellDiveToken

    private let columns = Array(repeating: GridItem(.fixed(Metrics.posterWidth), spacing: Metrics.cardSpacing),
                                count: 5)

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let model {
                    grid(model)
                } else {
                    LibraryLoadingPlaceholder()
                }
            }
            .appThemeBackground()
            .menuReturnsToSidebar(first: menuAction)
            .appRouteDestinations()
        }
        // Keyed on the store's generation so a provider switch re-fetches the
        // handle rather than leaving it on the discarded model.
        .task(id: models.generation) {
            let shared = models.vod(kind, env)
            model = shared
            // Already populated from an earlier visit against this same catalog
            // — don't re-query. (A visit made mid-import loaded a partial
            // library, so a newer revision does need a refresh.)
            let key: SectionModels.SectionKey = kind == .movies ? .movies : .series
            guard models.needsLoad(key, revision: env.catalogRevision) else { return }
            let revision = env.catalogRevision
            await shared.start()
            // Only after it finished — leaving mid-load must not mark it done.
            guard !Task.isCancelled else { return }
            models.markLoaded(key, revision: revision)
            prefetchPosters(shared)
        }
        .onChange(of: path.isEmpty) { _, atRoot in
            // Back from a detail screen: only the watch-progress bars can have
            // changed. Keep the grid — and the focus — exactly as it was.
            if atRoot { model?.refreshProgress() }
        }
        .onChange(of: env.catalogRevision) { _, revision in
            // Coalesced (280 ms) — the revision bumps repeatedly during import.
            models.markLoaded(kind == .movies ? .movies : .series, revision: revision)
            model?.scheduleReload(refreshFacets: true)
        }
    }

    /// Deep in the grid, Menu goes back to the first card; otherwise the
    /// default (the sidebar).
    private var menuAction: (() -> Void)? {
        if isDeepInGrid { return { backToTop() } }
        if let model, model.filter.isNarrowed {
            return { model.clearFilters(); backToTop() }
        }
        return nil
    }

    /// The category overview (collections, genres, quick picks) shows above
    /// the grid when nothing is narrowed — the way in to browsing.
    private func showsCategories(_ model: VODBrowseViewModel) -> Bool {
        !model.filter.isNarrowed && model.filter.text.isEmpty
            && (!model.collections.isEmpty || !model.genreCategories.isEmpty)
    }

    private func backToTop() {
        isDeepInGrid = false
        topToken &+= 1
    }

    private func prefetchPosters(_ model: VODBrowseViewModel) {
        ImageCache.shared.prefetch(model.cards.prefix(15).compactMap(\.posterURL))
    }

    @ViewBuilder
    private func grid(_ model: VODBrowseViewModel) -> some View {
        ScrollViewReader { proxy in
        VStack(spacing: 0) {
            // A fixed bar flush to the top — not a pinned section header (which
            // leaves a dark strip above it as it pins). `zIndex(1)` keeps it
            // painting over the grid: the ScrollView below has clipping disabled
            // (so a focused poster can scale past the edge), which otherwise lets
            // rows scroll *over* the header instead of under it.
            header(model, proxy: proxy)
                .background(Palette.canvas)
                .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
                .zIndex(1)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: Metrics.space3) {
                    Color.clear.frame(height: Metrics.space3).id("vod-top")
                    if model.cards.isEmpty && !model.isLoading && (env.loadState.isImporting || !env.catalogComplete) {
                        LibraryLoadingPlaceholder().frame(minHeight: 400)
                    } else if model.cards.isEmpty && !model.isLoading {
                        EmptyStateView(
                            icon: "line.3.horizontal.decrease.circle",
                            title: model.filter.isNarrowed ? "No matches" : "Nothing here yet",
                            message: model.filter.isNarrowed
                                ? "Nothing in your library matches these filters."
                                : "Your provider didn't return any \(kind.title.lowercased()).",
                            actionTitle: model.filter.isNarrowed ? "Clear filters" : nil,
                            action: model.filter.isNarrowed ? { model.clearFilters() } : nil
                        )
                        .frame(minHeight: 400)
                    } else {
                        let overview = showsCategories(model)
                        if overview {
                            categoryOverview(model)
                        }
                        gridHeading(model)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: Metrics.gridSpacing) {
                            ForEach(model.cards) { card in
                                PosterCard(
                                    title: card.title,
                                    subtitle: card.subtitle,
                                    artworkURL: card.posterURL,
                                    ref: card.artworkRef,
                                    progress: card.progress,
                                    isNew: card.isNew,
                                    action: { path.append(card.route) }
                                )
                                .sectionEntryFocus(!overview && card.id == model.cards.first?.id)
                                .onCardFocused {
                                    // Under the category rows, any grid card is
                                    // "deep"; otherwise past the first row.
                                    let deep = overview
                                        || (model.cards.firstIndex(where: { $0.id == card.id }) ?? 0) >= columns.count
                                    if deep != isDeepInGrid { isDeepInGrid = deep }
                                    env.warmUp(card.route)
                                }
                                .id(card.id)
                                .task { await model.loadMoreIfNeeded(currentItem: card) }
                            }
                        }
                        .padding(.horizontal, Metrics.screenMargin)
                        .padding(.bottom, Metrics.space7)
                    }
                }
            }
            .scrollClipDisabled()
            .focusSection()
            .environment(\.sectionDiveToken, shellDiveToken &+ focusTopToken)
        }
        .onChange(of: model.cards.first?.id) { _, _ in
            guard focusFirstAfterLoad else { return }
            focusFirstAfterLoad = false
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                focusTopToken &+= 1
            }
        }
        .onChange(of: topToken) { _, _ in
            withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo("vod-top", anchor: .top) }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(180))
                focusTopToken &+= 1
            }
        }
        .onChange(of: model.filter) { old, new in
            // A narrowing change (genre / language / year) resets the list —
            // snap to the top. A pure sort change keeps position.
            if old.isNarrowed != new.isNarrowed || old.genres != new.genres
                || old.collections != new.collections
                || old.audioLanguages != new.audioLanguages
                || old.subtitleLanguages != new.subtitleLanguages {
                withAnimation { proxy.scrollTo("vod-top", anchor: .top) }
            }
            model.scheduleReload()
        }
        }
    }

    @ViewBuilder
    private func letterRail(_ model: VODBrowseViewModel, proxy: ScrollViewProxy) -> some View {
        if model.anchors.count > 2 {
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

    private func header(_ model: VODBrowseViewModel, proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: Metrics.space2) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.space2) {
                Text(model.categoryTitle.map { "\(kind.title) · \($0)" } ?? kind.title)
                    .font(.dsTitle).lineLimit(1).accessibilityAddTraits(.isHeader)
                if !(model.isLoading && model.cards.isEmpty) {
                    Text("\(model.total)")
                        .font(.dsCardTitle).foregroundStyle(Palette.textTertiary)
                }
                Spacer()
                Button {
                    Task { await surpriseMe(model) }
                } label: {
                    Label("Surprise Me", systemImage: "shuffle")
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityHint("Opens a well-rated \(kind == .movies ? "film" : "show") picked for you\(model.filter.isNarrowed ? " that matches your filters" : "")")

                Button {
                    showFilters = true
                } label: {
                    Label(model.filter.isNarrowed ? "Filters · \(model.filter.activeChips.count)" : "Filters",
                          systemImage: "line.3.horizontal.decrease")
                }
                .buttonStyle(SecondaryButtonStyle())
            }

            if model.filter.isNarrowed {
                activeFilters(model)
            }

            letterRail(model, proxy: proxy)
        }
        .padding(.horizontal, Metrics.screenMargin)
        .padding(.top, Metrics.space3)
        .padding(.bottom, Metrics.space2)
        // One region: pressing ↑ from the grid lands on the last-used control
        // here (a chip or Filters), ↓ returns to the grid.
        .focusSection()
        .sheet(isPresented: $showFilters) {
            FilterSheet(
                filter: Binding(get: { model.filter }, set: { model.filter = $0 }),
                genres: model.availableGenres,
                audio: model.availableAudio,
                subtitles: model.availableSubtitles
            )
        }
    }

    /// Open a random title that matches the current filter.
    private func surpriseMe(_ model: VODBrowseViewModel) async {
        let ratings = await env.metadata.ratingsSnapshot()
        if let route = await model.surprisePick(ratings: ratings) { path.append(route) }
    }

    // MARK: - Categories

    private func openCategory(_ category: BrowseCategory, _ model: VODBrowseViewModel) {
        focusFirstAfterLoad = true
        model.open(category)
    }

    @ViewBuilder
    private func categoryOverview(_ model: VODBrowseViewModel) -> some View {
        let firstID = model.collections.first?.id ?? model.genreCategories.first?.id
        VStack(alignment: .leading, spacing: Metrics.space4) {
            if !model.collections.isEmpty {
                tileRow(title: "Collections", subtitle: "From your provider") {
                    ForEach(model.collections) { category in
                        CollectionTile(category: category) { openCategory(category, model) }
                            .sectionEntryFocus(category.id == firstID)
                            .onCardFocused { if isDeepInGrid { isDeepInGrid = false } }
                    }
                }
            }
            if !model.genreCategories.isEmpty {
                tileRow(title: "Genres", subtitle: nil) {
                    ForEach(model.genreCategories) { category in
                        GenreTile(category: category) { openCategory(category, model) }
                            .sectionEntryFocus(category.id == firstID)
                            .onCardFocused { if isDeepInGrid { isDeepInGrid = false } }
                    }
                }
            }
            quickPicks(model)
        }
        .padding(.bottom, Metrics.space3)
    }

    private func tileRow<Content: View>(title: String, subtitle: String?,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Metrics.space2) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.space2) {
                Text(title).font(.dsSectionHeader).foregroundStyle(Palette.textPrimary)
                if let subtitle {
                    Text(subtitle).font(.dsCaption).foregroundStyle(Palette.textTertiary)
                }
            }
            .padding(.horizontal, Metrics.screenMargin)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Metrics.cardSpacing) { content() }
                    .padding(.horizontal, Metrics.screenMargin)
                    .padding(.vertical, Metrics.space2)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }

    /// One-click filters a Swedish viewer reaches for: language, picture,
    /// decade.
    private func quickPicks(_ model: VODBrowseViewModel) -> some View {
        var picks: [(String, String, (inout CatalogFilter) -> Void)] = [
            ("Swedish audio", "speaker.wave.2.fill", { $0.audioLanguages = [.swedish] }),
            ("Swedish subtitles", "captions.bubble.fill", { $0.subtitleLanguages = [.swedish] }),
            ("Full HD & 4K", "4k.tv.fill", { $0.minQuality = .fhd }),
            ("2020s", "calendar", { $0.minYear = 2020 }),
            ("2010s", "calendar", { $0.minYear = 2010; $0.maxYear = 2019 }),
            ("2000s", "calendar", { $0.minYear = 2000; $0.maxYear = 2009 }),
            ("90s", "calendar", { $0.minYear = 1990; $0.maxYear = 1999 }),
            ("Classics", "film.stack", { $0.maxYear = 1979 }),
        ]
        if model.musicCount > 0 {
            // Concerts and music videos live here, out of the main grid.
            picks.append(("Music & concerts", "music.note", { $0.music = .only }))
        }
        return VStack(alignment: .leading, spacing: Metrics.space2) {
            Text("Quick picks").font(.dsSectionHeader).foregroundStyle(Palette.textPrimary)
                .padding(.horizontal, Metrics.screenMargin)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Metrics.space2) {
                    ForEach(picks, id: \.0) { pick in
                        Button {
                            var next = CatalogFilter(sort: model.filter.sort)
                            pick.2(&next)
                            focusFirstAfterLoad = true
                            model.filter = next
                        } label: {
                            Label(pick.0, systemImage: pick.1)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                }
                .padding(.horizontal, Metrics.screenMargin)
                .padding(.vertical, Metrics.space2)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }

    /// "All Movies · For You" above the grid, or the category's count.
    private func gridHeading(_ model: VODBrowseViewModel) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.space2) {
            Text(model.filter.isNarrowed ? "\(model.total.formatted()) titles" : "All \(kind.title)")
                .font(.dsSectionHeader).foregroundStyle(Palette.textPrimary)
            Text(model.filter.sort.label)
                .font(.dsCaption).foregroundStyle(Palette.textTertiary)
        }
        .padding(.horizontal, Metrics.screenMargin)
    }

    /// What's narrowing the grid, each removable, plus "Show all".
    private func activeFilters(_ model: VODBrowseViewModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Metrics.space1) {
                Button {
                    model.clearFilters()
                    backToTop()
                } label: {
                    Label("All \(kind.title)", systemImage: "chevron.left")
                }
                .buttonStyle(SecondaryButtonStyle())
                ForEach(model.filter.collections, id: \.self) { name in
                    FilterChip(label: name, isSelected: true, showsRemoveIcon: true) {
                        model.filter.collections.removeAll { $0 == name }
                    }
                }
                ForEach(model.filter.genres, id: \.self) { genre in
                    FilterChip(label: genre.displayName, isSelected: true, showsRemoveIcon: true) {
                        toggleGenre(genre, model)
                    }
                }
                ForEach(otherChips(model), id: \.self) { chip in
                    FilterChip(label: chip, isSelected: true, showsRemoveIcon: false) { showFilters = true }
                }
            }
            .padding(.vertical, Metrics.space1)
            .padding(.horizontal, 2)
        }
        .scrollClipDisabled()
        .focusSection()
    }

    /// Chips for the narrowing that isn't a category or genre (language,
    /// years, quality) — they open Filters to change.
    private func otherChips(_ model: VODBrowseViewModel) -> [String] {
        var f = model.filter
        f.collections = []
        f.genres = []
        return f.activeChips
    }

    private func toggleGenre(_ genre: Genre, _ model: VODBrowseViewModel) {
        if let idx = model.filter.genres.firstIndex(of: genre) {
            model.filter.genres.remove(at: idx)
        } else {
            model.filter.genres.append(genre)
        }
    }
}
