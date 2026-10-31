import Foundation

/// Decides whether a catalog item belongs in the app at all.
///
/// Aeria+ is built **exclusively for the Swedish market**. A typical Xtream
/// provider dumps tens of thousands of channels and VOD entries from every
/// region on earth; this keeps what a typical Swede watches — Swedish, the
/// Scandinavian neighbours they understand (Norwegian, Danish) and the
/// English-speaking world — plus anything with Swedish subtitles or
/// Swedish / English / Scandinavian audio, wherever it's from. Everything else
/// (Arabic, Turkish, South/East-Asian, Russian, African, Latin-American, and
/// continental-European TV such as Polish, Balkan or German feeds) is dropped
/// **at import** — it never reaches the store, any screen, or search.
public enum RelevanceFilter {

    /// Bump whenever the rules below change. Stored with each import; a library
    /// imported under older rules is refreshed on the next launch so it's
    /// re-filtered without the user doing anything.
    public static let rulesVersion = "se-market-1"

    public static let nordic: Set<String> = ["SE", "NO", "DK", "FI", "IS"]
    public static let english: Set<String> = ["GB", "IE", "US", "CA", "AU", "NZ"]

    /// Continental Europe kept under the region limit. Russia and Belarus are
    /// deliberately excluded; Turkey is treated as non-European here (the focus
    /// is the EU / EEA).
    public static let europe: Set<String> = [
        "DE", "FR", "ES", "IT", "PT", "NL", "BE", "AT", "CH", "LU",
        "PL", "CZ", "SK", "HU", "RO", "BG", "GR", "HR", "SI", "RS",
        "BA", "MK", "AL", "XK", "ME", "EE", "LV", "LT", "UA",
        "MT", "CY",
    ]

    /// The Swedish market: Sweden, the neighbours whose language Swedes
    /// understand, and the English-speaking world. Finland, Iceland and
    /// continental Europe are deliberately out — a typical Swede doesn't watch
    /// Finnish, Polish or German TV.
    public static let swedishMarket: Set<String> = ["SE", "NO", "DK"].union(english)

    /// ISO country codes kept. Everything with no detected country is also kept
    /// unless a foreign marker or a foreign script is found (generic /
    /// international feeds).
    public static let keptRegions: Set<String> = swedishMarket

    /// Audio languages that keep an item no matter where it's from — a Swede
    /// can follow it by ear.
    static let understoodAudioCodes: Set<String> = ["sv", "en", "no", "nb", "nn", "da"]
    /// Subtitle languages that do the same: Swedish subtitles are how Swedes
    /// watch foreign film and TV. (English subtitles alone don't — that let
    /// Arabic and Turkish series through.)
    static let understoodSubtitleCodes: Set<String> = ["sv"]

    /// Sort rank for a country: 0 = the viewer's home country, 1 = other Nordic,
    /// 2 = English / European / generic, 3 = anything else. Lower sorts first.
    public static func priority(countryCode: String?, home: Set<String>) -> Int {
        guard let code = countryCode else { return 2 }
        if home.contains(code) { return 0 }
        if nordic.contains(code) { return 1 }
        if english.contains(code) || europe.contains(code) { return 2 }
        return 3
    }

    /// The viewer's home country codes, from their chosen audio languages.
    /// Defaults to Sweden — the launch market.
    public static func homeRegions(for languages: [Language]) -> Set<String> {
        let map = ["sv": "SE", "no": "NO", "nb": "NO", "nn": "NO",
                   "da": "DK", "fi": "FI", "is": "IS", "en": "GB"]
        let codes = Set(languages.compactMap { map[$0.code] })
        return codes.isEmpty ? ["SE"] : codes
    }

    /// ISO country codes whose channels pass the given scope. `nil` means "no
    /// country filter — keep everything". Channels with no detected country are
    /// always kept (they're generic / international feeds, already marker-scanned
    /// by `is_relevant`); this only gates channels that *do* carry a country.
    public static func channelCountryCodes(for scope: ChannelRegionScope,
                                           home: Set<String>) -> Set<String>? {
        switch scope {
        case .homeCountry: return home
        case .nordic:      return home.union(nordic)
        case .european:    return home.union(nordic).union(english).union(europe)
        case .all:         return nil
        }
    }

    /// Single-word foreign-region markers that show up in provider category /
    /// channel names even when no clean country token was parsed. Matched as
    /// whole words (tokenised, not substring). European markers are intentionally
    /// absent — Europe is kept.
    private static let foreignMarkers: Set<String> = [
        "arab", "arabic", "mbc", "osn", "rotana",
        "turkish", "turkce", "turkiye",
        "hindi", "tamil", "telugu", "punjabi", "desi", "bollywood",
        "urdu", "pakistan", "bangla", "bengali", "afghan",
        "farsi", "persian", "kurdi", "kurdish",
        "hebrew", "israeli",
        "latino", "latinos", "espanol", "mexican",
        "brasil", "brazil", "brazilian",
        "russian", "russkie", "rossiya",
        "belarus",
        "chinese", "mandarin", "cantonese",
        "japanese", "korean",
        "vietnamese", "filipino", "pinoy", "indonesia", "malaysia", "khmer",
        "nigeria", "nollywood", "ghana", "ethiopia", "amharic",
        "somali", "somalia", "swahili",
        "thai", "tagalog", "albanian", "shqip",
    ]

