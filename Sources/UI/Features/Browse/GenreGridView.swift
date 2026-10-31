import SwiftUI

/// A "see all" grid for one genre — every film and show in the library tagged
/// with it, newest first. Pushed from a Home genre shelf header, so it navigates
/// through the ambient `NavigationStack` with `NavigationLink(value:)`.
struct GenreGridView: View {
    let genre: Genre

    @Environment(AppEnvironment.self) private var env
    @State private var cards: [BrowseCard] = []
    @State private var page = 0
    @State private var canLoadMore = true
    @State private var isLoading = false

    private let columns = Array(repeating: GridItem(.fixed(Metrics.posterWidth), spacing: Metrics.cardSpacing),
                                count: 5)
    private let pageSize = 60

    private var filter: CatalogFilter {
        CatalogFilter(genres: [genre], sort: .recentlyAdded)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.space3) {
                Text(genre.displayName)
                    .font(.dsTitle)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, Metrics.space4)

                if cards.isEmpty, isLoading {
                    LibraryLoadingPlaceholder().frame(minHeight: 400)
                } else if cards.isEmpty {
                    EmptyStateView(icon: "film", title: "Nothing here",
                                   message: "No \(genre.displayName.lowercased()) titles in your library right now.")
                        .frame(minHeight: 400)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: Metrics.gridSpacing) {
                        ForEach(cards) { card in
                            NavigationLink(value: card.route) { poster(card) }
                                .buttonStyle(.card)
                                .task { await loadMoreIfNeeded(card) }
                        }
                    }
                    .padding(.bottom, Metrics.space7)
                }
            }
            .padding(.horizontal, Metrics.screenMargin)
        }
        .appThemeBackground()
        // Reloads on first appearance and whenever the catalog changes underneath
        // it (a background refresh finishing, a provider switch).
        .task(id: env.catalogRevision) { await reload() }
    }

    private func poster(_ card: BrowseCard) -> some View {
        VStack(alignment: .leading, spacing: Metrics.space1 + 2) {
            EnrichedArtwork(ref: card.artworkRef, providerURL: card.posterURL,
                            aspect: 2.0 / 3.0, style: .poster)
                .frame(width: Metrics.posterWidth, height: Metrics.posterHeight)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous))
                .overlay(alignment: .bottom) {
                    if let progress = card.progress, progress > 0 {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(.white.opacity(0.2))
                                Rectangle().fill(Palette.accent)
                                    .frame(width: geo.size.width * Swift.min(1, progress))
                            }
                        }
                        .frame(height: 4)
                        .padding(.horizontal, 12).padding(.bottom, 12)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(card.title).font(.dsCardTitle).foregroundStyle(Palette.textPrimary).lineLimit(1)
                if let subtitle = card.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.dsCaption).foregroundStyle(Palette.textSecondary).lineLimit(1)
                }
            }
        }
        .frame(width: Metrics.posterWidth, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.subtitle.map { "\(card.title), \($0)" } ?? card.title)
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        page = 0
        canLoadMore = true
        cards = await fetchPage()
        page = 1
    }

    private func loadMoreIfNeeded(_ card: BrowseCard) async {
        guard canLoadMore, !isLoading,
              let idx = cards.firstIndex(where: { $0.id == card.id }), idx >= cards.count - 10
        else { return }
        isLoading = true
        defer { isLoading = false }
        cards.append(contentsOf: await fetchPage())
        page += 1
    }

    /// One page each of movies + series of this genre, mapped to cards.
    private func fetchPage() async -> [BrowseCard] {
        let movies = await env.repository.movies(filter: filter, page: page, pageSize: pageSize)
        let series = await env.repository.series(filter: filter, page: page, pageSize: pageSize)
        canLoadMore = movies.count == pageSize || series.count == pageSize
        let movieCards = movies.map { movie -> BrowseCard in
            let f = env.watchProgress.fraction(for: movie.id)
            return BrowseCard(movie: movie, progress: f > 0 ? f : nil)
        }
        return movieCards + series.map { BrowseCard(series: $0) }
    }
}
