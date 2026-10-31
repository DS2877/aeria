import SwiftUI

struct FavoritesView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var sections: [FavSection] = []
    @State private var path: [AppRoute] = []
    /// A favourite channel was clicked — it plays straight away.
    @State private var watching: CatalogID?
    private let channelColumns = Array(repeating: GridItem(.fixed(Metrics.wideCardWidth),
                                                           spacing: Metrics.cardSpacing), count: 4)

    private let columns = Array(repeating: GridItem(.fixed(Metrics.posterWidth), spacing: Metrics.cardSpacing),
                                count: 5)

    struct FavItem: Identifiable {
        let id: CatalogID
        let title: String
        let subtitle: String
        let art: URL?
        let route: AppRoute
        var ref: ArtworkRef?
    }
    struct FavSection: Identifiable {
        let id: String
        let items: [FavItem]
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if sections.isEmpty, env.loadState.isImporting, !env.favorites.all().isEmpty {
                    LibraryLoadingPlaceholder()
                } else if sections.isEmpty {
                    EmptyStateView(
                        icon: "heart",
                        title: "Inga favoriter än",
                        message: "Tryck på hjärtat på en film eller serie — eller håll inne på en kanal — så hamnar den här."
                    )
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Metrics.shelfSpacing) {
                            Text("Favoriter").font(.dsTitle)
                                .accessibilityAddTraits(.isHeader)
                                .padding(.horizontal, Metrics.screenMargin)
                                .padding(.top, Metrics.space4)

                            ForEach(sections) { section in
                                VStack(alignment: .leading, spacing: Metrics.space2) {
                                    SectionHeader(section.id).padding(.horizontal, Metrics.screenMargin)
                                    if section.items.first.map({ Self.isChannel($0.route) }) == true {
                                        // Channels: wide logo cards that play on click.
                                        LazyVGrid(columns: channelColumns, alignment: .leading,
                                                  spacing: Metrics.gridSpacing) {
                                            ForEach(section.items) { item in
                                                ChannelCard(name: item.title, logoURL: item.art,
                                                            nowTitle: item.subtitle) { watching = item.id }
                                                    .contextMenu {
                                                        ChannelContextMenu(channelID: item.id) {
                                                            path.append(item.route)
                                                        }
                                                    }
                                            }
                                        }
                                        .padding(.horizontal, Metrics.screenMargin)
                                    } else {
                                        LazyVGrid(columns: columns, alignment: .leading, spacing: Metrics.gridSpacing) {
                                            ForEach(section.items) { item in
                                                PosterCard(title: item.title, subtitle: item.subtitle,
                                                           artworkURL: item.art, ref: item.ref,
                                                           action: { path.append(item.route) })
                                            }
                                        }
                                        .padding(.horizontal, Metrics.screenMargin)
                                    }
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
        .liveChannelPlayer($watching)
        // Keyed on the *set* of favourites, so it reloads when you heart or
        // unheart something (including on a detail screen) and stays put —
        // scroll and focus intact — when you simply come back from one.
        .task(id: env.favorites.revision) { await reload() }
    }

    private static func isChannel(_ route: AppRoute) -> Bool {
        if case .channel = route { return true }
        return false
    }

    private func reload() async {
        let repo = env.repository
        let addedAt = Dictionary(env.favorites.all().map { ($0.itemID, $0.addedAt) },
                                 uniquingKeysWith: { a, _ in a })
        let ids = Array(addedAt.keys)
        // Most recently favourited first, within each section.
        func byRecency<T>(_ items: [T], id: (T) -> CatalogID) -> [T] {
            items.sorted { (addedAt[id($0)] ?? .distantPast) > (addedAt[id($1)] ?? .distantPast) }
        }

        let movieHits = await repo.movies(ids: ids)
        let seriesHits = await repo.series(ids: ids)
        let channelHits = await repo.channels(ids: ids)

        let movies = byRecency(movieHits, id: \.id).map { m in
            FavItem(id: m.id, title: m.title,
                    subtitle: [m.year.map(String.init), m.genres.first?.displayName].compactMap { $0 }.joined(separator: " · "),
                    art: m.posterURL, route: .movie(m.id),
                    ref: ArtworkRef(id: m.id, title: m.title, year: m.year, isSeries: false))
        }
        let series = byRecency(seriesHits, id: \.id).map { s in
            FavItem(id: s.id, title: s.title,
                    subtitle: s.cardSubtitle,
                    art: s.posterURL, route: .series(s.id),
                    ref: ArtworkRef(id: s.id, title: s.title, year: s.year, isSeries: true))
        }
        let channels = byRecency(channelHits, id: \.id).map { c in
            FavItem(id: c.id, title: c.name, subtitle: c.category, art: c.logoURL, route: .channel(c.id))
        }

        sections = [
            FavSection(id: "Filmer", items: movies),
            FavSection(id: "Serier", items: series),
            FavSection(id: "Kanaler", items: channels),
        ].filter { !$0.items.isEmpty }
    }
}
