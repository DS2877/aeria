import Foundation

/// A TV programme that matched a search, with the channel it's on — "Rapport,
/// SVT1, 19:30". Sendable value, built by the repository.
public struct ProgrammeHit: Identifiable, Sendable {
    public let event: EPGEvent
    public let channel: Channel

    public var id: String { "\(channel.id.rawValue)|\(event.id)" }

    public init(event: EPGEvent, channel: Channel) {
        self.event = event
        self.channel = channel
    }

    /// Search-hit order: on now first, then by start time.
    public static func ranked(_ hits: [ProgrammeHit], now: Date, limit: Int) -> [ProgrammeHit] {
        var seen = Set<String>()
        return hits
            .filter { seen.insert($0.id).inserted }
            .sorted { lhs, rhs in
                let l = lhs.event.isLive(at: now), r = rhs.event.isLive(at: now)
                if l != r { return l }
                return lhs.event.start < rhs.event.start
            }
            .prefix(limit)
            .map { $0 }
    }

    /// Whether `title` contains every word of `query` (folded, any order).
    public static func matches(_ title: String, query: String) -> Bool {
        let tokens = query.foldedForSearch().split(separator: " ")
        guard !tokens.isEmpty else { return false }
        let folded = title.foldedForSearch()
        return tokens.allSatisfy { folded.contains($0) }
    }
}
