import Foundation
import Observation

@MainActor
@Observable
public final class SearchViewModel {

    public var query = ""
    public private(set) var intent: SearchIntent = .empty
    public private(set) var results: [SearchResult] = []
    /// Guide programmes matching the query — "Rapport", "Allsvenskan".
    public private(set) var programmes: [ProgrammeHit] = []
    /// What's on now on each channel in `results`, for the channel cards.
    public private(set) var channelNow: [CatalogID: EPGEvent] = [:]
    public private(set) var isSearching = false
    public private(set) var hasSearched = false
    public private(set) var interpretedFrom = ""

    /// A few titles to show on the empty search screen — recent additions,
    /// best-rated first.
    public private(set) var trending: [SearchResult] = []
    private var trendingRevision = -1

    /// The last handful of queries the viewer actually ran, newest first.
    public private(set) var recentQueries: [String] = []
    private let recentKey = "search.recent.v1"
    private let recentLimit = 8
    private let defaults = UserDefaults.standard

    public struct Chip: Identifiable {
        public let id: String
        public let label: String
        let remove: (inout SearchIntent) -> Void
    }

    public var chips: [Chip] { Self.chips(for: intent) }

    // Grouped results, for the per-kind rows.
    public var channels: [Channel] {
        results.compactMap { r -> Channel? in if case .channel(let c) = r.item { return c } else { return nil } }
    }
    public var movies: [Movie] {
        results.compactMap { r -> Movie? in if case .movie(let m) = r.item { return m } else { return nil } }
    }
    public var series: [Series] {
        results.compactMap { r -> Series? in if case .series(let s) = r.item { return s } else { return nil } }
    }
    public var hasAnyResult: Bool { !results.isEmpty || !programmes.isEmpty }

    private let repository: any CatalogQuerying
    private let engine: SearchEngine
    private let ai: AIService
    private let localParser = DeterministicQueryParser()

    public init(repository: any CatalogQuerying, engine: SearchEngine, ai: AIService) {
        self.repository = repository
        self.engine = engine
        self.ai = ai
        if let saved = defaults.stringArray(forKey: recentKey) { recentQueries = saved }
    }

