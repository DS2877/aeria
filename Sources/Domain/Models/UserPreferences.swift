import Foundation

/// The rows the Home screen can show, in display order. The user chooses which
/// are enabled during onboarding and in Settings.
public enum HomeRowKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case continueWatching
    case myList
    case liveNow
    case tonight
    case topRated
    case recentlyAdded
    case genres
    case inYourLanguages
    case withYourSubtitles
    case movies
    case series

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .continueWatching:  return "Fortsätt titta"
        case .myList:            return "Min lista"
        case .liveNow:           return "Direkt nu"
        case .tonight:           return "Ikväll"
        case .topRated:          return "Topp 10"
        case .genres:            return "Genrehyllor"
        case .recentlyAdded:     return "Senast tillagt"
        case .inYourLanguages:   return "På dina språk"
        case .withYourSubtitles: return "Med dina undertexter"
        case .movies:            return "Filmer"
        case .series:            return "Serier"
        }
    }

    public var explanation: String {
        switch self {
        case .continueWatching:  return "Fortsätt där du slutade"
        case .myList:            return "Allt du har lagt till i Favoriter"
        case .liveNow:           return "Vad som sänds på dina kanaler"
        case .tonight:           return "Kommande program ikväll"
        case .topRated:          return "Högst betygsatta filmerna och serierna i ditt bibliotek"
        case .genres:            return "En hylla för var och en av dina största genrer"
        case .recentlyAdded:     return "Det senaste i ditt bibliotek"
        case .inYourLanguages:   return "Innehåll på de språk du valt"
        case .withYourSubtitles: return "Titlar med undertexter på ditt språk"
        case .movies:            return "En hylla med filmer"
        case .series:            return "En hylla med serier"
        }
    }

    public static let defaultEnabled: [HomeRowKind] = allCases
}

/// How wide a net Live TV / Guide / the Home live rows cast for channels.
/// Sweden-first by default — a typical provider carries thousands of channels
/// from every country, and the vast majority are noise for this audience.
public enum ChannelRegionScope: String, Codable, Sendable, CaseIterable, Identifiable {
    /// The viewer's own country (from their language) plus generic/international
    /// feeds with no country tag. The default.
    case homeCountry
    /// …plus the other Nordic countries.
    case nordic
    /// …plus the English-speaking world and the rest of Europe.
    case european
    /// Every channel the provider carries.
    case all

    public var id: String { rawValue }

    /// The choices offered in Personalize. Aeria+ is Swedish-market only, so
    /// the wider nets aren't offered; saved values from before are clamped by
    /// `swedishMarket`.
    public static let offered: [ChannelRegionScope] = [.homeCountry, .nordic]

    /// This scope limited to what the Swedish market allows.
    public var swedishMarket: ChannelRegionScope {
        switch self {
        case .homeCountry, .nordic: return self
        case .european, .all:       return .nordic
        }
    }

    public var title: String {
        switch self {
        case .homeCountry: return "Bara Sverige"
        case .nordic:      return "Skandinavien"
        case .european:    return "Europa & engelska"
        case .all:         return "Allt"
        }
    }

    public var note: String {
        switch self {
        case .homeCountry: return "Svenska kanaler, plus internationella kanaler utan land"
        case .nordic:      return "Svenska, norska och danska kanaler"
        case .european:    return "Norden, engelskspråkiga länder och resten av Europa"
        case .all:         return "Inget filter — alla kanaler i leverantörens lista"
        }
    }
}

/// Everything the user has decided about how the app behaves. Persisted as JSON.
public struct UserPreferences: Codable, Sendable, Equatable {
    /// Languages the user cares about — used to prioritise content and power the
    /// "In Your Languages" row. Empty = no preference.
    public var preferredAudioLanguages: [Language]

    /// The user's subtitle language, if they rely on subtitles.
    public var preferredSubtitleLanguage: Language?

    /// Keep adult categories out of Home, browsing and search.
    public var hideAdultContent: Bool

