import Foundation

/// A structured search request. Every natural-language query — whether parsed
/// on-device or by an LLM — is turned into one of these before it touches the
/// catalog. The parser never returns content, only constraints.
public struct SearchIntent: Equatable, Codable, Sendable {
    public enum Sort: String, Codable, Sendable {
        case relevance
        case newest
        case titleAscending
        case durationAscending
    }

    /// Which kinds of content to include. Empty means "any".
    public var kinds: [ContentKind]
    public var genres: [Genre]
    public var audioLanguages: [Language]
    public var subtitleLanguages: [Language]
    public var minYear: Int?
    public var maxYear: Int?
    public var maxDurationMinutes: Int?
    public var minQuality: VideoQuality?

    /// Leftover words to match against titles / metadata (e.g. `"batman"`).
    public var freeText: String

    /// Whether the query referenced "tonight" / "now" — the UI may route this to
    /// the EPG-driven Tonight experience instead of a catalog search.
    public var timeContext: TimeContext?

    public var sort: Sort

    public enum TimeContext: String, Codable, Sendable {
        case now
        case tonight
    }

    public init(
        kinds: [ContentKind] = [],
        genres: [Genre] = [],
        audioLanguages: [Language] = [],
        subtitleLanguages: [Language] = [],
        minYear: Int? = nil,
        maxYear: Int? = nil,
        maxDurationMinutes: Int? = nil,
        minQuality: VideoQuality? = nil,
        freeText: String = "",
        timeContext: TimeContext? = nil,
        sort: Sort = .relevance
    ) {
        self.kinds = kinds
        self.genres = genres
        self.audioLanguages = audioLanguages
        self.subtitleLanguages = subtitleLanguages
        self.minYear = minYear
        self.maxYear = maxYear
        self.maxDurationMinutes = maxDurationMinutes
        self.minQuality = minQuality
        self.freeText = freeText
        self.timeContext = timeContext
        self.sort = sort
    }

    public static let empty = SearchIntent()

    public var isEmpty: Bool {
        self == .empty
    }

    /// Human-readable chips shown back to the user, who can remove them.
    public var filterChips: [String] {
        var chips: [String] = []
        chips += kinds.map { kind in
            switch kind {
            case .movie: return "Movies"
            case .series: return "Series"
            case .liveChannel: return "Live TV"
            }
        }
        chips += genres.map(\.displayName)
        chips += audioLanguages.map { "\($0.displayName) audio" }
        chips += subtitleLanguages.map { "\($0.displayName) subtitles" }
        if let minYear, let maxYear { chips.append("\(minYear)–\(maxYear)") }
        else if let minYear { chips.append("After \(minYear - 1)") }
        else if let maxYear { chips.append("Before \(maxYear + 1)") }
        if let maxDurationMinutes {
            chips.append("Under \(maxDurationMinutes / 60 > 0 ? "\(maxDurationMinutes / 60)h" : "\(maxDurationMinutes)m")")
        }
        if let minQuality, minQuality > .unknown { chips.append(minQuality.shortLabel + "+") }
        return chips
    }
}
