import SwiftUI

struct HomeView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SectionModels.self) private var models
    /// A handle on the shared model — the store owns it, so leaving and
    /// returning to Home doesn't rebuild the screen.
    @State private var model: HomeViewModel?
    @State private var path: [AppRoute] = []
    /// Playing a Continue Watching card straight from Home, no detail detour.
    @State private var playback: PlaybackItem?

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                // A restored snapshot outranks the load state: if we have real
                // content to show, show it — even while the library is still
                // loading behind it.
                if let model, !model.content.rows.isEmpty {
                    readyView(model: model)
                } else if case .failed(let error) = environment.loadState {
                    ErrorStateView(error: error, onRetry: {
                        Task { await environment.bootstrap(forceReload: true) }
                    })
                } else if environment.catalogComplete, model?.isBuilding == false {
                    // Loaded, built, and genuinely nothing to show.
                    EmptyStateView(
                        icon: "tv",
                        title: "Nothing to show yet",
                        message: "Your library loaded but came back empty. Check your provider in Settings."
                    )
                } else {
                    loadingView
                }
            }
            .transition(.opacity)
            // Skeleton → real content cross-fades instead of snapping. The
            // shelves the full pass adds settle in the same way.
            .animation(.easeInOut(duration: 0.32), value: contentFingerprint)
            .appThemeBackground()
            .appRouteDestinations()
        }
        .fullScreenCover(item: $playback) { item in
            PlayerScreen(
                item: item,
                preferredAudio: environment.preferences.preferences.preferredAudioLanguages,
                preferredSubtitle: environment.preferences.preferences.preferredSubtitleLanguage,
                nextItem: { await environment.nextEpisodePlayback(after: $0) }
            ) { id, kind, position, duration in
                environment.recordProgress(id: id, kind: kind, position: position, duration: duration)
            }
        }
        // Grab the shared model. On a first launch it restores the cached screen
        // from the last session — the "instant" frame. On a return visit it
        // already holds everything, so nothing reloads. Keyed on the store's
        // generation so a provider switch (which discards every model)
        // re-fetches the handle instead of holding the old one.
        .task(id: models.generation) {
            let shared = models.home(environment)
            model = shared
            if !shared.content.rows.isEmpty { prefetchArtwork(shared) }
        }
        .task(id: environment.loadState) {
            guard case .ready = environment.loadState else { return }
            let shared = models.home(environment)
            model = shared
            // Only rebuild if this screen hasn't been built against the catalog
            // as it stands now — coming back to Home is otherwise free.
            guard models.needsLoad(.home, revision: environment.catalogRevision) else {
                consumePendingRoute()
                return
            }
            let revision = environment.catalogRevision
            await shared.rebuild()
            // Marked only once the build actually finished. Switching section
            // mid-build cancels this task; marking up front would have left the
            // screen half-built and never retried.
            guard !Task.isCancelled else { return }
            models.markLoaded(.home, revision: revision)
            prefetchArtwork(shared)
            consumePendingRoute()
        }
        .onChange(of: environment.pendingRoute) { _, _ in consumePendingRoute() }
        // Returning to Home only rebuilds when something was actually watched —
        // otherwise browsing into a title and straight back out re-shaped the
        // whole screen for nothing.
        .onChange(of: watchRevisionAtRoot) { _, _ in
            guard path.isEmpty else { return }
            Task { await model?.rebuild() }
        }
        .onChange(of: favoritesRevisionAtRoot) { _, _ in
            // Hearted / unhearted something — refresh the My List row. Only while
            // Home is the visible screen, like the watch-progress rebuild.
            guard path.isEmpty else { return }
            Task { await model?.rebuild() }
        }
        .onChange(of: environment.isRefreshing) { _, refreshing in
            // A background library refresh just finished — rebuild shelves.
            if !refreshing { Task { await model?.rebuild() } }
        }
        .onChange(of: environment.preferences.preferences) { _, _ in
            Task { await model?.rebuild() }
        }
        .onChange(of: environment.catalogRevision) { _, revision in
            models.markLoaded(.home, revision: revision)
            Task {
                await model?.rebuild()
                if let model { prefetchArtwork(model) }
            }
        }
        .onChange(of: environment.metadataRevision) { _, _ in
            // Ratings only change how rows are shaped — no store queries.
            Task { await model?.refreshRatings() }
        }
    }

    /// Watch progress, but only while Home is the visible screen — so a rebuild
    /// fires once when you come back from playback, not while you're still deep
    /// in a detail screen scrubbing through something.
    private var watchRevisionAtRoot: Int {
        path.isEmpty ? environment.watchProgress.revision : -1
    }

    private var favoritesRevisionAtRoot: Int {
        path.isEmpty ? environment.favorites.revision : -1
    }

    /// Changes when the shape of the screen changes (skeleton ↔ content, or a
    /// pass adding rows) — drives the cross-fade without animating on every
    /// unrelated redraw.
    private var contentFingerprint: Int {
        (model?.content.rows.count ?? -1) * 8 + (model?.content.heroes.isEmpty == false ? 1 : 0)
    }

    /// Push a Top Shelf deep link onto the stack once Home is on screen and the
    /// catalog is loaded enough to resolve it.
    private func consumePendingRoute() {
        guard let route = environment.pendingRoute else { return }
        guard case .ready = environment.loadState else { return }
        if path.last != route { path.append(route) }
        environment.clearPendingRoute()
    }

    /// Warm the image cache for the hero and the first few rows so Home looks
    /// populated the instant it appears rather than filling in poster by poster.
    ///
    /// The hero is prefetched at backdrop resolution and the cards at poster
    /// resolution — warming them at the wrong size would decode twice and still
    /// miss when the view asks.
    private func prefetchArtwork(_ model: HomeViewModel) {
        // The lead hero first: it's the largest thing on screen and the one gap
        // the eye actually notices.
        ImageCache.shared.prefetch(Array(model.content.heroes.prefix(2)).compactMap(\.artworkURL),
                                   size: .backdrop)

        var cardURLs: [URL] = []
        for row in model.content.rows.prefix(3) {
            cardURLs += row.cards.prefix(8).compactMap(\.artworkURL)
        }
        ImageCache.shared.prefetch(cardURLs, size: .poster)
    }

    private var loadingView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.shelfSpacing) {
                SkeletonBox(cornerRadius: 0)
                    .frame(height: HeroBanner.height - HeroBanner.shelfOverlap)
                    .overlay(alignment: .bottomLeading) {
                        VStack(alignment: .leading, spacing: Metrics.space2) {
                            SkeletonBox(cornerRadius: 8).frame(width: 460, height: 56)
                            SkeletonBox(cornerRadius: 6).frame(width: 620, height: 24)
                            SkeletonBox(cornerRadius: 12).frame(width: 190, height: 54)
                                .padding(.top, Metrics.space2)
                        }
                        .padding(.horizontal, Metrics.screenMargin)
                        .padding(.bottom, Metrics.space5)
                    }
                SkeletonShelf()
                SkeletonShelf()
                SkeletonShelf()
            }
        }
        .scrollDisabled(true)
    }

    @ViewBuilder
    private func readyView(model: HomeViewModel) -> some View {
        if model.content.rows.isEmpty {
            EmptyStateView(
                icon: "tv",
                title: "Nothing to show yet",
                message: "Your library loaded but came back empty. Check your provider in Settings."
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !model.content.heroes.isEmpty {
                        // The first shelf rides up into the hero's fade — a
                        // peek that says "there's more below" without a scroll.
                        HeroBanner(heroes: model.content.heroes) { navigate($0) }
                            .padding(.bottom, -HeroBanner.shelfOverlap)
                            .focusSection()
                    }

                    LazyVStack(alignment: .leading, spacing: Metrics.shelfSpacing) {
                        // Your own shows come first: Tonight sits just under
                        // Continue Watching when there is one, else on top.
                        let tonightAfterResume = model.content.rows.first?.id == HomeRowKind.continueWatching.rawValue
                        if !model.content.tonight.isEmpty, !tonightAfterResume {
                            TonightRail(items: model.content.tonight)
                        }

                        ForEach(model.content.rows) { row in
                            Shelf(title: row.title, subtitle: row.subtitle, items: row.cards,
                                  headerRoute: Self.genre(for: row).map { AppRoute.genre($0) }) { card in
                                cardView(card, in: row)
                            }
                            if tonightAfterResume, row.id == HomeRowKind.continueWatching.rawValue,
                               !model.content.tonight.isEmpty {
                                TonightRail(items: model.content.tonight)
                            }
                        }
                    }
                }
                .padding(.bottom, Metrics.space7)
            }
        }
    }

    @ViewBuilder
    private func cardView(_ card: HomeCard, in row: HomeRow) -> some View {
        switch (row.style, card.kind) {
        case (.landscape, .movie), (.landscape, .series):
            ResumeCard(card: card, action: { activate(card) })
                .contextMenu { resumeMenu(for: card) }
        case (.ranked, .movie), (.ranked, .series):
            RankedPosterCard(rank: (row.cards.firstIndex { $0.id == card.id } ?? 0) + 1,
                             card: card, action: { activate(card) })
        default:
            standardCard(card)
        }
    }

    /// A Continue Watching card plays where you left off; every other card
    /// opens the detail screen.
    private func activate(_ card: HomeCard) {
        if card.resumeItemID != nil {
            Task { await resume(card) }
        } else {
            navigate(card)
        }
    }

    @ViewBuilder
    private func resumeMenu(for card: HomeCard) -> some View {
        if let itemID = card.resumeItemID {
            Button { navigate(card) } label: {
                Label("Go to \(card.title)", systemImage: "info.circle")
            }
            Button {
                environment.markWatched(id: itemID, kind: card.kind == .series ? .series : .movie)
                Task { await model?.rebuild() }
            } label: { Label("Mark as Watched", systemImage: "checkmark.circle") }

            Button(role: .destructive) {
                environment.removeFromContinueWatching(id: itemID)
                Task { await model?.rebuild() }
            } label: { Label("Remove", systemImage: "minus.circle") }
        }
    }

    @ViewBuilder
    private func standardCard(_ card: HomeCard) -> some View {
        switch card.kind {
        case .channel:
            ChannelCard(
                name: card.title,
                logoURL: card.artworkURL,
                nowTitle: card.subtitle,
                quality: .unknown,
                nowProgress: card.liveProgress,
                action: { navigate(card) }
            )
        case .movie, .series:
            PosterCard(
                title: card.title,
                subtitle: card.subtitle,
                artworkURL: card.artworkURL,
                ref: card.artworkRef,
                badge: card.badge,
                progress: card.progress,
                isNew: card.isNew,
                action: { activate(card) }
            )
            .contextMenu { resumeMenu(for: card) }
        }
    }

    private func navigate(_ card: HomeCard) {
        switch card.kind {
        case .movie:   path.append(.movie(card.id))
        case .series:  path.append(.series(card.id))
        case .channel: path.append(.channel(card.id))
        }
    }

    /// The genre a genre-shelf row names — its id is `"genre-<rawValue>"`.
    private static func genre(for row: HomeRow) -> Genre? {
        guard row.id.hasPrefix("genre-") else { return nil }
        return Genre(rawValue: String(row.id.dropFirst("genre-".count)))
    }

    /// Resume a Continue Watching card in place. `card.id` is the container
    /// (movie / series), `card.resumeItemID` is what actually plays.
    private func resume(_ card: HomeCard) async {
        guard let itemID = card.resumeItemID else { return }
        switch card.kind {
        case .movie:
            playback = await environment.playback(forMovie: itemID)
        case .series:
            // `card.title` is already the series title; the episode lookup is the
            // only thing we need from the store.
            guard let episode = await environment.repository.episode(id: itemID) else {
                navigate(card)   // episode is gone — fall back to the detail screen
                return
            }
            playback = environment.playback(forEpisode: episode, seriesTitle: card.title)
        case .channel:
            navigate(card)
        }
    }
}