    /// Hide movies / series from regions outside Europe and the English-speaking
    /// world (see `RelevanceFilter`). On by default — a typical provider is 90%
    /// noise for this audience.
    public var limitToRelevantRegions: Bool

    /// How wide a net Live TV / Guide / the Home live rows cast. Sweden-first by
    /// default; independent of `limitToRelevantRegions` (which governs VOD).
    public var channelRegionScope: ChannelRegionScope

    /// Which Home rows to show, in order.
    public var homeRows: [HomeRowKind]

    /// Default ordering for the browse grids.
    public var defaultSort: BrowseSort

    /// Autoplay the next episode of a series.
    public var autoPlayNextEpisode: Bool

    /// Use the AI-assisted parser for ambiguous searches (opt-in).
    public var aiAssistedSearch: Bool

    /// Set once the user has been through onboarding.
    public var hasOnboarded: Bool

    public init(
        preferredAudioLanguages: [Language] = [],
        preferredSubtitleLanguage: Language? = nil,
        hideAdultContent: Bool = true,
        limitToRelevantRegions: Bool = true,
        channelRegionScope: ChannelRegionScope = .homeCountry,
        homeRows: [HomeRowKind] = HomeRowKind.defaultEnabled,
        defaultSort: BrowseSort = .recentlyAdded,
        autoPlayNextEpisode: Bool = true,
        aiAssistedSearch: Bool = false,
        hasOnboarded: Bool = false
    ) {
        self.preferredAudioLanguages = preferredAudioLanguages
        self.preferredSubtitleLanguage = preferredSubtitleLanguage
        self.hideAdultContent = hideAdultContent
        self.limitToRelevantRegions = limitToRelevantRegions
        self.channelRegionScope = channelRegionScope
        self.homeRows = homeRows
        self.defaultSort = defaultSort
        self.autoPlayNextEpisode = autoPlayNextEpisode
        self.aiAssistedSearch = aiAssistedSearch
        self.hasOnboarded = hasOnboarded
    }

    public func isRowEnabled(_ kind: HomeRowKind) -> Bool { homeRows.contains(kind) }

    private enum CodingKeys: String, CodingKey {
        case preferredAudioLanguages, preferredSubtitleLanguage, hideAdultContent, limitToRelevantRegions
        case channelRegionScope
        case homeRows, defaultSort, autoPlayNextEpisode, aiAssistedSearch, hasOnboarded
    }

    // Lenient decoding: any key missing from stored JSON falls back to its
    // default, so new preference fields never wipe a user's existing settings.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = UserPreferences()
        preferredAudioLanguages   = try c.decodeIfPresent([Language].self, forKey: .preferredAudioLanguages) ?? d.preferredAudioLanguages
        preferredSubtitleLanguage = try c.decodeIfPresent(Language.self, forKey: .preferredSubtitleLanguage) ?? d.preferredSubtitleLanguage
        hideAdultContent          = try c.decodeIfPresent(Bool.self, forKey: .hideAdultContent) ?? d.hideAdultContent
        limitToRelevantRegions    = try c.decodeIfPresent(Bool.self, forKey: .limitToRelevantRegions) ?? d.limitToRelevantRegions
        channelRegionScope        = try c.decodeIfPresent(ChannelRegionScope.self, forKey: .channelRegionScope) ?? d.channelRegionScope
        homeRows                  = try c.decodeIfPresent([HomeRowKind].self, forKey: .homeRows) ?? d.homeRows
        defaultSort               = try c.decodeIfPresent(BrowseSort.self, forKey: .defaultSort) ?? d.defaultSort
        autoPlayNextEpisode       = try c.decodeIfPresent(Bool.self, forKey: .autoPlayNextEpisode) ?? d.autoPlayNextEpisode
        hasOnboarded              = try c.decodeIfPresent(Bool.self, forKey: .hasOnboarded) ?? d.hasOnboarded
        aiAssistedSearch          = try c.decodeIfPresent(Bool.self, forKey: .aiAssistedSearch) ?? d.aiAssistedSearch
    }
}
