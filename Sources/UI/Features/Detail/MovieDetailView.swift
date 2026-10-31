import SwiftUI

struct MovieDetailView: View {
    let movieID: CatalogID

    @Environment(AppEnvironment.self) private var env
    @State private var movie: Movie?
    @State private var notFound = false
    @State private var playback: PlaybackItem?
    @State private var enriched: EnrichedMetadata?
    @State private var related: [RelatedItem] = []

    var body: some View {
        Group {
            if let movie {
                loaded(movie)
            } else if notFound {
                EmptyStateView(icon: "film", title: "Not available",
                               message: "This title isn't in your library anymore.")
            } else {
                ProgressView().controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: movieID) { await load() }
        .onChange(of: env.catalogRevision) { _, _ in
            // A deep link may open this before the VOD stage has merged in.
            if movie == nil { Task { await load() } }
        }
        .fullScreenCover(item: $playback) { item in
            PlayerScreen(
                item: item,
                preferredAudio: env.preferences.preferences.preferredAudioLanguages,
                preferredSubtitle: env.preferences.preferences.preferredSubtitleLanguage
            ) { id, kind, position, duration in
                env.recordProgress(id: id, kind: kind, position: position, duration: duration)
            }
        }
    }

    private func load() async {
        let found = await env.repository.movie(id: movieID)
        movie = found
        notFound = found == nil && env.catalogComplete
        guard let found else { return }
        var picks = await env.repository
            .similarMovies(to: found.id, genres: found.genres, limit: 18)
        if picks.isEmpty {
            // No genre tags (or nothing shares one) — fall back to fresh arrivals.
            picks = await env.repository.newestMovies(limit: 18).filter { $0.id != found.id }
        }
        related = picks.map { RelatedItem(id: $0.id, title: $0.title, year: $0.year,
                                          posterURL: $0.posterURL, isSeries: false) }
        enriched = await env.metadata.details(
            for: found.id, title: found.title, year: found.year, isSeries: false
        )
    }

    @ViewBuilder
    private func loaded(_ movie: Movie) -> some View {
        let progress = env.watchProgress.progress(for: movie.id)
        let backdrop = movie.backdropURL ?? enriched?.backdropURL ?? movie.posterURL ?? enriched?.posterURL

        DetailScaffold(title: movie.title, backdropURL: backdrop) {
            titleBlock(movie)
            actions(movie, progress: progress)
            info(movie)
            if let credits = enriched?.castCredits, !credits.isEmpty {
                CastRail(credits: credits)
            }
            RelatedRail(title: "More Like This", items: related)
        }
    }

    // MARK: - Sections

    /// Poster thumbnail beside the title block — the Apple TV+ detail signature.
    @ViewBuilder
    private func titleBlock(_ movie: Movie) -> some View {
        HStack(alignment: .bottom, spacing: Metrics.space4) {
            EnrichedArtwork(
                ref: ArtworkRef(id: movie.id, title: movie.title, year: movie.year, isSeries: false),
                providerURL: movie.posterURL, aspect: 2.0 / 3.0, style: .poster
            )
            .frame(width: 220, height: 330)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
            .accessibilityHidden(true)

            header(movie)
        }
    }

    @ViewBuilder
    private func header(_ movie: Movie) -> some View {
        let runtime = movie.durationMinutes ?? enriched?.runtime
        let genre = movie.genres.first?.displayName ?? enriched?.genres?.first

        VStack(alignment: .leading, spacing: Metrics.space2) {
            Text(movie.title).font(.dsHero).tracking(Metrics.heroTracking).lineLimit(2)

            HStack(spacing: Metrics.space2) {
                if let rating = enriched?.rating {
                    TMDBRatingBadge(rating: rating, votes: enriched?.voteCount)
                }
                MetadataLine([
                    movie.year.map(String.init),
                    genre,
                    runtime.map { "\($0 / 60)h \($0 % 60)m" },
                    movie.quality > .unknown ? movie.quality.shortLabel : nil,
                ])
            }

            if let tagline = enriched?.tagline {
                Text(tagline)
                    .font(.dsBody.italic())
                    .foregroundStyle(Palette.textTertiary)
            }
        }
    }

    @ViewBuilder
    private func actions(_ movie: Movie, progress: WatchProgress?) -> some View {
        VStack(alignment: .leading, spacing: Metrics.space2) {
            HStack(spacing: Metrics.space2) {
                Button {
                    Task { playback = await env.playback(forMovie: movie.id) }
                } label: {
                    Label(progress?.isResumable == true ? "Resume" : "Play", systemImage: "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .contextMenu {
                    if progress?.isFinished == true {
                        Button {
                            env.markUnwatched(id: movie.id)
                        } label: { Label("Mark as Unwatched", systemImage: "arrow.uturn.backward") }
                    } else {
                        Button {
                            env.markWatched(id: movie.id, kind: .movie)
                        } label: { Label("Mark as Watched", systemImage: "checkmark.circle") }
                    }
                    if progress?.isResumable == true {
                        Button(role: .destructive) {
                            env.removeFromContinueWatching(id: movie.id)
                        } label: { Label("Clear resume point", systemImage: "minus.circle") }
                    }
                }

                if progress?.isResumable == true {
                    Button {
                        Task { playback = await env.playback(forMovie: movie.id, fromStart: true) }
                    } label: {
                        Label("From Start", systemImage: "gobackward")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }

                Button {
                    env.favorites.toggle(id: movie.id, kind: .movie)
                } label: {
                    Image(systemName: env.favorites.isFavorite(movie.id) ? "heart.fill" : "heart")
                        .symbolEffect(.bounce, value: env.favorites.isFavorite(movie.id))
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityLabel(env.favorites.isFavorite(movie.id) ? "Remove from Favorites" : "Add to Favorites")
            }

            if let progress, progress.isResumable {
                ProgressView(value: progress.fraction) {
                    Text("Resume from \(timecode(progress.positionSeconds))")
                        .font(.dsCaption).foregroundStyle(Palette.textTertiary)
                }
                .tint(Palette.accent)
                .frame(maxWidth: 600)
            }
        }
    }

    @ViewBuilder
    private func info(_ movie: Movie) -> some View {
        let synopsis = movie.synopsis ?? enriched?.overview
        let textCast = movie.cast.isEmpty ? (enriched?.cast ?? []) : movie.cast
        let showTextCast = (enriched?.castCredits?.isEmpty ?? true) && !textCast.isEmpty

        VStack(alignment: .leading, spacing: Metrics.space2) {
            LanguageSummary(audio: movie.audioLanguages, subtitles: movie.subtitleLanguages)

            if let synopsis {
                Text(synopsis)
                    .font(.dsBody)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: 1100, alignment: .leading)
            }

            if !movie.directors.isEmpty {
                creditRow("Director", movie.directors)
            }
            if showTextCast {
                creditRow("Cast", textCast)
            }
        }
    }

    private func creditRow(_ label: String, _ names: [String]) -> some View {
        HStack(alignment: .top, spacing: Metrics.space2) {
            Text(label).font(.dsCaption).foregroundStyle(Palette.textTertiary)
                .frame(width: 140, alignment: .leading)
            Text(names.joined(separator: ", "))
                .font(.dsCaption).foregroundStyle(Palette.textSecondary)
        }
    }

    private func timecode(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}
