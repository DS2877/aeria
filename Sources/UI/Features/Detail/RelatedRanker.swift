import Foundation

/// "More Like This", varied: scores a candidate pool against the title you're
/// looking at, then picks greedily with a penalty for repeating what's
/// already in the row — so it isn't eighteen of the newest dramas.
///
/// Signals: share of genres in common, how close in time, shared cast or
/// director, shared audio language, TMDB rating, having a poster. A little
/// jitter seeded by the title and the day keeps the row stable while you look
/// at it but different from one title to the next.
enum RelatedRanker {

    struct Item {
        let id: CatalogID
        let title: String
        let genres: [Genre]
        let year: Int?
        let people: Set<String>       // cast + directors, folded
        let audio: Set<Language>
        let hasPoster: Bool
    }

    static func item(_ m: Movie) -> Item {
        Item(id: m.id, title: m.title, genres: m.genres, year: m.year,
             people: Set((m.cast.prefix(6) + m.directors).map { $0.foldedForSearch() }.filter { !$0.isEmpty }),
             audio: Set(m.audioLanguages), hasPoster: m.posterURL != nil)
    }

    static func item(_ s: Series) -> Item {
        Item(id: s.id, title: s.title, genres: s.genres, year: s.year, people: [],
             audio: Set(s.audioLanguages), hasPoster: s.posterURL != nil)
    }

    static func rank(source: Item, candidates: [Item], ratings: [String: Double],
                     limit: Int, day: Date = Date()) -> [CatalogID] {
        let sourceGenres = Set(source.genres)
        let sourceTitle = source.title.foldedForSearch()
        let seed = stableHash(source.id.rawValue + dayKey(day))

        var seenTitles: Set<String> = [sourceTitle]
        var scored: [(Item, Double)] = []
        for c in candidates where c.id != source.id {
            let title = c.title.foldedForSearch()
            guard seenTitles.insert(title).inserted else { continue }   // other versions of one title
            var s = 0.0
            let genres = Set(c.genres)
            if !sourceGenres.isEmpty {
                s += 40 * Double(sourceGenres.intersection(genres).count) / Double(sourceGenres.count)
                if genres == sourceGenres { s += 4 }
            }
            if let a = source.year, let b = c.year { s += max(0, 12 - Double(abs(a - b))) }
            let sharedPeople = source.people.intersection(c.people).count
            s += Double(min(sharedPeople, 2)) * 18
            if !source.audio.isDisjoint(with: c.audio) { s += 5 }
            if let rating = ratings[c.id.rawValue] {
                s += rating >= 7 ? 10 : (rating < 5.5 ? -20 : 0)
            }
            s += c.hasPoster ? 5 : -25
            s += Double(stableHash(c.id.rawValue, seed: seed) % 1000) / 1000 * 10   // 0…10 jitter
            scored.append((c, s))
        }
        scored.sort { $0.1 > $1.1 }

        // Greedy with diversity: each pick makes its decade and exact genre
        // mix a little less attractive for the next slot.
        var picked: [CatalogID] = []
        var decadeUse: [Int: Int] = [:]
        var mixUse: [Set<Genre>: Int] = [:]
        var pool = Array(scored.prefix(max(limit * 4, 40)))
        while picked.count < limit, !pool.isEmpty {
            var bestIndex = 0
            var bestScore = -Double.infinity
            for (i, entry) in pool.enumerated() {
                let decade = (entry.0.year ?? 0) / 10
                let mix = Set(entry.0.genres)
                let adjusted = entry.1
                    - Double(decadeUse[decade, default: 0]) * 4
                    - Double(mixUse[mix, default: 0]) * 6
                if adjusted > bestScore { bestScore = adjusted; bestIndex = i }
            }
            let chosen = pool.remove(at: bestIndex).0
            picked.append(chosen.id)
            decadeUse[(chosen.year ?? 0) / 10, default: 0] += 1
            mixUse[Set(chosen.genres), default: 0] += 1
        }
        return picked
    }

    private static func dayKey(_ date: Date) -> String {
        String(Int(date.timeIntervalSince1970 / 86_400))
    }

    /// FNV-1a — stable across launches (Swift's `hashValue` isn't).
    static func stableHash(_ text: String, seed: UInt64 = 0xcbf29ce484222325) -> UInt64 {
        var hash = seed
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}
