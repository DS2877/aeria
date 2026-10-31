import SwiftUI

struct VODBrowseView: View {
    let kind: BrowseKind

    @Environment(AppEnvironment.self) private var env
    @Environment(SectionModels.self) private var models
    @State private var model: VODBrowseViewModel?
    @State private var showFilters = false
    @State private var path: [AppRoute] = []

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
            model?.scheduleReload()
        }
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
        }
        .onChange(of: model.filter) { old, new in
            // A narrowing change (genre / language / year) resets the list —
            // snap to the top. A pure sort change keeps position.
            if old.isNarrowed != new.isNarrowed || old.genres != new.genres
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
                Text(kind.title).font(.dsTitle).accessibilityAddTraits(.isHeader)
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
                .accessibilityHint("Opens a random \(kind == .movies ? "film" : "show")\(model.filter.isNarrowed ? " that matches your filters" : "")")

                Button {
                    showFilters = true
                } label: {
                    Label(model.filter.isNarrowed ? "Filters · \(model.filter.activeChips.count)" : "Filters",
                          systemImage: "line.3.horizontal.decrease")
                }
                .buttonStyle(SecondaryButtonStyle())
            }

            if !model.availableGenres.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Metrics.space1) {
                        ForEach(model.availableGenres, id: \.self) { genre in
                            FilterChip(
                                label: genre.displayName,
                                isSelected: model.filter.genres.contains(genre)
                            ) {
                                toggleGenre(genre, model)
                            }
                        }
                    }
                    .padding(.vertical, Metrics.space1)
                    .padding(.horizontal, 2)
                }
                .scrollClipDisabled()
                .focusSection()
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
        switch kind {
        case .movies:
            if let m = await env.repository.randomMovie(filter: model.filter) { path.append(.movie(m.id)) }
        case .series:
            if let s = await env.repository.randomSeries(filter: model.filter) { path.append(.series(s.id)) }
        }
    }

    private func toggleGenre(_ genre: Genre, _ model: VODBrowseViewModel) {
        if let idx = model.filter.genres.firstIndex(of: genre) {
            model.filter.genres.remove(at: idx)
        } else {
            model.filter.genres.append(genre)
        }
    }
}
