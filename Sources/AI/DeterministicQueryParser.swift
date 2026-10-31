import Foundation

/// On-device natural-language parser. Handles the majority of real queries with
/// no network call, no cost, and nothing leaving the device.
///
///   "scary movie with swedish subtitles"
///     → kinds:[movie] genres:[horror] subtitleLanguages:[sv]
///   "english series released after 2020"
///     → kinds:[series] audioLanguages:[en] minYear:2021
///   "something under 90 minutes tonight"
///     → maxDurationMinutes:90 timeContext:tonight
public struct DeterministicQueryParser: AIQueryParser {

    public init() {}

    public func parse(_ query: String, vocabulary: SearchVocabulary = .init()) async throws -> SearchIntent {
        parseSync(query, vocabulary: vocabulary)
    }

    /// Synchronous entry point for tests and for the AI fallback path.
    public func parseSync(_ query: String, vocabulary: SearchVocabulary = .init()) -> SearchIntent {
        let text = " " + query.lowercased().foldedForSearch() + " "
        var intent = SearchIntent()
        var consumed = Set<String>()

        // MARK: Kind
        // English and Swedish (folded: "säsong" → "sasong").
        let movieWords = ["movie", "movies", "film", "films", "cinema", "filmer", "filmen", "langfilm"]
        let seriesWords = ["series", "show", "shows", "tv show", "tv shows", "episode", "episodes", "season", "seasons",
                           "serie", "serier", "serien", "tv serie", "tv serier", "avsnitt", "sasong", "sasonger"]
        let channelWords = ["channel", "channels", "live tv", "live", "kanal", "kanaler", "kanalen", "direkt"]
        if text.containsWord(anyOf: movieWords) {
            intent.kinds.append(.movie); consumed.formUnion(movieWords)
        }
        if text.containsWord(anyOf: seriesWords) {
            intent.kinds.append(.series); consumed.formUnion(seriesWords)
        }
        if text.containsWord(anyOf: channelWords) {
            intent.kinds.append(.liveChannel); consumed.formUnion(channelWords)
        }

        // MARK: Genres (with mood synonyms)
        for (genre, terms) in Self.genreSynonyms {
            if text.containsWord(anyOf: terms) {
                if !intent.genres.contains(genre) { intent.genres.append(genre) }
                consumed.formUnion(terms)
            }
        }

        // MARK: Languages
        let (audio, subs, langWords) = Self.parseLanguages(text)
        intent.audioLanguages = audio
        intent.subtitleLanguages = subs
        consumed.formUnion(langWords)

        // MARK: Year constraints
        if let years = Self.parseYears(text) {
            intent.minYear = years.min
            intent.maxYear = years.max
        }

        // MARK: Duration
        if let minutes = Self.parseMaxDuration(text) {
            intent.maxDurationMinutes = minutes
        }

        // MARK: Quality
        let qualityTerms = ["4k", "uhd", "ultra hd", "2160p", "1080p", "full hd", "fhd", "hd", "720p"]
        if text.containsWord(anyOf: ["4k", "uhd", "ultra hd", "2160p"]) { intent.minQuality = .uhd }
        else if text.containsWord(anyOf: ["1080p", "full hd", "fhd"]) { intent.minQuality = .fhd }
        else if text.containsWord(anyOf: ["hd", "720p"]) { intent.minQuality = .hd }
        if intent.minQuality != nil { consumed.formUnion(qualityTerms) }

        // MARK: Time context
        if text.containsWord(anyOf: ["tonight", "this evening", "ikvall", "i kvall"]) { intent.timeContext = .tonight }
        else if text.containsWord(anyOf: ["right now", "on now", "whats on", "what is on", "just nu"]) { intent.timeContext = .now }

        // MARK: Sort hints
        if text.containsWord(anyOf: ["newest", "latest", "recent", "new releases", "nyaste", "senaste", "nysläppta", "nyslappta"]) {
            intent.sort = .newest
            consumed.formUnion(["newest", "latest", "recent", "nyaste", "senaste", "nyslappta"])
        } else if text.containsWord(anyOf: ["shortest", "quickest", "kortaste"]) {
            intent.sort = .durationAscending
            consumed.formUnion(["shortest", "quickest", "kortaste"])
        }

        // MARK: Free text — leftover meaningful words
        intent.freeText = Self.residualFreeText(query, consumed: consumed)

        return intent
    }

