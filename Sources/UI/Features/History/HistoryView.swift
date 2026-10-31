import SwiftUI

/// Everything the user has watched or started, newest first. Press-and-hold a
/// row to remove it; "Clear All" wipes the lot (and the Continue Watching row).
struct HistoryView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var groups: [HistoryGroup] = []
    @State private var path: [AppRoute] = []
    @State private var confirmClear = false
    @State private var playback: PlaybackItem?

    struct HistoryRow: Identifiable {
        enum Resume { case movie(CatalogID), episode(Episode, seriesTitle: String) }

        let id: String
        let progressID: CatalogID
        let title: String
        let subtitle: String
        let art: URL?
        let fraction: Double
        let finished: Bool
        let route: AppRoute
        let resume: Resume
    }

    struct HistoryGroup: Identifiable {
        let id: String
        let rows: [HistoryRow]
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if groups.isEmpty, env.loadState.isImporting, !env.watchProgress.allEntries().isEmpty {
                    LibraryLoadingPlaceholder()
                } else if groups.isEmpty {
                    EmptyStateView(
                        icon: "clock.arrow.circlepath",
                        title: "Inget sett än",
                        message: "Filmer och avsnitt du spelar hamnar här, så att du kan fortsätta var som helst i appen."
                    )
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Metrics.shelfSpacing) {
                            header
                            ForEach(groups) { group in
                                VStack(alignment: .leading, spacing: Metrics.space2) {
                                    SectionHeader(group.id).padding(.horizontal, Metrics.screenMargin)
                                    VStack(spacing: Metrics.space2) {
                                        ForEach(group.rows) { row in
                                            HistoryRowView(
                                                row: row,
                                                onOpen: { path.append(row.route) },
                                                onResume: { Task { await resume(row) } },
                                                onRemove: { remove(row) }
                                            )
                                        }
                                    }
                                    .padding(.horizontal, Metrics.screenMargin)
                                }
                            }
                        }
                        .padding(.bottom, Metrics.space7)
                    }
                }
            }
            .appThemeBackground()
            .appRouteDestinations()
        }
        // Keyed on what's actually been watched — so playing something updates
        // the list, and merely returning from a detail screen doesn't.
        .task(id: env.watchProgress.revision) { await reload() }
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
    }

    private func resume(_ row: HistoryRow) async {
        switch row.resume {
        case .movie(let id):
            playback = await env.playback(forMovie: id)
        case .episode(let episode, let seriesTitle):
            playback = env.playback(forEpisode: episode, seriesTitle: seriesTitle)
        }
    }

    private var header: some View {
        HStack {
            Text("Historik").font(.dsTitle).accessibilityAddTraits(.isHeader)
            Spacer()
            Button(role: .destructive) { confirmClear = true } label: {
                Label("Rensa allt", systemImage: "trash")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, Metrics.screenMargin)
        .padding(.top, Metrics.space4)
        .alert("Rensa tittarhistoriken?", isPresented: $confirmClear) {
            Button("Rensa", role: .destructive) {
                env.watchProgress.clearAll()
                Task { await reload() }
            }
            Button("Avbryt", role: .cancel) {}
        } message: {
            Text("Alla återupptagningspunkter och raden Fortsätt titta tas bort. Favoriter och leverantör påverkas inte.")
        }
    }

    private func remove(_ row: HistoryRow) {
        env.watchProgress.clear(id: row.progressID)
        Task { await reload() }
    }

    private func reload() async {
        let repo = env.repository
        let entries = env.watchProgress.history()

        let movieIDs = entries.filter { $0.kind == .movie }.map(\.itemID)
        let episodeIDs = entries.filter { $0.kind == .series }.map(\.itemID)

        let movieHits = await repo.movies(ids: movieIDs)
        var episodes: [Episode] = []
        for id in episodeIDs {
            if let episode = await repo.episode(id: id) { episodes.append(episode) }
        }
        let seriesHits = await repo.series(ids: Array(Set(episodes.map(\.seriesID))))

        let moviesByID = Dictionary(movieHits.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let seriesByID = Dictionary(seriesHits.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var episodeIndex: [CatalogID: (series: Series, episode: Episode)] = [:]
        for episode in episodes {
            if let series = seriesByID[episode.seriesID] { episodeIndex[episode.id] = (series, episode) }
        }

        var inProgress: [HistoryRow] = []
        var watched: [HistoryRow] = []

        for entry in entries {
            guard let row = makeRow(for: entry, moviesByID: moviesByID, episodeIndex: episodeIndex) else { continue }
            if entry.isFinished { watched.append(row) } else { inProgress.append(row) }
        }

        groups = [
            HistoryGroup(id: "Påbörjat", rows: inProgress),
            HistoryGroup(id: "Sett", rows: watched),
        ].filter { !$0.rows.isEmpty }
    }

    private func makeRow(
        for entry: WatchProgress,
        moviesByID: [CatalogID: Movie],
        episodeIndex: [CatalogID: (series: Series, episode: Episode)]
    ) -> HistoryRow? {
        switch entry.kind {
        case .movie:
            guard let movie = moviesByID[entry.itemID] else { return nil }
            return HistoryRow(
                id: entry.itemID.rawValue,
                progressID: entry.itemID,
                title: movie.title,
                subtitle: [movie.year.map(String.init), movie.genres.first?.displayName]
                    .compactMap { $0 }.joined(separator: " · "),
                art: movie.posterURL,
                fraction: entry.fraction,
                finished: entry.isFinished,
                route: .movie(movie.id),
                resume: .movie(movie.id)
            )
        case .series:
            guard let (series, episode) = episodeIndex[entry.itemID] else { return nil }
            return HistoryRow(
                id: entry.itemID.rawValue,
                progressID: entry.itemID,
                title: series.title,
                subtitle: "\(episode.code) · \(episode.title)",
                art: episode.stillURL ?? series.posterURL,
                fraction: entry.fraction,
                finished: entry.isFinished,
                route: .series(series.id),
                resume: .episode(episode, seriesTitle: series.title)
            )
        case .liveChannel:
            return nil
        }
    }
}

private struct HistoryRowView: View {
    let row: HistoryView.HistoryRow
    let onOpen: () -> Void
    let onResume: () -> Void
    let onRemove: () -> Void

    var body: some View {
        Button(action: row.finished ? onOpen : onResume) {
            HStack(spacing: Metrics.space3) {
                ArtworkView(url: row.art, title: row.title, aspect: 16.0 / 9.0)
                    .frame(width: 240, height: 135)
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous))

                VStack(alignment: .leading, spacing: 8) {
                    Text(row.title)
                        .font(.dsCardTitle)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                    Text(row.subtitle)
                        .font(.dsCaption)
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(1)
                    if row.finished {
                        Label("Sett", systemImage: "checkmark.circle.fill")
                            .font(.dsTag)
                            .foregroundStyle(Palette.accent)
                    } else {
                        ProgressView(value: row.fraction)
                            .tint(Palette.accent)
                            .frame(maxWidth: 360)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(Metrics.space2)
        }
        .buttonStyle(.card)
        .contextMenu {
            if !row.finished {
                Button(action: onResume) { Label("Återuppta", systemImage: "play.fill") }
            }
            Button(action: onOpen) { Label("Gå till \(row.title)", systemImage: "info.circle") }
            Button(role: .destructive, action: onRemove) {
                Label("Ta bort från historiken", systemImage: "trash")
            }
        }
        .accessibilityLabel("\(row.title), \(row.subtitle)")
        .accessibilityHint(row.finished ? "Öppnar detaljer" : "Fortsätter uppspelningen. Håll inne för fler val.")
    }
}
