import Foundation

/// A normalised series with its seasons and episodes.
public struct Series: Identifiable, Hashable, Codable, Sendable {
    public let id: CatalogID
    public let title: String
    public let year: Int?
    public let genres: [Genre]
    public let audioLanguages: [Language]
    public let subtitleLanguages: [Language]
    public let quality: VideoQuality
    public let countryCode: String?

    public let posterURL: URL?
    public let backdropURL: URL?
    public let synopsis: String?

    public var seasons: [Season]

    /// Provider's own key for on-demand episode loading (Xtream `series_id`).
    /// `nil` when the series was reconstructed from episode names (M3U).
    public let providerSeriesKey: String?

    /// When the provider added this to the library — for "Recently Added".
    public let addedAt: Date?

    /// Best-effort adult-category flag (see `AdultContentDetector`).
    public var isAdult: Bool

    public init(
        id: CatalogID,
        title: String,
        year: Int? = nil,
        genres: [Genre] = [],
        audioLanguages: [Language] = [],
        subtitleLanguages: [Language] = [],
        quality: VideoQuality = .unknown,
        countryCode: String? = nil,
        posterURL: URL? = nil,
        backdropURL: URL? = nil,
        synopsis: String? = nil,
        seasons: [Season] = [],
        providerSeriesKey: String? = nil,
        addedAt: Date? = nil,
        isAdult: Bool = false
    ) {
        self.id = id
        self.title = title
        self.year = year
        self.genres = genres
        self.audioLanguages = audioLanguages
        self.subtitleLanguages = subtitleLanguages
        self.quality = quality
        self.countryCode = countryCode
        self.posterURL = posterURL
        self.backdropURL = backdropURL
        self.synopsis = synopsis
        self.seasons = seasons
        self.providerSeriesKey = providerSeriesKey
        self.addedAt = addedAt
        self.isAdult = isAdult
    }

    public var episodeCount: Int {
        seasons.reduce(0) { $0 + $1.episodes.count }
    }

    public var hasEpisodes: Bool { !seasons.isEmpty }
}

public struct Season: Identifiable, Hashable, Codable, Sendable {
    /// Stable within a series: `"\(seriesID)-s\(number)"`.
    public var id: String { "\(seriesID.rawValue)-s\(number)" }
    public let seriesID: CatalogID
    public let number: Int
    public let episodes: [Episode]

    public init(seriesID: CatalogID, number: Int, episodes: [Episode]) {
        self.seriesID = seriesID
        self.number = number
        self.episodes = episodes
    }
}

public struct Episode: Identifiable, Hashable, Codable, Sendable {
    public let id: CatalogID
    public let seriesID: CatalogID
    public let seasonNumber: Int
    public let episodeNumber: Int
    public let title: String
    public let overview: String?
    public let durationMinutes: Int?
    public let stillURL: URL?
    public let streamURL: URL

    public init(
        id: CatalogID,
        seriesID: CatalogID,
        seasonNumber: Int,
        episodeNumber: Int,
        title: String,
        overview: String? = nil,
        durationMinutes: Int? = nil,
        stillURL: URL? = nil,
        streamURL: URL
    ) {
        self.id = id
        self.seriesID = seriesID
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.title = title
        self.overview = overview
        self.durationMinutes = durationMinutes
        self.stillURL = stillURL
        self.streamURL = streamURL
    }

    /// `"S02E05"` style label.
    public var code: String {
        String(format: "S%02dE%02d", seasonNumber, episodeNumber)
    }
}

public extension Series {
    /// "3 seasons" once the season tree is loaded; before that (Xtream shells
    /// load episodes on demand) "2019 · Drama" — never "0 seasons".
    var cardSubtitle: String {
        if seasons.isEmpty {
            return [year.map(String.init), genres.first?.displayName]
                .compactMap { $0 }.joined(separator: " · ")
        }
        return "\(seasons.count) \(seasons.count == 1 ? "säsong" : "säsonger")"
    }
}
