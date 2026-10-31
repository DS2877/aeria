import Foundation

// MARK: - Content kind

/// What a catalog item fundamentally is. The UI branches on this, never on
/// provider-specific category strings.
public enum ContentKind: String, Codable, Sendable, CaseIterable {
    case liveChannel
    case movie
    case series
}

// MARK: - Stable identifier

/// A provider-independent identifier for a catalog item.
///
/// Built from a hash of the originating provider id + the provider's own id for
/// the item, so that favourites and watch progress survive a catalog refresh
/// even if the provider reorders or re-numbers its list.
public struct CatalogID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Derive a stable id from a provider id and the provider's own item key.
    /// Deterministic across launches so favourites / watch progress survive a
    /// catalog refresh.
    public init(providerID: String, kind: ContentKind, providerItemKey: String) {
        let digest = StableHash.hash([providerID, kind.rawValue, providerItemKey])
        self.rawValue = "\(kind.rawValue):\(String(digest, radix: 36))"
    }

    public var description: String { rawValue }
}

// MARK: - Language

/// A spoken or subtitle language, keyed by ISO 639-1 code.
public struct Language: Hashable, Codable, Sendable, Comparable {
    /// Lowercased ISO 639-1 code, e.g. `"en"`, `"sv"`.
    public let code: String

    public init?(code rawCode: String) {
        let cleaned = rawCode
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count == 2, cleaned.allSatisfy({ $0.isLetter }) else { return nil }
        self.code = cleaned
    }

    /// Localised display name for the current locale, falling back to the code.
    public var displayName: String {
        Locale.current.localizedString(forLanguageCode: code)?.capitalized
            ?? code.uppercased()
    }

    public static func < (lhs: Language, rhs: Language) -> Bool {
        lhs.displayName.localizedCompare(rhs.displayName) == .orderedAscending
    }

    // Common languages used across the app and tests.
    public static let english = Language(code: "en")!
    public static let swedish = Language(code: "sv")!
    public static let norwegian = Language(code: "no")!
    public static let danish = Language(code: "da")!
    public static let finnish = Language(code: "fi")!
    public static let icelandic = Language(code: "is")!
    public static let german = Language(code: "de")!
    public static let dutch = Language(code: "nl")!
    public static let french = Language(code: "fr")!
    public static let spanish = Language(code: "es")!
    public static let italian = Language(code: "it")!
    public static let portuguese = Language(code: "pt")!
    public static let polish = Language(code: "pl")!
    public static let czech = Language(code: "cs")!
    public static let greek = Language(code: "el")!
    public static let hungarian = Language(code: "hu")!
    public static let romanian = Language(code: "ro")!
    public static let turkish = Language(code: "tr")!
    public static let russian = Language(code: "ru")!
    public static let ukrainian = Language(code: "uk")!
    public static let arabic = Language(code: "ar")!

    /// The languages always offered in the personalize / settings pickers, so a
    /// viewer can pick a preference the current library hasn't surfaced yet.
    /// Nordic + the major European languages, plus the ones that show up most in
    /// European IPTV bundles.
    /// The Swedish market's languages — the only ones offered as audio /
    /// subtitle preferences (Aeria+ is Swedish-market only).
    public static let commonPickerChoices: [Language] = [
        .swedish, .english, .norwegian, .danish,
    ]
}

// MARK: - Freshness

/// Whether a catalog item counts as a "new" addition — drives the NEW badge on
/// cards and could later gate a "New this week" shelf.
public enum CatalogFreshness {
    /// Titles the provider added within this window are flagged new.
    public static let newWindow: TimeInterval = 12 * 24 * 3600

    public static func isNew(_ addedAt: Date?, now: Date = .now) -> Bool {
        guard let addedAt else { return false }
        let age = now.timeIntervalSince(addedAt)
        return age >= 0 && age < newWindow
    }
}

// MARK: - Video quality

public enum VideoQuality: String, Codable, Sendable, CaseIterable, Comparable {
    case unknown
    case sd
    case hd      // 720p
    case fhd     // 1080p
    case uhd     // 4K / 2160p

    private var rank: Int {
        switch self {
        case .unknown: return 0
        case .sd:      return 1
        case .hd:      return 2
        case .fhd:     return 3
        case .uhd:     return 4
        }
    }

    public static func < (lhs: VideoQuality, rhs: VideoQuality) -> Bool {
        lhs.rank < rhs.rank
    }

    public var shortLabel: String {
        switch self {
        case .unknown: return ""
        case .sd:      return "SD"
        case .hd:      return "HD"
        case .fhd:     return "FHD"
        case .uhd:     return "4K"
        }
    }
}

// MARK: - Genre

/// A normalised content genre. Kept as a small closed set plus `.other` so the
/// UI can rely on it; the raw string is preserved for enrichment later.
public enum Genre: String, Codable, Sendable, CaseIterable {
    case action, adventure, animation, comedy, crime, documentary, drama
    case family, fantasy, history, horror, music, mystery, romance
    case sciFi = "sci_fi"
    case thriller, war, western, kids, news, sport, reality
    case other

    public var displayName: String {
        switch self {
        case .sciFi: return "Sci-Fi"
        default:     return rawValue.capitalized
        }
    }
}
