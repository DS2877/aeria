import Foundation

/// Something the user can jump straight back into: a partly-watched movie, the
/// episode they're midway through, or the next episode after one they finished.
public struct ResumePoint: Identifiable, Hashable, Sendable {
    public enum Kind: Sendable, Hashable { case resumeMovie, resumeEpisode, nextEpisode }

    public let id: String
    public let kind: Kind
    /// What actually plays — a movie id or an episode id.
    public let itemID: CatalogID
    /// What a tap navigates to — a movie id or a series id.
    public let containerID: CatalogID
    public let isSeries: Bool
    /// Movie title, or series title.
    public let primaryTitle: String
    /// "48m left" · "S02E03 · Infected" · "Up Next · S02E04".
    public let secondaryText: String
    public let artworkURL: URL?
    /// Resume fraction 0…1; `0` for a fresh next episode.
    public let fraction: Double
    public let lastWatched: Date

    public init(
        id: String,
        kind: Kind,
        itemID: CatalogID,
        containerID: CatalogID,
        isSeries: Bool,
        primaryTitle: String,
        secondaryText: String,
        artworkURL: URL?,
        fraction: Double,
        lastWatched: Date
    ) {
        self.id = id
        self.kind = kind
        self.itemID = itemID
        self.containerID = containerID
        self.isSeries = isSeries
        self.primaryTitle = primaryTitle
        self.secondaryText = secondaryText
        self.artworkURL = artworkURL
        self.fraction = fraction
        self.lastWatched = lastWatched
    }
}

/// Turns raw watch progress into an ordered "keep watching" queue. Pure and
/// synchronous so it can run wherever the catalog snapshot is available.
public enum UpNext {

    /// One entry per movie / series the user is partway through, most recently
    /// watched first.
    ///
    /// - Movies: included while they have resumable progress.
    /// - Series: the most recent action on the series decides the entry —
    ///   the in-progress episode if there is one, otherwise the first later
    ///   episode they haven't finished. A series with every episode finished
    ///   drops out.
    public static func resumePoints(
        catalog: Catalog,
        progress: [WatchProgress],
        limit: Int = 20
    ) -> [ResumePoint] {
        let moviesByID = Dictionary(catalog.movies.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var episodeIndex: [CatalogID: (series: Series, episode: Episode)] = [:]
        var orderedEpisodes: [CatalogID: [Episode]] = [:]
        for series in catalog.series {
            let ordered = series.seasons
                .sorted { $0.number < $1.number }
                .flatMap { $0.episodes.sorted { $0.episodeNumber < $1.episodeNumber } }
            orderedEpisodes[series.id] = ordered
            for episode in ordered { episodeIndex[episode.id] = (series, episode) }
        }

        let finishedEpisodeIDs = Set(progress.filter { $0.kind == .series && $0.isFinished }.map(\.itemID))

        var points: [ResumePoint] = []
        var handledSeries: Set<CatalogID> = []

        for entry in progress.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            switch entry.kind {
            case .liveChannel:
                continue

            case .movie:
                guard entry.isResumable, let movie = moviesByID[entry.itemID] else { continue }
                points.append(ResumePoint(
                    id: "movie:\(movie.id.rawValue)",
                    kind: .resumeMovie,
                    itemID: movie.id,
                    containerID: movie.id,
                    isSeries: false,
                    primaryTitle: movie.title,
                    secondaryText: remainingText(fraction: entry.fraction, totalMinutes: movie.durationMinutes),
                    artworkURL: movie.posterURL,
                    fraction: entry.fraction,
                    lastWatched: entry.updatedAt
                ))

            case .series:
                guard let (series, episode) = episodeIndex[entry.itemID],
                      !handledSeries.contains(series.id) else { continue }
                handledSeries.insert(series.id)

                if entry.isResumable {
                    points.append(ResumePoint(
                        id: "episode:\(episode.id.rawValue)",
                        kind: .resumeEpisode,
                        itemID: episode.id,
                        containerID: series.id,
                        isSeries: true,
                        primaryTitle: series.title,
                        secondaryText: "\(episode.code) · \(episode.title)",
                        artworkURL: episode.stillURL ?? series.posterURL,
                        fraction: entry.fraction,
                        lastWatched: entry.updatedAt
                    ))
                } else if entry.isFinished,
                          let ordered = orderedEpisodes[series.id],
                          let idx = ordered.firstIndex(where: { $0.id == episode.id }),
                          let next = ordered[(idx + 1)...].first(where: { !finishedEpisodeIDs.contains($0.id) }) {
                    points.append(ResumePoint(
                        id: "next:\(next.id.rawValue)",
                        kind: .nextEpisode,
                        itemID: next.id,
                        containerID: series.id,
                        isSeries: true,
                        primaryTitle: series.title,
                        secondaryText: "Up Next · \(next.code)",
                        artworkURL: next.stillURL ?? series.posterURL,
                        fraction: 0,
                        lastWatched: entry.updatedAt
                    ))
                }
            }
        }

        return Array(points.prefix(limit))
    }

    static func remainingText(fraction: Double, totalMinutes: Int?) -> String {
        guard let totalMinutes, totalMinutes > 0 else {
            return "\(Int((fraction * 100).rounded()))% watched"
        }
        let left = Int((Double(totalMinutes) * (1 - fraction)).rounded())
        if left <= 0 { return "Almost done" }
        if left < 60 { return "\(left)m left" }
        return "\(left / 60)h \(left % 60)m left"
    }
}
