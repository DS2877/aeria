import SwiftUI

struct SeriesDetailView: View {
    let seriesID: CatalogID

    @Environment(AppEnvironment.self) private var env
    @State private var series: Series?
    @State private var notFound = false
    @State private var loadingEpisodes = false
    @State private var selectedSeason: Int?
    @State private var playback: PlaybackItem?
    @State private var enriched: EnrichedMetadata?
    @State private var related: [RelatedItem] = []
    @State private var episodeStills: [Int: URL] = [:]

    var body: some View {
        Group {
            if let series {
                loaded(series)
            } else if notFound {
                EmptyStateView(icon: "rectangle.stack", title: "Not available",
                               message: "This series isn't in your library anymore.")
            } else {
                ProgressView().controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: seriesID) { await load() }
        .onChange(of: env.catalogRevision) { _, _ in
            if series == nil { Task { await load() } }
        }
        .fullScreenCover(item: $playback) { item in
            PlayerScreen(
                item: item,
                preferredAudio: env.preferences.preferences.preferredAudioLanguages,
                preferredSubtitle: env.preferences.preferences.preferredSubtitleLanguage,
                nextItem: { await env.nextEpisodePlayback(after: $0) }
            ) { id, kind, position, duration in
                env.recordProgress(id: id, kind: kind, position: position, duration: duration)
            }
        }
        .task(id: stillsKey) {
            guard let tmdbID = enriched?.tmdbID, tmdbID > 0, let season = selectedSeason else { return }
            episodeStills = await env.metadata.episodeStills(seriesTMDBID: tmdbID, season: season)
        }
        // Next-episode autoplay happens inside the player now (Up Next
        // countdown via `nextItem`), so there's no close-and-reopen here.
    }

    /// Paint first, fill in after: the page shows the moment the catalog row
    /// is read. Episodes (a provider request on first open), related titles
    /// and TMDB details all arrive in parallel behind it.
    private func load() async {
        let found = await env.repository.series(id: seriesID)
        notFound = found == nil && env.catalogComplete
        guard let found else { return }
        series = found
        selectedSeason = resumeEpisode(in: found)?.seasonNumber ?? found.seasons.first?.number

        async let relatedPicks = relatedSeries(to: found)
        async let details = env.metadata.details(
            for: found.id, title: found.title, year: found.year, isSeries: true
        )
        if !found.hasEpisodes {
            loadingEpisodes = true
            let withEpisodes = await env.ensureEpisodes(forSeries: seriesID)
            loadingEpisodes = false
            if let withEpisodes, !Task.isCancelled {
                series = withEpisodes
                selectedSeason = resumeEpisode(in: withEpisodes)?.seasonNumber
                    ?? withEpisodes.seasons.first?.number
            }
        }
        related = await relatedPicks
        enriched = await details
    }

    private func relatedSeries(to found: Series) async -> [RelatedItem] {
        var picks = await env.repository
            .similarSeries(to: found.id, genres: found.genres, limit: 18)
        if picks.isEmpty {
            picks = await env.repository.newestSeries(limit: 18).filter { $0.id != found.id }
        }
        return picks.map { RelatedItem(id: $0.id, title: $0.title, year: $0.year,
                                       posterURL: $0.posterURL, isSeries: true) }
    }

    /// The very first episode — first season by number, first episode by number.
    private func firstEpisode(in series: Series) -> Episode? {
        series.seasons
            .sorted { $0.number < $1.number }
            .compactMap { $0.episodes.min(by: { $0.episodeNumber < $1.episodeNumber }) }
            .first
    }

    /// What the primary button should play when nothing is mid-watch: the first
    /// unwatched episode after the latest finished one, else the very first.
    private func nextUnwatchedEpisode(in series: Series) -> Episode? {
        let ordered = series.seasons
            .sorted { $0.number < $1.number }
            .flatMap { $0.episodes.sorted { $0.episodeNumber < $1.episodeNumber } }
        guard !ordered.isEmpty else { return nil }
        let lastFinishedIdx = ordered.lastIndex {
            env.watchProgress.progress(for: $0.id)?.isFinished == true
        }
        guard let idx = lastFinishedIdx else { return ordered.first }
        return idx + 1 < ordered.count ? ordered[idx + 1] : ordered.first
    }

    /// The most recently-watched, not-yet-finished episode of this series.
    private func resumeEpisode(in series: Series?) -> Episode? {
        guard let series else { return nil }
        return series.seasons
            .flatMap(\.episodes)
            .compactMap { ep -> (episode: Episode, watched: Date)? in
                guard let p = env.watchProgress.progress(for: ep.id), p.isResumable else { return nil }
                return (ep, p.updatedAt)
            }
            .max { $0.watched < $1.watched }?
            .episode
    }

    @ViewBuilder
    private func loaded(_ series: Series) -> some View {
        let season = series.seasons.first { $0.number == selectedSeason } ?? series.seasons.first

        let backdrop = series.backdropURL ?? enriched?.backdropURL ?? series.posterURL ?? enriched?.posterURL

        DetailScaffold(title: series.title, backdropURL: backdrop, contentMaxWidth: 1600) {
            titleBlock(series)
            actions(series)
            info(series)
            if let credits = enriched?.castCredits, !credits.isEmpty {
                CastRail(credits: credits)
            }
            episodes(series, season: season)
            RelatedRail(title: "More Like This", items: related)
        }
    }

    // MARK: - Sections

    /// Poster thumbnail beside the title block — the Apple TV+ detail signature.
    @ViewBuilder
    private func titleBlock(_ series: Series) -> some View {
        HStack(alignment: .bottom, spacing: Metrics.space4) {
            EnrichedArtwork(
                ref: ArtworkRef(id: series.id, title: series.title, year: series.year, isSeries: true),
                providerURL: series.posterURL, aspect: 2.0 / 3.0, style: .poster
            )
            .frame(width: 220, height: 330)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
            .accessibilityHidden(true)

            header(series)
        }
    }

    @ViewBuilder
    private func header(_ series: Series) -> some View {
        let watched = episodesWatched(in: series)

        VStack(alignment: .leading, spacing: Metrics.space2) {
            Text(series.title).font(.dsHero).tracking(Metrics.heroTracking).lineLimit(2)

            HStack(spacing: Metrics.space2) {
                if let rating = enriched?.rating {
                    TMDBRatingBadge(rating: rating, votes: enriched?.voteCount)
                }
                MetadataLine([
                    series.year.map(String.init),
                    series.genres.first?.displayName ?? enriched?.genres?.first,
                    series.seasons.isEmpty ? nil
                        : "\(series.seasons.count) season\(series.seasons.count == 1 ? "" : "s")",
                    series.quality > .unknown ? series.quality.shortLabel : nil,
                ])
            }

            if let tagline = enriched?.tagline {
                Text(tagline)
                    .font(.dsBody.italic())
                    .foregroundStyle(Palette.textTertiary)
            }

            if watched.total > 0, watched.done > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    Text(watched.done >= watched.total
                         ? "All \(watched.total) episodes watched"
                         : "\(watched.done) of \(watched.total) episodes watched")
                        .font(.dsCaption).foregroundStyle(Palette.textTertiary)
                    ProgressView(value: Double(watched.done), total: Double(watched.total))
                        .tint(Palette.accent)
                        .frame(maxWidth: 360)
                }
                .padding(.top, 4)
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// Episodes marked finished across every loaded season.
    private func episodesWatched(in series: Series) -> (done: Int, total: Int) {
        let all = series.seasons.flatMap(\.episodes)
        let done = all.filter { env.watchProgress.progress(for: $0.id)?.isFinished == true }.count
        return (done, all.count)
    }

    @ViewBuilder
    private func actions(_ series: Series) -> some View {
        HStack(spacing: Metrics.space2) {
            if let resume = resumeEpisode(in: series) {
                Button {
                    playback = env.playback(forEpisode: resume, seriesTitle: series.title)
                } label: {
                    Label("Resume \(resume.code)", systemImage: "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle())

                if let first = firstEpisode(in: series), first.id != resume.id {
                    Button {
                        playback = env.playback(forEpisode: first, seriesTitle: series.title)
                    } label: {
                        Label("From Start", systemImage: "gobackward")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            } else if let next = nextUnwatchedEpisode(in: series) {
                let anyFinished = next.id != firstEpisode(in: series)?.id
                Button {
                    playback = env.playback(forEpisode: next, seriesTitle: series.title)
                } label: {
                    Label("\(anyFinished ? "Next" : "Play") \(next.code)", systemImage: "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle())

                if anyFinished, let first = firstEpisode(in: series) {
                    Button {
                        playback = env.playback(forEpisode: first, seriesTitle: series.title)
                    } label: {
                        Label("From Start", systemImage: "gobackward")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }

            Button {
                env.favorites.toggle(id: series.id, kind: .series)
            } label: {
                Image(systemName: env.favorites.isFavorite(series.id) ? "heart.fill" : "heart")
                    .symbolEffect(.bounce, value: env.favorites.isFavorite(series.id))
            }
            .buttonStyle(SecondaryButtonStyle())
            .accessibilityLabel(env.favorites.isFavorite(series.id) ? "Remove from Favorites" : "Add to Favorites")
        }
    }

    @ViewBuilder
    private func info(_ series: Series) -> some View {
        let synopsis = series.synopsis ?? enriched?.overview
        let textCast = enriched?.cast ?? []
        let showTextCast = (enriched?.castCredits?.isEmpty ?? true) && !textCast.isEmpty

        VStack(alignment: .leading, spacing: Metrics.space2) {
            LanguageSummary(audio: series.audioLanguages, subtitles: series.subtitleLanguages)

            if let synopsis {
                Text(synopsis).font(.dsBody).foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: 1100, alignment: .leading)
            }

            if showTextCast {
                creditRow("Cast", textCast)
            }
        }
    }

    @ViewBuilder
    private func episodes(_ series: Series, season: Season?) -> some View {
        VStack(alignment: .leading, spacing: Metrics.space3) {
            // Heading: "Season 2  ·  10 episodes" + the season toggle, right-aligned.
            HStack(alignment: .center, spacing: Metrics.space2) {
                Text(season.map { "Season \($0.number)" } ?? "Episodes")
                    .font(.dsSectionHeader)
                    .foregroundStyle(Palette.textPrimary)
                if let season, !season.episodes.isEmpty {
                    Text("·  \(season.episodes.count) episode\(season.episodes.count == 1 ? "" : "s")")
                        .font(.dsCaption)
                        .foregroundStyle(Palette.textTertiary)
                }
                Spacer(minLength: Metrics.space2)
                if let season, !season.episodes.isEmpty {
                    seasonWatchedButton(season)
                }
            }

            if series.seasons.count > 1 {
                seasonSelector(series)
            }

            if loadingEpisodes {
                HStack(spacing: Metrics.space2) {
                    ProgressView().tint(Palette.accent)
                    Text("Loading episodes…").font(.dsCaption).foregroundStyle(Palette.textTertiary)
                }
            } else if series.seasons.isEmpty {
                Text("No episodes available for this series.")
                    .font(.dsCaption).foregroundStyle(Palette.textTertiary)
            }

            if let season {
                VStack(spacing: Metrics.space2) {
                    ForEach(season.episodes) { episode in
                        episodeRow(episode, seriesTitle: series.title)
                    }
                }
            }
        }
    }

    /// Refetch episode stills whenever the matched series or the visible season
    /// changes.
    private var stillsKey: String { "\(enriched?.tmdbID ?? 0)-\(selectedSeason ?? 0)" }

    private func creditRow(_ label: String, _ names: [String]) -> some View {
        HStack(alignment: .top, spacing: Metrics.space2) {
            Text(label).font(.dsCaption).foregroundStyle(Palette.textTertiary)
                .frame(width: 140, alignment: .leading)
            Text(names.joined(separator: ", "))
                .font(.dsCaption).foregroundStyle(Palette.textSecondary)
        }
    }

    /// Toggles the whole visible season between watched and unwatched.
    private func seasonWatchedButton(_ season: Season) -> some View {
        let ids = season.episodes.map(\.id)
        let allWatched = ids.allSatisfy { env.watchProgress.progress(for: $0)?.isFinished == true }
        return Button {
            if allWatched {
                env.markEpisodesUnwatched(ids)
            } else {
                env.markEpisodesWatched(ids)
            }
        } label: {
            Label(allWatched ? "Mark season unwatched" : "Mark season watched",
                  systemImage: allWatched ? "arrow.uturn.backward" : "checkmark.circle")
        }
        .buttonStyle(SecondaryButtonStyle())
        .accessibilityLabel(allWatched ? "Mark whole season unwatched" : "Mark whole season watched")
    }

    private func seasonSelector(_ series: Series) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Metrics.space2) {
                ForEach(series.seasons) { season in
                    Button {
                        selectedSeason = season.number
                    } label: {
                        Text("Season \(season.number)")
                    }
                    .buttonStyle(SeasonButtonStyle(isSelected: season.number == selectedSeason))
                    .accessibilityAddTraits(season.number == selectedSeason ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.vertical, Metrics.space1)
            .padding(.horizontal, 2)
        }
        .scrollClipDisabled()
        .focusSection()
        .accessibilityLabel("Choose a season")
    }

    private func episodeRow(_ episode: Episode, seriesTitle: String) -> some View {
        let progress = env.watchProgress.progress(for: episode.id)
        let still = episodeStills[episode.episodeNumber] ?? episode.stillURL

        let watched = progress?.isFinished == true

        return Button {
            playback = env.playback(forEpisode: episode, seriesTitle: seriesTitle)
        } label: {
            HStack(alignment: .top, spacing: Metrics.space4) {
                ZStack {
                    ArtworkView(url: still, title: episode.title, aspect: 16.0 / 9.0, style: .backdrop)
                        .frame(width: 320, height: 180)
                        .opacity(watched ? 0.5 : 1)
                        .overlay(alignment: .bottom) {
                            if let progress, progress.isResumable {
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Rectangle().fill(.white.opacity(0.2))
                                        Rectangle().fill(Palette.accent)
                                            .frame(width: geo.size.width * progress.fraction)
                                    }
                                }
                                .frame(height: 4)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous))
                    Image(systemName: watched ? "checkmark.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(watched ? Palette.accent : .white.opacity(0.92))
                        .shadow(radius: 8)
                }

                VStack(alignment: .leading, spacing: Metrics.space1) {
                    HStack(alignment: .firstTextBaseline, spacing: Metrics.space2) {
                        Text(episode.code).font(.dsTag).foregroundStyle(Palette.textTertiary)
                        Text(episode.title)
                            .font(.dsCardTitle).foregroundStyle(Palette.textPrimary).lineLimit(1)
                        Spacer(minLength: 0)
                        if let mins = episode.durationMinutes, mins > 0 {
                            Text("\(mins) min").font(.dsTag).foregroundStyle(Palette.textTertiary)
                        }
                        if watched {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.dsCaption).foregroundStyle(Palette.accent)
                        }
                    }

                    if let overview = episode.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.dsCaption)
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let progress, progress.isResumable {
                        Text("Resume from \(Int(progress.fraction * 100))%")
                            .font(.dsTag).foregroundStyle(Palette.accent)
                            .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(RowButtonStyle())
        .contextMenu {
            if watched {
                Button {
                    env.markUnwatched(id: episode.id)
                } label: { Label("Mark as Unwatched", systemImage: "arrow.uturn.backward") }
            } else {
                Button {
                    env.markEpisodesWatched([episode.id])
                } label: { Label("Mark as Watched", systemImage: "checkmark.circle") }
            }
        }
        .accessibilityLabel("\(episode.code), \(episode.title)\(watched ? ", watched" : "")")
    }
}

/// A season chip in the series episode selector — bigger and clearer than a
/// generic `FilterChip`, with a solid accent fill when it's the chosen season.
private struct SeasonButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        SeasonButtonBody(configuration: configuration, isSelected: isSelected)
    }
}

private struct SeasonButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .font(.dsBody)
            .foregroundStyle(fg)
            .padding(.horizontal, Metrics.space3)
            .padding(.vertical, Metrics.space1 + 4)
            .background(Capsule().fill(bg))
            .overlay(Capsule().strokeBorder(isFocused || isSelected ? Palette.accent : Palette.hairline,
                                            lineWidth: 2))
            .scaleEffect(isFocused ? 1.06 : 1)
            .shadow(color: .black.opacity(isFocused ? 0.3 : 0), radius: isFocused ? 16 : 0, y: isFocused ? 8 : 0)
            .animation(Metrics.focusAnimation, value: isFocused)
    }

    private var fg: Color {
        if isFocused { return Palette.canvas }
        if isSelected { return Palette.textPrimary }
        return Palette.textSecondary
    }
    private var bg: Color {
        if isFocused { return Palette.focusFill }
        if isSelected { return Palette.accent.opacity(0.22) }
        return Palette.surface
    }
}
