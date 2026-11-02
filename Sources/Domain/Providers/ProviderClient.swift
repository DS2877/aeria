import Foundation

public enum ProviderKind: String, Codable, Sendable {
    case mock
    case m3u
    case xtream
}

/// Identifies a configured provider. `id` is stable and used to derive
/// `CatalogID`s and to scope persisted data.
public struct ProviderDescriptor: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let kind: ProviderKind
    public let displayName: String

    public init(id: String, kind: ProviderKind, displayName: String) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
    }
}

/// One slice of a staged catalog fetch. Emitting these in order
/// (`channels` → `vod` → `guide`) lets the app become interactive before the
/// whole library has finished downloading.
public enum RawStage: Sendable {
    case channels([RawChannel])
    case vod(movies: [RawVODItem], shells: [RawSeriesShell], episodes: [RawSeriesEpisode])
    case guide([RawEPGEvent])
    /// A first, partial guide (now/next for the main channels) sent before
    /// the full guide arrives. Merged in; it never prunes anything, so it
    /// belongs to no part.
    case guidePreview([RawEPGEvent])

    public var part: ImportParts {
        switch self {
        case .channels:     return .channels
        case .vod:          return .vod
        case .guide:        return .guide
        case .guidePreview: return []
        }
    }
}

/// Which parts of the catalogue an import refreshes. They change at very
/// different rates — channels sometimes, the guide daily, films and series
/// rarely — so background refreshes fetch only what's due.
public struct ImportParts: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let channels = ImportParts(rawValue: 1 << 0)
    public static let vod      = ImportParts(rawValue: 1 << 1)
    public static let guide    = ImportParts(rawValue: 1 << 2)
    public static let all: ImportParts = [.channels, .vod, .guide]

    /// Stable name, for per-part "last imported" stamps.
    public var key: String {
        switch self {
        case .channels: return "channels"
        case .vod:      return "vod"
        case .guide:    return "guide"
        default:        return "all"
        }
    }
}

/// The single seam every IPTV source implements. Everything above the
/// normalization layer depends only on this protocol, never on M3U/Xtream.
public protocol ProviderClient: Sendable {
    var descriptor: ProviderDescriptor { get }

    /// Fetch the provider's catalog in its own shape. Implementations must not
    /// block; heavy parsing belongs on a background executor.
    ///
    /// Series may come back as shells (no episodes) when episode listings are
    /// expensive — episodes are then loaded on demand via `fetchEpisodes`.
    func fetchRawCatalog(progress: ImportProgressReporter) async throws -> RawCatalog

    /// Fetch the catalog in stages, calling `emit` as each slice is ready.
    /// Default: run `fetchRawCatalog` and replay it in three stages. Providers
    /// override this to emit channels the moment they land, well before the
    /// (usually much larger) VOD list and EPG have downloaded.
    func fetchStaged(
        progress: ImportProgressReporter,
        emit: @Sendable (RawStage) async -> Void
    ) async throws

    /// Fetch only `parts` (a background refresh of what's due). A requirement,
    /// so a provider's override is used even through `any ProviderClient`.
    func fetchStaged(
        progress: ImportProgressReporter,
        parts: ImportParts,
        emit: @Sendable (RawStage) async -> Void
    ) async throws

    /// Resolve a playable URL for an item. For some providers this is a cheap
    /// passthrough; for others it hits the API. Called at playback time only.
    func resolveStreamURL(for providerItemKey: String, kind: ContentKind) async throws -> URL

    /// Load the episodes for one series on demand. `seriesKey` is the value the
    /// adapter put in `RawSeriesShell.providerKey`. Default: none.
    func fetchEpisodes(seriesKey: String) async throws -> [RawSeriesEpisode]

    /// The description, cast and backdrop for one title — big providers leave
    /// them out of the bulk lists. Default: none.
    func fetchDetails(_ request: DetailsRequest) async throws -> RawDetails?
}

/// Which title to fetch details for.
public enum DetailsRequest: Sendable {
    /// A film, by its stream URL (Xtream puts the VOD id in it).
    case movie(streamURL: URL)
    /// A series, by `Series.providerSeriesKey`.
    case series(key: String)
}

/// Per-title details from the provider.
public struct RawDetails: Sendable, Equatable {
    public var plot: String?
    public var cast: [String]
    public var directors: [String]
    public var backdropURL: URL?
    public var durationMinutes: Int?

    public init(plot: String?, cast: [String] = [], directors: [String] = [],
                backdropURL: URL? = nil, durationMinutes: Int? = nil) {
        self.plot = plot
        self.cast = cast
        self.directors = directors
        self.backdropURL = backdropURL
        self.durationMinutes = durationMinutes
    }
}

public extension ProviderClient {
    func fetchEpisodes(seriesKey: String) async throws -> [RawSeriesEpisode] { [] }
    func fetchDetails(_ request: DetailsRequest) async throws -> RawDetails? { nil }

    /// Convenience for callers that don't need progress.
    func fetchRawCatalog() async throws -> RawCatalog {
        try await fetchRawCatalog(progress: .ignore)
    }

    /// Only the given parts. Default: a full staged fetch with the unwanted
    /// stages dropped (correct, not cheaper) — providers that can skip whole
    /// requests (Xtream) override it.
    func fetchStaged(
        progress: ImportProgressReporter,
        parts: ImportParts,
        emit: @Sendable (RawStage) async -> Void
    ) async throws {
        try await fetchStaged(progress: progress) { stage in
            if parts.contains(stage.part) { await emit(stage) }
        }
    }

    func fetchStaged(
        progress: ImportProgressReporter,
        emit: @Sendable (RawStage) async -> Void
    ) async throws {
        let raw = try await fetchRawCatalog(progress: progress)
        await emit(.channels(raw.channels))
        await emit(.vod(movies: raw.vod, shells: raw.seriesShells, episodes: raw.seriesEpisodes))
        await emit(.guide(raw.epg))
    }
}