/// The "Tonight" discovery rail — EPG-driven.
struct TonightRail: View {
    let items: [TonightItem]

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space2) {
            SectionHeader("Tonight", subtitle: "What's coming up across your channels")
                .padding(.horizontal, Metrics.screenMargin)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Metrics.space2) {
                    ForEach(items) { item in
                        NavigationLink(value: AppRoute.channel(item.channelID)) {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: Metrics.space1) {
                                    Text(item.time)
                                        .font(.dsTag)
                                        .foregroundStyle(Palette.accent)
                                    if item.isLiveNow { LiveBadge() }
                                    Spacer(minLength: 0)
                                }
                                Text(item.programTitle)
                                    .font(.dsCardTitle)
                                    .foregroundStyle(Palette.textPrimary)
                                    .lineLimit(2)
                                Spacer(minLength: 0)
                                Text(item.channelName)
                                    .font(.dsCaption)
                                    .foregroundStyle(Palette.textTertiary)
                                    .lineLimit(1)
                            }
                            .padding(Metrics.space2)
                            .frame(width: 256, height: 150, alignment: .leading)
                        }
                        .buttonStyle(.card)
                    }
                }
                .padding(.horizontal, Metrics.screenMargin)
                .padding(.vertical, Metrics.space3)
            }
        }
        .focusSection()
    }
}
