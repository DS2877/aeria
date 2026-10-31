import SwiftUI

/// Search, the Apple TV way: the system search keyboard at the top, results
/// updating underneath as you type, grouped by kind — channels (with what's on),
/// programmes in the guide, films, series. Plain titles, channel names, guide
/// programmes and free descriptions ("skräck med svenska undertexter") all work.
struct SearchView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(SectionModels.self) private var models
    @State private var model: SearchViewModel?
    @State private var path: [AppRoute] = []
    /// A channel (or a programme on now) was clicked — it plays straight away.
    @State private var watching: CatalogID?

    /// Shown on the empty screen — they double as a hint of what Search
    /// understands. Tapping one runs it.
    private let examples = [
        "Something scary with Swedish subtitles",
        "A comedy under 2 hours",
        "English series after 2018",
        "Something like Game of Thrones",
        "Kids' movies",
        "Documentaries",
    ]

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let model {
                    content(model)
                        .searchable(text: Binding(get: { model.query }, set: { model.query = $0 }),
                                    prompt: "Titles, channels, programmes — or describe it")
                        .onSubmit(of: .search) {
                            Task { await model.search(vocabulary: env.vocabulary) }
                        }
                        // As-you-type: a short pause after the last key, then
                        // search. A new key cancels the pending one.
                        .task(id: model.query) {
                            try? await Task.sleep(for: .milliseconds(320))
                            guard !Task.isCancelled else { return }
                            await model.liveSearch(vocabulary: env.vocabulary)
                        }
                } else {
                    Color.clear
                }
            }
            .appThemeBackground()
            .appRouteDestinations()
        }
        .liveChannelPlayer($watching)
        // Shared, so coming back to Search still shows your last results.
        // Re-fetched when the store resets (provider switch).
        .task(id: models.generation) { model = models.search(env) }
        .task(id: env.catalogRevision) {
            await models.search(env).loadTrending(ratings: await env.metadata.ratingsSnapshot(),
                                                  revision: env.catalogRevision)
        }
    }

    // MARK: - Layout

    private func content(_ model: SearchViewModel) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.shelfSpacing) {
                if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                    idleState(model)
                } else if model.isSearching && !model.hasAnyResult {
                    SkeletonShelf()
                    SkeletonShelf()
                } else if model.hasSearched && !model.hasAnyResult {
                    if env.loadState.isImporting {
                        LibraryLoadingPlaceholder().frame(minHeight: 360)
                    } else {
                        interpretation(model)
                        EmptyStateView(
                            icon: "magnifyingglass",
                            title: "Nothing matched",
                            message: "Nothing in your library or today's TV guide matches \u{201C}\(model.interpretedFrom)\u{201D}. Try fewer words, or remove a filter above."
                        )
                        .frame(maxWidth: .infinity, minHeight: 320)
                    }
                } else {
                    interpretation(model)
                    resultRows(model)
                }
            }
            .padding(.top, Metrics.space3)
            .padding(.bottom, Metrics.space7)
        }
    }

    /// The constraints the query was read as ("Horror", "Swedish subtitles",
    /// "Under 2h") — each removable. Hidden for plain title searches.
    @ViewBuilder
    private func interpretation(_ model: SearchViewModel) -> some View {
        if !model.chips.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Understood as").font(.dsCaption).foregroundStyle(Palette.textTertiary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Metrics.space1) {
                        ForEach(model.chips) { chip in
                            FilterChip(label: chip.label, isSelected: true, showsRemoveIcon: true) {
                                model.removeChip(chip)
                            }
                        }
                    }
                    .padding(.vertical, Metrics.space1)
                }
                .scrollClipDisabled()
            }
            .padding(.horizontal, Metrics.screenMargin)
            .focusSection()
        }
    }

    @ViewBuilder
    private func resultRows(_ model: SearchViewModel) -> some View {
        if !model.channels.isEmpty {
            Shelf(title: "Channels", items: model.channels) { channel in
                let now = model.channelNow[channel.id]
                ChannelCard(name: channel.name, logoURL: channel.logoURL,
                            nowTitle: now?.title, quality: channel.quality,
                            nowProgress: now.map { $0.progress(at: .now) },
                            channelNumber: channel.sortIndex) {
                    model.noteResultOpened()
                    watching = channel.id
                }
                .contextMenu {
                    ChannelContextMenu(channelID: channel.id) { open(.channel(channel.id), model) }
                }
            }
        }
        if !model.programmes.isEmpty {
            Shelf(title: "On TV", subtitle: "Today in the guide", items: model.programmes) { hit in
                // On now → watch it; later → the channel's schedule.
                ProgrammeCard(hit: hit) {
                    if hit.event.isLive(at: .now) {
                        model.noteResultOpened()
                        watching = hit.channel.id
                    } else {
                        open(.channel(hit.channel.id), model)
                    }
                }
            }
        }
        if !model.movies.isEmpty {
            Shelf(title: "Movies", items: model.movies) { movie in
                movieCard(movie, model)
            }
        }
        if !model.series.isEmpty {
            Shelf(title: "Series", items: model.series) { show in
                seriesCard(show, model)
            }
        }
    }

    @ViewBuilder
    private func idleState(_ model: SearchViewModel) -> some View {
        if !model.recentQueries.isEmpty {
            chipRow(title: "Recent searches", items: model.recentQueries, icon: "clock.arrow.circlepath",
                    trailing: AnyView(
                        Button("Clear") { model.clearRecents() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    )) { text in
                Task { await model.runRecent(text, vocabulary: env.vocabulary) }
            }
        }
        if !model.trending.isEmpty {
            Shelf(title: "Popular in your library", items: model.trending) { result in
                switch result.item {
                case .movie(let m):   movieCard(m, model)
                case .series(let s):  seriesCard(s, model)
                case .channel(let c): ChannelCard(name: c.name, logoURL: c.logoURL) { watching = c.id }
                }
            }
        }
        chipRow(title: "Try searching for", items: examples, icon: "sparkle", trailing: nil) { example in
            model.query = example
            Task { await model.search(vocabulary: env.vocabulary) }
        }
    }

    private func chipRow(title: String, items: [String], icon: String, trailing: AnyView?,
                         action: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: Metrics.space2) {
            HStack {
                SectionHeader(title)
                Spacer()
                if let trailing { trailing }
            }
            .padding(.horizontal, Metrics.screenMargin)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Metrics.space2) {
                    ForEach(items, id: \.self) { item in
                        Button { action(item) } label: {
                            Label(item, systemImage: icon).font(.dsBody)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.horizontal, Metrics.screenMargin)
                .padding(.vertical, Metrics.space2)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }

    // MARK: - Cards

    private func movieCard(_ m: Movie, _ model: SearchViewModel) -> some View {
        PosterCard(title: m.title,
                   subtitle: [m.year.map(String.init), m.genres.first?.displayName]
                       .compactMap { $0 }.joined(separator: " · "),
                   artworkURL: m.posterURL,
                   ref: ArtworkRef(id: m.id, title: m.title, year: m.year, isSeries: false),
                   isNew: CatalogFreshness.isNew(m.addedAt),
                   action: { open(.movie(m.id), model) })
    }

    private func seriesCard(_ s: Series, _ model: SearchViewModel) -> some View {
        PosterCard(title: s.title,
                   subtitle: s.cardSubtitle,
                   artworkURL: s.posterURL,
                   ref: ArtworkRef(id: s.id, title: s.title, year: s.year, isSeries: true),
                   isNew: CatalogFreshness.isNew(s.addedAt),
                   action: { open(.series(s.id), model) })
    }

    private func open(_ route: AppRoute, _ model: SearchViewModel) {
        model.noteResultOpened()
        path.append(route)
    }
}

/// A guide programme in search results: when, what, on which channel — with a
/// live badge and progress when it's on now.
private struct ProgrammeCard: View {
    let hit: ProgrammeHit
    let action: () -> Void

    var body: some View {
        let now = Date()
        let live = hit.event.isLive(at: now)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: Metrics.space1) {
                    Text(timeLabel(now: now))
                        .font(.dsTag)
                        .foregroundStyle(live ? Palette.accent : Palette.textSecondary)
                    if live { LiveBadge() }
                    Spacer(minLength: 0)
                }
                Text(hit.event.title)
                    .font(.dsCardTitle)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Text(hit.channel.name)
                    .font(.dsCaption)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
                if live {
                    ProgressView(value: hit.event.progress(at: now)).tint(Palette.accent)
                }
            }
            .padding(Metrics.space2)
            .frame(width: 300, height: 170, alignment: .leading)
        }
        .buttonStyle(.card)
        .accessibilityLabel("\(hit.event.title), \(hit.channel.name), \(timeLabel(now: now))\(live ? ", on now" : "")")
    }

    private func timeLabel(now: Date) -> String {
        let time = hit.event.start.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDate(hit.event.start, inSameDayAs: now) { return time }
        return "Tomorrow \(time)"
    }
}
