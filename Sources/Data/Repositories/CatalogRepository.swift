import Foundation

// The repository protocol now lives in `CatalogQuerying.swift` (SQLite-backed).
// This file keeps the value types the browse layer and that protocol share.

/// Composable, structured filter used by browse screens (distinct from
/// `SearchIntent`, which is the *parsed* form of a natural-language query —
/// though a `SearchIntent` maps cleanly onto a `CatalogFilter`).
/// A first-letter jump target for an A–Z browse list.
public struct BrowseAnchor: Identifiable, Sendable, Hashable {
    public let letter: String   // "A"…"Z" or "#"
    public let index: Int       // position in the sorted+filtered list
    public var id: String { letter }

    public init(letter: String, index: Int) {
        self.letter = letter
        self.index = index
    }
}

public enum ChannelSort: String, CaseIterable, Sendable {
    /// Your regulars first, then your country, then other Nordic / English, each
    /// tier by the provider's channel number.
    case number
    case nameAsc

    public var label: String {
        switch self {
        case .number:  return "For you"
        case .nameAsc: return "A–Z"
        }
    }
}

/// A browsable slice of Movies or Series — one of the provider's own sections
/// ("Netflix", "Barnfilm") or a genre — with how many titles it holds and a
/// poster to show on its tile.
public struct BrowseCategory: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case collection(String)
        case genre(Genre)
    }
    public let kind: Kind
    public let count: Int
    public let artworkURL: URL?

    public init(kind: Kind, count: Int, artworkURL: URL?) {
        self.kind = kind
        self.count = count
        self.artworkURL = artworkURL
    }

    public var id: String {
        switch kind {
        case .collection(let name): return "c:" + name
        case .genre(let genre):     return "g:" + genre.rawValue
        }
    }

    public var title: String {
        switch kind {
        case .collection(let name): return name
        case .genre(let genre):     return genre.displayName
        }
    }
}

/// What "For You" ranks by: your languages (most important first) and the
/// genres you watch most.
public struct ForYouProfile: Equatable, Sendable {
    public var languages: [Language]
    public var genres: [Genre]

    public init(languages: [Language] = [], genres: [Genre] = []) {
        self.languages = languages
        self.genres = genres
    }
}

public enum BrowseSort: String, CaseIterable, Sendable, Codable {
    /// Your languages, then your genres, then fresh — the default.
    case forYou
    case recentlyAdded
    case titleAscending
    case newest
    case oldest

    public var label: String {
        switch self {
        case .forYou:         return "For You"
        case .recentlyAdded:  return "Recently Added"
        case .titleAscending: return "A–Z"
        case .newest:         return "Newest"
        case .oldest:         return "Oldest"
        }
    }
}

public struct CatalogFilter: Equatable, Sendable {
    /// Pure music (concerts, music videos) lives apart from films and series.
    public enum Music: Equatable, Sendable {
        /// The default: browsing, Home, More Like This.
        case hidden
        /// The "Music" entry.
        case only
        /// Search — a concert should still be findable by name.
        case included
    }
    public var music: Music = .hidden
    public var genres: [Genre]
    /// Provider sections (`BrowseCategory.Kind.collection`) — any of them.
    public var collections: [String] = []
    public var audioLanguages: [Language]
    public var subtitleLanguages: [Language]
    public var minYear: Int?
    public var maxYear: Int?
    public var maxDurationMinutes: Int?
    public var minQuality: VideoQuality?
    public var text: String
    public var sort: BrowseSort
    /// Only read by `.forYou`. Not a filter — never narrows the list.
    public var forYou: ForYouProfile?

    public init(
        genres: [Genre] = [],
        audioLanguages: [Language] = [],
        subtitleLanguages: [Language] = [],
        minYear: Int? = nil,
        maxYear: Int? = nil,
        maxDurationMinutes: Int? = nil,
        minQuality: VideoQuality? = nil,
        text: String = "",
        sort: BrowseSort = .titleAscending,
        forYou: ForYouProfile? = nil
    ) {
        self.forYou = forYou
        self.genres = genres
        self.audioLanguages = audioLanguages
        self.subtitleLanguages = subtitleLanguages
        self.minYear = minYear
        self.maxYear = maxYear
        self.maxDurationMinutes = maxDurationMinutes
        self.minQuality = minQuality
        self.text = text
        self.sort = sort
    }

    /// Whether any narrowing filter is active (ignores sort + text).
    public var isNarrowed: Bool {
        music == .only || !genres.isEmpty || !collections.isEmpty || !audioLanguages.isEmpty || !subtitleLanguages.isEmpty
            || minYear != nil || maxYear != nil || maxDurationMinutes != nil || minQuality != nil
    }

    public var activeChips: [String] {
        var chips: [String] = []
        if music == .only { chips.append("Music") }
        chips += collections
        chips += genres.map(\.displayName)
        chips += audioLanguages.map { "\($0.displayName) audio" }
        chips += subtitleLanguages.map { "\($0.displayName) subs" }
        if let minYear, let maxYear { chips.append("\(minYear)–\(maxYear)") }
        else if let minYear { chips.append("From \(minYear)") }
        else if let maxYear { chips.append("Until \(maxYear)") }
        if let minQuality, minQuality > .unknown { chips.append("\(minQuality.shortLabel)+") }
        return chips
    }

    public static let none = CatalogFilter()

    public init(intent: SearchIntent) {
        let sort: BrowseSort = intent.sort == .newest ? .newest : .titleAscending
        self.init(
            genres: intent.genres,
            audioLanguages: intent.audioLanguages,
            subtitleLanguages: intent.subtitleLanguages,
            minYear: intent.minYear,
            maxYear: intent.maxYear,
            maxDurationMinutes: intent.maxDurationMinutes,
            minQuality: intent.minQuality,
            text: intent.freeText,
            sort: sort
        )
        music = .included
    }
}
