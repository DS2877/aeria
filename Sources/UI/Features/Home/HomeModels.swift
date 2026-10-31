import Foundation

/// A single card's worth of data on the Home screen, kind-agnostic.
///
/// `Codable` so the whole shaped screen can be cached to disk and re-shown
/// instantly on the next launch (see `HomeSnapshotStore`).
public struct HomeCard: Identifiable, Sendable, Codable {
    public enum Kind: String, Sendable, Codable { case movie, series, channel }

    public let id: CatalogID
    public let kind: Kind
    public let title: String
    public let subtitle: String?
    public let artworkURL: URL?
    public let year: Int?
    public let badge: String?
    public let progress: Double?
    /// How far through the current live programme a channel card is (0…1).
    public let liveProgress: Double?
    /// Small uppercase line above the title (hero only): "2024 · Sci-Fi · 4K".
    public let eyebrow: String?
    /// For Continue Watching cards: the item that actually plays / gets marked
    /// watched (an episode or movie id), distinct from `id` (the container the
    /// card taps through to). `nil` for every other card.
    public let resumeItemID: CatalogID?
    /// Added to the library within the last `CatalogFreshness.newWindow` — shows
    /// a NEW pill.
    public let isNew: Bool

    public init(id: CatalogID, kind: Kind, title: String, subtitle: String?, artworkURL: URL?, year: Int? = nil, badge: String? = nil, progress: Double? = nil, liveProgress: Double? = nil, eyebrow: String? = nil, resumeItemID: CatalogID? = nil, isNew: Bool = false) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.year = year
        self.badge = badge
        self.progress = progress
        self.liveProgress = liveProgress
        self.eyebrow = eyebrow
        self.resumeItemID = resumeItemID
        self.isNew = isNew
    }

    /// A TMDB match reference for movie / series cards (nil for channels).
    public var artworkRef: ArtworkRef? {
        switch kind {
        case .movie:   return ArtworkRef(id: id, title: title, year: year, isSeries: false)
        case .series:  return ArtworkRef(id: id, title: title, year: year, isSeries: true)
        case .channel: return nil
        }
    }
}

public struct HomeRow: Identifiable, Sendable, Codable {
    /// How a row's cards are drawn.
    public enum Style: String, Sendable, Codable {
        /// 2:3 posters (channels draw as wide logo cards regardless).
        case poster
        /// 16:9 stills with progress — Continue Watching.
        case landscape
        /// Posters with a big rank numeral beside each — the Top 10.
        case ranked
    }

    public let id: String
    public let title: String
    public let subtitle: String?
    public let cards: [HomeCard]
    public let style: Style

    public init(id: String, title: String, subtitle: String?, cards: [HomeCard], style: Style = .poster) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.cards = cards
        self.style = style
    }
}

public struct TonightItem: Identifiable, Sendable, Codable {
    public let id: String
    public let channelID: CatalogID
    public let time: String
    public let programTitle: String
    public let channelName: String
    public let isLiveNow: Bool

    public init(id: String, channelID: CatalogID, time: String, programTitle: String,
                channelName: String, isLiveNow: Bool) {
        self.id = id
        self.channelID = channelID
        self.time = time
        self.programTitle = programTitle
        self.channelName = channelName
        self.isLiveNow = isLiveNow
    }
}

public struct HomeContent: Sendable, Codable {
    public var heroes: [HomeCard]
    public var rows: [HomeRow]
    public var tonight: [TonightItem]

    public init(heroes: [HomeCard], rows: [HomeRow], tonight: [TonightItem]) {
        self.heroes = heroes
        self.rows = rows
        self.tonight = tonight
    }

    public var hero: HomeCard? { heroes.first }

    public var isEmpty: Bool { heroes.isEmpty && rows.isEmpty }

    public static let empty = HomeContent(heroes: [], rows: [], tonight: [])
}