    // MARK: - Genre / mood synonyms

    /// English and Swedish mood / genre words, in folded form (no diacritics:
    /// "skräck" → "skrack", "dokumentär" → "dokumentar").
    static let genreSynonyms: [(Genre, [String])] = [
        (.horror,      ["horror", "scary", "spooky", "terrifying", "slasher", "creepy", "frightening",
                        "skrack", "skrackfilm", "skrackfilmer", "laskig", "laskigt", "laskiga", "rysare", "rysligt"]),
        (.comedy,      ["comedy", "funny", "hilarious", "lighthearted", "light hearted", "laugh",
                        "komedi", "komedier", "rolig", "roligt", "roliga", "lattsam", "humor"]),
        (.action,      ["action", "explosive", "fast paced", "action packed", "actionfilm", "actionfilmer"]),
        (.thriller,    ["thriller", "tense", "suspenseful", "edge of my seat", "gripping",
                        "thrillers", "spannande", "spanning", "nervkittlande"]),
        (.romance,     ["romance", "romantic", "love story", "date night",
                        "romantik", "romantisk", "romantiska", "karlek", "karleksfilm", "karlekshistoria"]),
        (.drama,       ["drama", "dramatic", "emotional", "moving", "tearjerker", "draman", "dramer", "gripande"]),
        (.sciFi,       ["sci fi", "scifi", "science fiction", "space", "futuristic", "dystopian", "aliens",
                        "rymden", "framtiden", "utomjordingar"]),
        (.fantasy,     ["fantasy", "magical", "medieval", "dragons", "epic", "magi", "magisk", "drakar"]),
        (.documentary, ["documentary", "documentaries", "true story", "docuseries",
                        "dokumentar", "dokumentarer", "dokumentarfilm", "dokumentarserie", "verklig historia"]),
        (.animation,   ["animated", "animation", "anime", "cartoon", "animerad", "animerat", "animerade",
                        "tecknad", "tecknat", "tecknade"]),
        (.crime,       ["crime", "heist", "detective", "noir", "true crime",
                        "kriminal", "deckare", "deckarserie", "brott", "polisserie", "kupp"]),
        (.mystery,     ["mystery", "whodunit", "puzzling", "mysterium", "mysterier", "gata"]),
        (.family,      ["family", "family friendly", "wholesome", "familj", "familjefilm", "hela familjen"]),
        (.kids,        ["kids", "children", "for my kids", "toddler", "barn", "barnen", "barnfilm",
                        "barnfilmer", "barnprogram", "for barn"]),
        (.war,         ["war", "wartime", "military", "krig", "krigsfilm", "andra varldskriget"]),
        (.western,     ["western", "cowboy", "wild west", "vilda vastern", "cowboys"]),
        (.history,     ["history", "historical", "period drama", "historisk", "historiska", "historia", "kostymdrama"]),
        (.sport,       ["sport", "sports", "football", "soccer", "basketball", "fotboll", "hockey", "ishockey"]),
    ]

    // MARK: - Languages

    private static let languageWords: [String: Language] = [
        "english": .english, "en": .english,
        "swedish": .swedish, "swede": .swedish, "sv": .swedish, "swe": .swedish, "sweden": .swedish,
        "norwegian": .norwegian, "norway": .norwegian,
        "danish": .danish, "denmark": .danish,
        "finnish": .finnish, "finland": .finnish,
        "german": .german, "germany": .german,
        "spanish": .spanish, "spain": .spanish,
        "french": .french, "france": .french,
        // Swedish (folded)
        "svensk": .swedish, "svenska": .swedish, "svenskt": .swedish, "sverige": .swedish,
        "engelsk": .english, "engelska": .english, "engelskt": .english,
        "norsk": .norwegian, "norska": .norwegian, "norskt": .norwegian, "norge": .norwegian,
        "dansk": .danish, "danska": .danish, "danskt": .danish, "danmark": .danish,
        "finsk": .finnish, "finska": .finnish,
        "tysk": .german, "tyska": .german, "spansk": .spanish, "spanska": .spanish,
        "fransk": .french, "franska": .french,
    ]

