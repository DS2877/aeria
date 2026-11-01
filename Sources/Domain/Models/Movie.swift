import Foundation

/// A normalised movie (VOD).
public struct Movie: Identifiable, Hashable, Codable, Sendable {
    public let id: CatalogID

    /// Clean title without year/quality tags, e.g. `"Sicario"`.
    public let title: String
    public let year: Int?
    public let genres: [Genre]
    public let durationMinutes: Int?
    public let audioLanguages: [Language]
    public let subtitleLanguages: [Language]
    public let quality: VideoQuality
    public let countryCode: String?

    public let posterURL: URL?
    public let backdropURL: URL?

    /// Optional, only present when the provider or an enrichment source gave us
    /// real metadata. Never fabricated.
    public let synopsis: String?
    public let cast: [String]
    public let directors: [String]

    public let streamURL: URL

    /// When the provider added this to the library — for "Recently Added".
    public let addedAt: Date?

    /// Best-effort adult-category flag (see `AdultContentDetector`).
    public var isAdult: Bool
    /// The provider's own section for this title, tidied ("Netflix",
    /// "Barnfilm", "4K") — what category browsing groups by. Write-side only:
    /// rows read back from the store leave it nil.
    public var collection: String? = nil

    public init(
        id: CatalogID,
        title: String,
        year: Int? = nil,
        genres: [Genre] = [],
        durationMinutes: Int? = nil,
        audioLanguages: [Language] = [],
        subtitleLanguages: [Language] = [],
        quality: VideoQuality = .unknown,
        countryCode: String? = nil,
        posterURL: URL? = nil,
        backdropURL: URL? = nil,
        synopsis: String? = nil,
        cast: [String] = [],
        directors: [String] = [],
        streamURL: URL,
        addedAt: Date? = nil,
        isAdult: Bool = false,
        collection: String? = nil
    ) {
        self.collection = collection
        self.id = id
        self.title = title
        self.year = year
        self.genres = genres
        self.durationMinutes = durationMinutes
        self.audioLanguages = audioLanguages
        self.subtitleLanguages = subtitleLanguages
        self.quality = quality
        self.countryCode = countryCode
        self.posterURL = posterURL
        self.backdropURL = backdropURL
        self.synopsis = synopsis
        self.cast = cast
        self.directors = directors
        self.streamURL = streamURL
        self.addedAt = addedAt
        self.isAdult = isAdult
    }
}