    /// As-you-type search. On-device parser only — nothing leaves the device
    /// per keystroke; the AI tier (if enabled) runs on submit.
    public func liveSearch(vocabulary: SearchVocabulary) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            intent = .empty
            results = []
            programmes = []
            channelNow = [:]
            hasSearched = false
            return
        }
        await run(localParser.parseSync(trimmed, vocabulary: vocabulary), text: trimmed)
    }

    /// Submit (Search on the keyboard): may consult the AI parser, and the
    /// query is remembered.
    public func search(vocabulary: SearchVocabulary) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let parsed = await ai.intent(for: trimmed, vocabulary: vocabulary)
        await run(parsed, text: trimmed)
        rememberRecent(trimmed)
    }

    public func runRecent(_ text: String, vocabulary: SearchVocabulary) async {
        query = text
        await search(vocabulary: vocabulary)
    }

    /// The viewer opened something from the results — that query worked, so
    /// keep it in Recent.
    public func noteResultOpened() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { rememberRecent(trimmed) }
    }

    private func run(_ parsed: SearchIntent, text: String) async {
        if results.isEmpty && programmes.isEmpty { isSearching = true }
        defer { isSearching = false }

        let found = await repository.search(parsed, limit: 150)
        guard !Task.isCancelled else { return }

        // Programme titles: the leftover free text, or — when the parser read
        // the whole query as filters ("fotboll" → sport) — the words as typed,
        // so "fotboll" still finds tonight's match. Long sentences are filters,
        // not programme names.
        let programmeQuery = parsed.freeText.isEmpty ? text : parsed.freeText
        let words = programmeQuery.split(separator: " ").count
        var progs: [ProgrammeHit] = []
        if words <= 4 {
            progs = await repository.searchProgrammes(text: programmeQuery, limit: 24)
        }
        guard !Task.isCancelled else { return }

        let channelHits = found.compactMap { r -> Channel? in
            if case .channel(let c) = r.item { return c } else { return nil }
        }
        var now: [CatalogID: EPGEvent] = [:]
        if !channelHits.isEmpty {
            let t = Date()
            let window = DateInterval(start: t.addingTimeInterval(-4 * 3600), end: t.addingTimeInterval(3600))
            let epg = await repository.epgIndex(forEPGIDs: channelHits.compactMap(\.epgID), in: window)
            for channel in channelHits {
                if let id = channel.epgID, let event = epg.nowPlaying(forChannel: id, at: t) {
                    now[channel.id] = event
                }
            }
        }
        guard !Task.isCancelled else { return }

        intent = parsed
        interpretedFrom = text
        results = found
        programmes = progs
        channelNow = now
        hasSearched = true
    }

    /// Populate `trending` from the newest additions, ranked by TMDB rating
    /// where one is known. A no-op until the catalog revision actually changes,
    /// so the staged-import revision storm doesn't re-query it repeatedly.
    public func loadTrending(ratings: [String: Double], revision: Int) async {
        guard revision != trendingRevision else { return }
        trendingRevision = revision
        let items = await repository.recentlyAdded(limit: 30).map { SearchResult(item: $0, score: 0) }
        trending = items
            .sorted { (ratings[$0.id.rawValue] ?? 0) > (ratings[$1.id.rawValue] ?? 0) }
            .prefix(18)
            .map { $0 }
    }

    public func clearRecents() {
        recentQueries = []
        defaults.removeObject(forKey: recentKey)
    }

    private func rememberRecent(_ text: String) {
        var next = recentQueries.filter { $0.caseInsensitiveCompare(text) != .orderedSame }
        next.insert(text, at: 0)
        recentQueries = Array(next.prefix(recentLimit))
        defaults.set(recentQueries, forKey: recentKey)
    }

    public func removeChip(_ chip: Chip) {
        var updated = intent
        chip.remove(&updated)
        let text = interpretedFrom
        Task { await run(updated, text: text) }
    }

    public func clear() {
        query = ""
        intent = .empty
        results = []
        programmes = []
        channelNow = [:]
        hasSearched = false
    }

    // MARK: - Chip mapping

    static func chips(for intent: SearchIntent) -> [Chip] {
        var chips: [Chip] = []

        for kind in intent.kinds {
            let label: String
            switch kind {
            case .movie: label = "Movies"
            case .series: label = "Series"
            case .liveChannel: label = "Live TV"
            }
            chips.append(Chip(id: "kind-\(kind.rawValue)", label: label) { intent in
                intent.kinds.removeAll { $0 == kind }
            })
        }
        for genre in intent.genres {
            chips.append(Chip(id: "genre-\(genre.rawValue)", label: genre.displayName) { intent in
                intent.genres.removeAll { $0 == genre }
            })
        }
        for lang in intent.audioLanguages {
            chips.append(Chip(id: "audio-\(lang.code)", label: "\(lang.displayName) audio") { intent in
                intent.audioLanguages.removeAll { $0 == lang }
            })
        }
        for lang in intent.subtitleLanguages {
            chips.append(Chip(id: "sub-\(lang.code)", label: "\(lang.displayName) subtitles") { intent in
                intent.subtitleLanguages.removeAll { $0 == lang }
            })
        }
        if let minYear = intent.minYear {
            chips.append(Chip(id: "minYear", label: "After \(minYear - 1)") { $0.minYear = nil })
        }
        if let maxYear = intent.maxYear {
            chips.append(Chip(id: "maxYear", label: "Before \(maxYear + 1)") { $0.maxYear = nil })
        }
        if let maxDur = intent.maxDurationMinutes {
            let label = maxDur >= 60 ? "Under \(maxDur / 60)h\(maxDur % 60 == 0 ? "" : " \(maxDur % 60)m")"
                                     : "Under \(maxDur)m"
            chips.append(Chip(id: "maxDur", label: label) { $0.maxDurationMinutes = nil })
        }
        if let q = intent.minQuality, q > .unknown {
            chips.append(Chip(id: "quality", label: "\(q.shortLabel)+") { $0.minQuality = nil })
        }
        return chips
    }
}
