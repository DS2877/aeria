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
        case .continueWatching:  return "Continue Watching"
        case .myList:            return "My List"
        case .liveNow:           return "Live Now"
        case .tonight:           return "Tonight"
        case .topRated:          return "Top Rated"
        case .genres:            return "Genre Shelves"
        case .recentlyAdded:     return "Recently Added"
        case .inYourLanguages:   return "In Your Languages"
        case .withYourSubtitles: return "With Your Subtitles"
        case .movies:            return "Movies"
        case .series:            return "Series"
        }
    }

    public var explanation: String {
        switch self {
        case .continueWatching:  return "Pick up where you left off"
        case .myList:            return "Everything you've added to Favorites"
        case .liveNow:           return "What's on across your channels"
        case .tonight:           return "Upcoming programmes this evening"
        case .topRated:          return "The highest-rated films and shows in your library"
        case .genres:            return "A shelf for each of your biggest genres"
        case .recentlyAdded:     return "The newest additions to your library"
        case .inYourLanguages:   return "Content in the languages you chose"
        case .withYourSubtitles: return "Titles subtitled in your language"
        case .movies:            return "A shelf of films"
        case .series:            return "A shelf of shows"
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
        case .homeCountry: return "My country only"
        case .nordic:      return "Scandinavia"
        case .european:    return "Europe & English"
        case .all:         return "Everything"
        }
    }

    public var note: String {
        switch self {
        case .homeCountry: return "Just channels from your country, plus international feeds"
        case .nordic:      return "Swedish, Norwegian and Danish channels"
        case .european:    return "The Nordics, the English-speaking world and the rest of Europe"
        case .all:         return "No filter — every channel in the provider's list"
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
        defaultSort: BrowseSort = .forYou,
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
