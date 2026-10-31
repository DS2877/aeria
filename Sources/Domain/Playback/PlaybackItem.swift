import Foundation

/// Everything the player needs to start playback, decoupled from the catalog
/// models. Built by `AppEnvironment.makePlayback(for:)`.
public struct PlaybackItem: Identifiable, Hashable, Sendable {
    public let id: CatalogID
    public let kind: ContentKind

    /// Resolved, playable URL (HLS for the mock/live; direct for VOD).
    public let url: URL

    public let title: String
    /// e.g. "S02E01 · The Bear" or "2019 · Thriller".
    public let subtitle: String?

    public let isLive: Bool

    /// Seconds to seek to on start, if resuming. Ignored for live.
    public let resumeAt: Double?

    /// Total runtime in seconds when known — lets us persist progress without
    /// waiting for the player to report duration.
    public let durationSeconds: Double?

    /// Plot / episode summary for the player's Info panel.
    public let synopsis: String?
    /// Poster, still or logo for the player's Info panel.
    public let artworkURL: URL?

    public init(
        id: CatalogID,
        kind: ContentKind,
        url: URL,
        title: String,
        subtitle: String? = nil,
        isLive: Bool = false,
        resumeAt: Double? = nil,
        durationSeconds: Double? = nil,
        synopsis: String? = nil,
        artworkURL: URL? = nil
    ) {
        self.id = id
        self.kind = kind
        self.url = url
        self.title = title
        self.subtitle = subtitle
        self.isLive = isLive
        self.resumeAt = resumeAt
        self.durationSeconds = durationSeconds
        self.synopsis = synopsis
        self.artworkURL = artworkURL
    }
}
