import Foundation

/// Turns a raw provider name into a clean display title.
///
///   "SE | TV4 HD [1080p]"          → "TV4"
///   "TV4.HD Sweden"                → "TV4"
///   "VOD: Sicario (2015) 1080p"    → "Sicario"      (+ year 2015 via `extractYear`)
///   "The Last of Us S01E03 MULTI"  → "The Last of Us S01E03"  (episode tags kept for EpisodeParser)
public enum TitleNormalizer {

    // Leading source markers: "VOD:", "SE |", "[EN]", "4K -", "|"
    private static let leadingJunk = CompiledPattern(
        #"^\s*(?:(?:vod|movie|film|serie|series|tv|live|hd|fhd|uhd|4k|sd)\s*[:\-\|]\s*)+"#
    )
    private static let leadingCountryTag = CompiledPattern(
        #"^\s*(?:\[[a-z]{2,3}\]|\([a-z]{2,3}\)|[a-z]{2,3}\s*[:\|]\s*)"#
    )

    // Bracketed tags anywhere: "[1080p]", "(SweSub)", "[MULTI]", "{VIP}"
    private static let bracketTags = CompiledPattern(#"\s*[\[\(\{][^\]\)\}]*[\]\)\}]"#)

    // Quality / codec / misc noise tokens as standalone words.
    private static let noiseWords = CompiledPattern(
        #"(?<![a-z])(?:hd|fhd|uhd|sd|4k|8k|1080p?|720p?|480p?|2160p?|h264|h265|hevc|x264|x265|hdr|dv|dolby|aac|ac3|multi|multisub|vip|backup|raw|web[\s\-]?dl|bluray|hdtv|restored|remastered)(?![a-z])"#
    )

    // Trailing country names that some providers append.
    private static let trailingCountry = CompiledPattern(
        #"[\s\-\|]+(?:sweden|sverige|norway|norge|denmark|danmark|finland|suomi|germany|deutschland|uk|usa|united\s?kingdom|united\s?states)\s*$"#
    )

    private static let year = CompiledPattern(#"(?<![0-9])((?:19|20)\d{2})(?![0-9])"#)

    /// A run of trailing language / subtitle tags on a movie title:
    /// "The Babadook EN SweSub" → "The Babadook". Deliberately does NOT include
    /// bare "us"/"it" so real one-word titles survive.
    private static let trailingLanguageTags = CompiledPattern(
        #"(?:\b(?:en|se|sv|swe|sve|eng|nor|dan|fin|ger|multi|nordic|dual|sub|subs|swesub|engsub|norsub|dansub|finsub|multisub|vo|vf|vostfr)\b[\s\-–—]*)+$"#
    )

    /// Full clean for a channel name (aggressive — strips quality, country, tags).
    public static func channelName(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
        s = leadingJunk.removingMatches(in: s)
        s = leadingCountryTag.removingMatches(in: s)
        s = bracketTags.removingMatches(in: s)
        s = noiseWords.removingMatches(in: s)
        s = trailingCountry.removingMatches(in: s)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " -–—:|/"))
        let cleaned = s.collapsingWhitespace()
        return cleaned.isEmpty ? raw.collapsingWhitespace() : cleaned
    }

    /// Clean for a movie title. Same as channel but we keep it a touch more
    /// conservative and also return the detected year.
    public static func movieTitle(_ raw: String) -> (title: String, year: Int?) {
        let detectedYear = extractYear(raw)
        var s = raw.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
        s = leadingJunk.removingMatches(in: s)
        s = leadingCountryTag.removingMatches(in: s)
        s = bracketTags.removingMatches(in: s)
        s = year.removingMatches(in: s)
        s = noiseWords.removingMatches(in: s)
        s = trailingCountry.removingMatches(in: s)
        s = s.collapsingWhitespace()
        s = trailingLanguageTags.removingMatches(in: s)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " -–—:|/"))
        let cleaned = s.collapsingWhitespace()
        return (cleaned.isEmpty ? raw.collapsingWhitespace() : cleaned, detectedYear)
    }

    /// Light clean for an episode name — strips bracketed tags and noise words
    /// but leaves the SxxExx marker in place for `EpisodeParser`.
    public static func episodeRawName(_ raw: String) -> String {
        // Scene-release names use "." / "_" as separators.
        var s = raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")
        s = leadingJunk.removingMatches(in: s)
        s = leadingCountryTag.removingMatches(in: s)
        s = bracketTags.removingMatches(in: s)
        s = noiseWords.removingMatches(in: s)
        return s.collapsingWhitespace()
    }

    public static func extractYear(_ raw: String) -> Int? {
        guard let groups = year.firstMatchGroups(raw),
              let match = groups[1],
              let value = Int(match) else { return nil }
        let currentYear = Calendar(identifier: .gregorian).component(.year, from: .now)
        guard value >= 1900, value <= currentYear + 2 else { return nil }
        return value
    }
}
