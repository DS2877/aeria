import Foundation

public enum BrowseKind: Sendable {
    case movies
    case series

    var title: String {
        switch self {
        case .movies: return "Movies"
        case .series: return "Series"
        }
    }
}

/// A card in a browse grid — kind-agnostic.
public struct BrowseCard: Identifiable, Sendable {
    public let id: CatalogID
    public let route: AppRoute
    public let title: String
    public let subtitle: String?
    public let posterURL: URL?
    public let progress: Double?
    public let year: Int?
    public let isSeries: Bool
    /// Added to the library recently — shows a NEW pill.
    public let isNew: Bool

    public init(id: CatalogID, route: AppRoute, title: String, subtitle: String?,
                posterURL: URL?, progress: Double?, year: Int?, isSeries: Bool, isNew: Bool = false) {
        self.id = id
        self.route = route
        self.title = title
        self.subtitle = subtitle
        self.posterURL = posterURL
        self.progress = progress
        self.year = year
        self.isSeries = isSeries
        self.isNew = isNew
    }

    public var artworkRef: ArtworkRef {
        ArtworkRef(id: id, title: title, year: year, isSeries: isSeries)
    }
}

extension BrowseCard {
    init(movie: Movie, progress: Double?) {
        self.init(
            id: movie.id,
            route: .movie(movie.id),
            title: movie.title,
            subtitle: [movie.year.map(String.init), movie.genres.first?.displayName]
                .compactMap { $0 }.joined(separator: " · ").nilIfBlank,
            posterURL: movie.posterURL,
            progress: progress,
            year: movie.year,
            isSeries: false,
            isNew: CatalogFreshness.isNew(movie.addedAt)
        )
    }

    init(series: Series) {
        self.init(
            id: series.id,
            route: .series(series.id),
            title: series.title,
            subtitle: [series.year.map(String.init), series.genres.first?.displayName]
                .compactMap { $0 }.joined(separator: " · ").nilIfBlank,
            posterURL: series.posterURL,
            progress: nil,
            year: series.year,
            isSeries: true,
            isNew: CatalogFreshness.isNew(series.addedAt)
        )
    }
}

private extension String {
    var nilIfBlank: String? { trimmingCharacters(in: .whitespaces).isEmpty ? nil : self }
}