    static func parseLanguages(_ text: String) -> (audio: [Language], subs: [Language], words: Set<String>) {
        var audio: [Language] = []
        var subs: [Language] = []
        var words = Set<String>()

        // "swedish subtitles", "svenska undertexter", "svensk text"
        let subtitleContext = CompiledPattern(#"(\w+)\s+(?:sub|subs|subtitle|subtitles|subtitled|undertext|undertexter|text|textning|textad|textade)"#)
        // "subtitles in swedish", "undertexter pa svenska", "textad pa svenska"
        let subtitleContext2 = CompiledPattern(#"(?:sub|subs|subtitle|subtitles|undertext|undertexter|textad|textade|textat)\s+(?:in\s+|pa\s+)?(\w+)"#)
        // One word: "svensktextad", "swesub"
        for (word, lang) in [("svensktextad", Language.swedish), ("svensktextade", .swedish),
                             ("svensktextat", .swedish), ("swesub", .swedish), ("swesubs", .swedish),
                             ("engsub", .english)] where text.containsWord(anyOf: [word]) {
            if !subs.contains(lang) { subs.append(lang) }
            words.insert(word)
        }
        for pattern in [subtitleContext, subtitleContext2] {
            if let groups = pattern.firstMatchGroups(text), let word = groups[1]?.lowercased(),
               let lang = languageWords[word] {
                if !subs.contains(lang) { subs.append(lang) }
                words.insert(word)
                words.formUnion(["sub", "subs", "subtitle", "subtitles", "subtitled",
                                 "undertext", "undertexter", "text", "textning", "textad", "textade", "textat"])
            }
        }

        // "swedish audio", "svenskt tal", "svenskt ljud", "dubbad svenska"
        let audioContext = CompiledPattern(#"(\w+)[\s\-]?(?:audio|dub|dubbed|spoken|language|dialogue|tal|ljud|dubbad|dubbat|dubbade)"#)
        if let groups = audioContext.firstMatchGroups(text), let word = groups[1]?.lowercased(),
           let lang = languageWords[word] {
            if !audio.contains(lang) { audio.append(lang) }
            words.insert(word)
        }

        // A bare language mention with no "sub"/"audio" nearby → treat as audio.
        // Iterate a sorted key list so the result order is deterministic.
        for word in languageWords.keys.sorted() where word.count > 3 {
            guard let lang = languageWords[word] else { continue }
            if text.containsWord(anyOf: [word]), !subs.contains(lang), !audio.contains(lang),
               !words.contains(word) {
                audio.append(lang)
                words.insert(word)
            }
        }

        return (audio.sorted(), subs.sorted(), words)
    }

    // MARK: - Years

    static func parseYears(_ text: String) -> (min: Int?, max: Int?)? {
        let after = CompiledPattern(#"(?:after|since|from|newer than|efter|sedan|nyare an)\s+((?:19|20)\d{2})"#)
        let before = CompiledPattern(#"(?:before|until|older than|up to|fore|innan|aldre an)\s+((?:19|20)\d{2})"#)
        let inYear = CompiledPattern(#"(?:in|released in|from|fran|ar)\s+((?:19|20)\d{2})"#)
        // "90s", "1990s", "1990 talet" ("90-talet" folds to "90 talet")
        let decade = CompiledPattern(#"((?:19|20)\d0)(?:s|\s?talet)"#)
        // "90s", "80-talet" — two-digit decades are last century.
        let shortDecade = CompiledPattern(#"(?<!\d)([2-9]0)(?:s|\s?talet)"#)

        if let g = after.firstMatchGroups(text), let y = g[1].flatMap({ Int($0) }) {
            return (min: y + 1, max: nil)
        }
        if let g = before.firstMatchGroups(text), let y = g[1].flatMap({ Int($0) }) {
            return (min: nil, max: y - 1)
        }
        if let g = decade.firstMatchGroups(text), let y = g[1].flatMap({ Int($0) }) {
            return (min: y, max: y + 9)
        }
        if let g = shortDecade.firstMatchGroups(text), let y = g[1].flatMap({ Int($0) }) {
            return (min: 1900 + y, max: 1900 + y + 9)
        }
        if let g = inYear.firstMatchGroups(text), let y = g[1].flatMap({ Int($0) }) {
            return (min: y, max: y)
        }
        return nil
    }

    // MARK: - Duration

    private static let numberWords: [String: String] = [
        "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
        "couple of": "2",
        "en": "1", "ett": "1", "tva": "2", "tre": "3", "fyra": "4", "fem": "5",
    ]

    static func parseMaxDuration(_ rawText: String) -> Int? {
        // Normalise spelled-out small numbers: "under two hours" → "under 2 hours".
        var text = rawText
        for (word, digit) in numberWords {
            text = text.replacingOccurrences(of: " \(word) ", with: " \(digit) ")
        }
        // "under 2 hours", "less than 90 minutes", "shorter than 1h30"
        let limit = "under|less than|below|at most|max|maximum|shorter than|no more than|mindre an|kortare an|hogst|hogst|hochst|inte mer an"
        let hours = CompiledPattern(#"(?:"# + limit + #"|about|around|ungefar|runt)\s+(\d+(?:\.\d+)?)\s*(?:hours?|hrs?|h|timmar|timme|tim|t)\b"#)
        let mins  = CompiledPattern(#"(?:"# + limit + #")\s+(\d{2,3})\s*(?:minutes?|mins?|m|minuter|minut|min)\b"#)
        let hm    = CompiledPattern(#"(?:under|less than|below|at most|shorter than|mindre an|kortare an)\s+(\d)\s*h(?:our)?s?\s*(\d{1,2})"#)

        if let g = hm.firstMatchGroups(text),
           let h = g[1].flatMap({ Int($0) }), let m = g[2].flatMap({ Int($0) }) {
            return h * 60 + m
        }
        if let g = hours.firstMatchGroups(text), let value = g[1].flatMap({ Double($0) }) {
            return Int((value * 60).rounded())
        }
        if let g = mins.firstMatchGroups(text), let value = g[1].flatMap({ Int($0) }) {
            return value
        }
        if text.containsWord(anyOf: ["short film", "shorts"]) { return 40 }
        return nil
    }

    // MARK: - Residual free text

    /// Intent/filler words only — deliberately excludes title connectives like
    /// "of" and "the" so `"something like Game of Thrones"` keeps `"game of thrones"`.
    private static let stopWords: Set<String> = [
        "some", "something", "anything", "with", "and", "or",
        "me", "want", "wanna", "watch", "watching", "find", "get", "give", "see",
        "please", "can", "you", "your", "my", "we", "us", "im",
        "tonight", "now", "today", "this", "evening", "good", "great", "best",
        "like", "similar", "similiar", "recommend", "suggestion", "suggestions",
        "recommendation", "recommendations", "what", "whats", "that", "thats",
        "should", "could", "would", "there", "anything", "featuring", "about",
        "have", "has", "had", "are", "is", "was", "were", "been",
        "under", "over", "than", "then", "new", "old", "release", "released",
        // duration / time units and small number words (dropped as filler)
        "hour", "hours", "hr", "hrs", "minute", "minutes", "min", "mins", "long",
        "one", "two", "three", "four", "five", "half",
        // Swedish filler (folded)
        "nagot", "nagon", "nagra", "med", "och", "eller", "jag", "vill", "se", "titta", "kolla",
        "pa", "ett", "som", "for", "till", "av", "om", "det", "den", "de", "ar", "har",
        "kan", "du", "mig", "oss", "vi", "bra", "basta", "bast", "liknande", "typ", "tips",
        "ny", "nya", "nytt", "gammal", "gamla", "fran", "efter", "innan", "fore", "an",
        "timme", "timmar", "tim", "minut", "minuter", "lang", "kort", "kortare", "mindre",
        "ikvall", "kvall", "nu", "idag", "just", "visa", "hitta", "sok", "rekommendera",
        "tva", "tre", "fyra", "fem", "halv", "talet", "s",
    ]

    static func residualFreeText(_ originalQuery: String, consumed: Set<String>) -> String {
        let folded = originalQuery.foldedForSearch()
        let words = folded.split(separator: " ").map(String.init)
        let kept = words.filter { word in
            guard word.count > 1 else { return false }
            if stopWords.contains(word) { return false }
            if consumed.contains(word) { return false }
            if Int(word) != nil { return false }            // stray numbers
            return true
        }
        // "something like Game of Thrones" → keep "game of thrones"
        return kept.joined(separator: " ")
    }
}

// MARK: - Word matching helper

extension String {
    /// True if `self` (already lowercased/folded, space-padded) contains any of
    /// the phrases as whole words / phrases.
    func containsWord(anyOf phrases: [String]) -> Bool {
        for phrase in phrases {
            let needle = " " + phrase.foldedForSearch() + " "
            if self.contains(needle) { return true }
        }
        return false
    }
}
