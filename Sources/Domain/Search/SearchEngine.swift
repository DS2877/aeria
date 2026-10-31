import Foundation

/// Runs a `SearchIntent` against a `Catalog` and returns ranked results.
///
/// In M1 the candidate-gathering step is replaced by an FTS5 query; the ranking
/// logic stays here.
public struct SearchEngine: Sendable {

    public init() {}

    public func search(_ intent: SearchIntent, in catalog: Catalog, limit: Int = 200) -> [SearchResult] {
        let filter = CatalogFilter(intent: intent)
        let wantMovies = intent.kinds.isEmpty || intent.kinds.contains(.movie)
        let wantSeries = intent.kinds.isEmpty || intent.kinds.contains(.series)
        // Channels when asked for, or for any plain text search with no kind
        // pinned — "SVT1" must find the channel.
        let wantChannels = intent.kinds.contains(.liveChannel)
            || (intent.kinds.isEmpty && !intent.freeText.isEmpty)

        var results: [SearchResult] = []

        if wantMovies {
            for movie in catalog.movies where filter.matches(movie: movie) {
                results.append(SearchResult(item: .movie(movie),
                                            score: score(title: movie.title, year: movie.year, intent: intent)))
            }
        }
        if wantSeries {
            for series in catalog.series where filter.matches(series: series) {
                results.append(SearchResult(item: .series(series),
                                            score: score(title: series.title, year: series.year, intent: intent)))
            }
        }
        if wantChannels {
            let tokens = intent.freeText.foldedForSearch().split(separator: " ")
            for channel in catalog.channels {
                let name = channel.name.foldedForSearch()
                guard tokens.allSatisfy({ name.contains($0) }) else { continue }
                results.append(SearchResult(item: .channel(channel),
                                            score: score(title: channel.name, year: nil, intent: intent)))
            }
        }

        results.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.title.localizedCompare(rhs.title) == .orderedAscending
        }

        let ordered = applySort(intent.sort, to: results)
        return Array(ordered.prefix(limit))
    }

    // MARK: - Scoring

    private func score(title: String, year: Int?, intent: SearchIntent) -> Double {
        var score = 1.0
        let needle = intent.freeText.foldedForSearch()
        if !needle.isEmpty {
            let folded = title.foldedForSearch()
            if folded == needle { score += 10 }
            else if folded.hasPrefix(needle) { score += 6 }
            else if folded.contains(needle) { score += 3 }
            else { score += title.similarity(to: intent.freeText) * 2 }
        }
        // Newer content gets a mild boost when the query didn't pin a year.
        if intent.minYear == nil, intent.maxYear == nil, let year {
            score += min(1.0, Double(max(0, year - 1990)) / 40.0)
        }
        return score
    }

    private func applySort(_ sort: SearchIntent.Sort, to results: [SearchResult]) -> [SearchResult] {
        switch sort {
        case .relevance:
            return results
        case .titleAscending:
            return results.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        case .newest:
            return results.sorted { yearOf($0) > yearOf($1) }
        case .durationAscending:
            return results.sorted { durationOf($0) < durationOf($1) }
        }
    }

    private func yearOf(_ r: SearchResult) -> Int {
        switch r.item {
        case .movie(let m):  return m.year ?? 0
        case .series(let s): return s.year ?? 0
        case .channel:       return 0
        }
    }

    private func durationOf(_ r: SearchResult) -> Int {
        switch r.item {
        case .movie(let m):  return m.durationMinutes ?? .max
        default:             return .max
        }
    }
}