    /// Continental-European language / country names, matched against the
    /// provider's **category** only — never a title, where "French" or
    /// "German" is often just a word ("The French Dispatch").
    private static let foreignCategoryMarkers: Set<String> = [
        "polish", "polska", "poland",
        "german", "deutsch", "deutschland", "germany",
        "french", "france", "francais",
        "italian", "italia", "italy",
        "spanish", "espana", "spain",
        "portugal", "portuguese",
        "dutch", "nederland", "netherlands", "belgium", "belgie",
        "greek", "greece", "ellada",
        "romania", "romanian",
        "serbia", "serbian", "srpski", "croatia", "croatian", "hrvatska",
        "bosnia", "bosnian", "balkan", "exyu", "yu", "yugoslavia", "macedonia",
        "hungary", "hungarian", "magyar",
        "czech", "slovakia", "slovak", "slovenia",
        "bulgaria", "bulgarian",
        "ukraine", "ukrainian",
        "albania", "kosovo",
        "finnish", "suomi", "finland", "iceland", "icelandic",
        "turkey",
    ]

    /// A title written mostly in a non-Latin script (Arabic, Hebrew, Cyrillic,
    /// Greek, Indic, Thai, CJK, Hangul …) isn't for a Swedish audience — the
    /// viewer can't even read its name.
    static func isMostlyForeignScript(_ text: String) -> Bool {
        var foreign = 0, latin = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            switch scalar.value {
            case 0x0041...0x024F, 0x1E00...0x1EFF: latin += 1
            case 0x0370...0x03FF,   // Greek
                 0x0400...0x052F,   // Cyrillic
                 0x0590...0x05FF,   // Hebrew
                 0x0600...0x08FF,   // Arabic, Syriac, Thaana, Arabic ext.
                 0x0900...0x0DFF,   // Indic scripts
                 0x0E00...0x0EFF,   // Thai, Lao
                 0x1100...0x11FF,   // Hangul Jamo
                 0x3040...0x30FF,   // Kana
                 0x3400...0x9FFF,   // CJK
                 0xAC00...0xD7AF,   // Hangul
                 0xFB1D...0xFDFF,   // Hebrew / Arabic presentation forms
                 0xFE70...0xFEFF:   // Arabic presentation forms
                foreign += 1
            default: break
            }
        }
        return foreign >= 2 && foreign >= latin
    }

    /// `true` when a provider section ("Arabic Movies", "TR | Series",
    /// "Polish VOD", "Ex-Yu") is foreign-market as a whole. Checked on the raw
    /// group title at import, before normalisation — VOD rows don't keep their
    /// section name, so this is the only point it can be seen.
    public static func isForeignSection(_ groupTitle: String?) -> Bool {
        guard let groupTitle, !groupTitle.isEmpty else { return false }
        if isMostlyForeignScript(groupTitle) { return true }
        let tokens = Set(groupTitle.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        return !foreignMarkers.isDisjoint(with: tokens)
            || !foreignCategoryMarkers.isDisjoint(with: tokens)
    }

    /// `true` when the item belongs in the Swedish-market catalog.
    public static func isRelevant(
        countryCode: String?,
        name: String,
        category: String,
        audioLanguages: [Language] = [],
        subtitleLanguages: [Language] = []
    ) -> Bool {
        // Can't read the name → not for this audience, whatever the tags say.
        if isMostlyForeignScript(name) { return false }

        func tokens(_ text: String) -> Set<String> {
            Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        }
        let categoryTokens = tokens(category)
        // A foreign-market *section* ("Arabic Movies", "Turkish Series") is out
        // even when it claims Swedish subtitles — providers stamp "MULTI SUB"
        // on whole foreign sections.
        guard foreignMarkers.isDisjoint(with: categoryTokens) else { return false }

        let audio = Set(audioLanguages.map(\.code))
        let understoodAudio = !audio.isDisjoint(with: understoodAudioCodes)
        // In a *name* the same words are weaker evidence ("Russian Doll"), so
        // they only count when nothing says the audio is one a Swede follows.
        if !understoodAudio, !foreignMarkers.isDisjoint(with: tokens(name)) { return false }

        // The escape hatch: a Swede can follow it — Swedish / English /
        // Scandinavian audio, or Swedish subtitles — wherever it's from.
        if understoodAudio { return true }
        if !Set(subtitleLanguages.map(\.code)).isDisjoint(with: understoodSubtitleCodes) { return true }

        if let code = countryCode {
            return keptRegions.contains(code)
        }

        // No parsed country — the provider's category is the last clue
        // ("Polish", "Ex-Yu", "German Movies"). Whole-word, tokenised once.
        return foreignCategoryMarkers.isDisjoint(with: categoryTokens)
    }
}
