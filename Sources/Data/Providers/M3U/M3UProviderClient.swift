import Foundation

/// `ProviderClient` for a plain M3U/M3U8 playlist URL, optionally paired with an
/// XMLTV EPG URL. The playlist URL frequently embeds credentials, so it is only
/// ever read from the Keychain and never logged in full.
public struct M3UProviderClient: ProviderClient {

    public let descriptor: ProviderDescriptor
    private let playlistURL: URL
    private let epgURL: URL?
    private let http: HTTPClient

    public init?(configuration: ProviderConfiguration, playlistURLString: String, epgURLString: String?, http: HTTPClient = .init()) {
        guard configuration.kind == .m3u,
              let playlistURL = URL(string: playlistURLString.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        self.descriptor = configuration.descriptor
        self.playlistURL = playlistURL
        self.epgURL = epgURLString.flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        self.http = http
    }

    public func fetchRawCatalog(progress: ImportProgressReporter) async throws -> RawCatalog {
        var out = RawCatalog(providerID: descriptor.id)
        try await fetchStaged(progress: progress) { stage in
            switch stage {
            case .channels(let c): out.channels = c
            case .vod(let m, let s, let e):
                out.vod = m; out.seriesShells = s; out.seriesEpisodes = e
            case .guide(let g): out.epg = g
            case .guidePreview: break
            }
        }
        return out
    }

    /// Staged: the playlist is one download, but the (often large) XMLTV EPG is
    /// a separate request — defer it so the app is usable while it loads.
    public func fetchStaged(
        progress: ImportProgressReporter,
        emit: @Sendable (RawStage) async -> Void
    ) async throws {
        progress.reached(.connecting)
        let data = try await http.data(from: playlistURL)
        let catalog = try M3UParser.parse(data, providerID: descriptor.id)
        guard !catalog.channels.isEmpty || !catalog.vod.isEmpty || !catalog.seriesEpisodes.isEmpty else {
            AppLog.provider.error("M3U import: playlist parsed but contained no entries.")
            throw ProviderError.emptyLibrary
        }
        progress.reached(.channels)
        await emit(.channels(catalog.channels))
        progress.reached(.movies)
        progress.reached(.series)
        await emit(.vod(movies: catalog.vod, shells: catalog.seriesShells,
                        episodes: catalog.seriesEpisodes))

        progress.reached(.guide)
        var epg: [RawEPGEvent] = []
        if let epgURL {
            // Stream the XMLTV off disk and window it while parsing so a big
            // feed never balloons memory.
            if let file = try? await http.downloadToFile(from: epgURL) {
                defer { try? FileManager.default.removeItem(at: file) }
                epg = (try? XMLTVParser.parse(fileURL: file, within: EPGWindow.current())) ?? []
            }
        }
        await emit(.guide(epg))
        AppLog.provider.info("M3U import: \(catalog.channels.count) channels, \(catalog.vod.count) movies, \(catalog.seriesEpisodes.count) episodes.")
    }

    public func resolveStreamURL(for providerItemKey: String, kind _: ContentKind) async throws -> URL {
        guard let url = URL(string: providerItemKey) else { throw ProviderError.streamUnavailable }
        return url
    }
}
