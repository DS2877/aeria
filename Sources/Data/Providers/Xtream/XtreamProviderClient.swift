import Foundation

/// `ProviderClient` for an Xtream Codes account. Fetches live + VOD + series
/// shells in the bulk pass; series episodes load on demand.
public struct XtreamProviderClient: ProviderClient {

    public let descriptor: ProviderDescriptor
    private let api: XtreamAPI
    private let http: HTTPClient

    public init?(configuration: ProviderConfiguration, password: String, http: HTTPClient = .init()) {
        guard configuration.kind == .xtream,
              let host = configuration.xtreamHost,
              let username = configuration.xtreamUsername,
              let api = XtreamAPI(host: host, username: username, password: password)
        else { return nil }
        self.descriptor = configuration.descriptor
        self.api = api
        self.http = http
    }

    // MARK: - Bulk catalog

    public func fetchRawCatalog(progress: ImportProgressReporter) async throws -> RawCatalog {
        var channels: [RawChannel] = []
        var movies: [RawVODItem] = []
        var shells: [RawSeriesShell] = []
        var epg: [RawEPGEvent] = []
        try await fetchStaged(progress: progress) { stage in
            switch stage {
            case .channels(let c): channels = c
            case .vod(let m, let s, _): movies = m; shells = s
            case .guide(let e): epg = e
            case .guidePreview: break
            }
        }
        return RawCatalog(providerID: descriptor.id, channels: channels, vod: movies,
                          seriesEpisodes: [], seriesShells: shells, epg: epg)
    }

    /// Staged: emit channels as soon as the live list lands (small, fast), then
    /// VOD + series, then the EPG (often the largest single request).
    ///
    /// The lists are fetched **sequentially**, and each provider DTO array is
    /// decoded inside its own helper so it is released before the next (often
    /// much larger) list is fetched — a real provider's VOD JSON alone is
    /// ~100 MB decoded, and holding all three at once jetsams the app on device.
    /// The `do { }` blocks force the mapped arrays to be released too (a Debug
    /// build keeps `let`s alive to end-of-scope).
    public func fetchStaged(
        progress: ImportProgressReporter,
        emit: @Sendable (RawStage) async -> Void
    ) async throws {
        try await fetchStaged(progress: progress, parts: .all, emit: emit)
    }

    /// Only the requested parts — the lists that aren't due aren't requested
    /// at all (the point of a staggered refresh).
    public func fetchStaged(
        progress: ImportProgressReporter,
        parts: ImportParts,
        emit: @Sendable (RawStage) async -> Void
    ) async throws {
        progress.reached(.connecting)
        try await verifyAuth()

        var channelCount = 0, movieCount = 0, shellCount = 0
        /// Guide ids of the kept channels — the XMLTV parse keeps only these.
        var guideChannels: Set<String>?

        if parts.contains(.channels) {
            let channels = try await fetchLiveChannels()
            channelCount = channels.count
            progress.reached(.channels)
            let kept = channels.filter { !RelevanceFilter.isForeignSection($0.groupTitle) }
            guideChannels = Set(kept.compactMap(\.tvgID).filter { !$0.isEmpty })
            await emit(.channels(channels))

            // Two-tier guide: now/next for the main channels right away (a
            // few dozen tiny requests), so "on now" shows within seconds —
            // the full XMLTV is the biggest download and comes last.
            if parts.contains(.guide) {
                let preview = await shortEPG(for: kept)
                if !preview.isEmpty { await emit(.guidePreview(preview)) }
            }
        }

        if parts.contains(.vod) {
            progress.reached(.movies)
            let movies = try await fetchMovies()
            progress.reached(.series)
            let shells = (try? await fetchSeriesShells()) ?? []   // don't sink the import
            // Only a full import can tell "the subscription is empty".
            if parts == .all, channelCount == 0, movies.isEmpty, shells.isEmpty {
                AppLog.provider.error("Xtream import: authenticated but every list came back empty.")
                throw ProviderError.emptyLibrary
            }
            movieCount = movies.count
            shellCount = shells.count
            await emit(.vod(movies: movies, shells: shells, episodes: []))
        }

        if parts.contains(.guide) {
            progress.reached(.guide)
            let epg = (try? await fetchEPG(channels: guideChannels)) ?? []
            await emit(.guide(epg))
        }

        AppLog.provider.info("Xtream import: \(channelCount) channels, \(movieCount) movies, \(shellCount) series.")
    }

    // MARK: - Per-list fetch + map (DTO array released on return)

    private func fetchLiveChannels() async throws -> [RawChannel] {
        let (live, cats) = try await fetchMarketScoped(XtreamDTO.LiveStream.self,
                                                       list: .liveStreams, categories: .liveCategories)
        return live.enumerated().compactMap { index, s in
            guard let id = s.stream_id, let name = s.name else { return nil }
            return RawChannel(
                providerKey: String(id),
                displayName: name,
                groupTitle: cats[s.category_id ?? ""],
                logo: s.stream_icon,
                tvgID: s.epg_channel_id,
                streamURL: api.liveStreamURL(id: id).absoluteString,
                channelNumber: s.num ?? (index + 1)
            )
        }
    }

    private func fetchMovies() async throws -> [RawVODItem] {
        let (vod, cats) = try await fetchMarketScoped(XtreamDTO.VODStream.self,
                                                      list: .vodStreams, categories: .vodCategories)
        return vod.compactMap { v in
            guard let id = v.stream_id, let name = v.name else { return nil }
            return RawVODItem(
                providerKey: String(id),
                name: name,
                groupTitle: cats[v.category_id ?? ""],
                logo: v.stream_icon,
                streamURL: api.vodStreamURL(id: id, extension: v.container_extension ?? "mp4").absoluteString,
                plot: v.plot,
                genreText: v.genre,
                releaseDate: v.releaseDate ?? v.added,
                durationSecs: v.episode_run_time.map { $0 * 60 },
                cast: v.cast,
                director: v.director,
                addedAt: Self.unixDate(v.added)
            )
        }
    }

    private func fetchSeriesShells() async throws -> [RawSeriesShell] {
        let (series, cats) = try await fetchMarketScoped(XtreamDTO.SeriesListItem.self,
                                                         list: .series, categories: .seriesCategories)
        return series.compactMap { s in
            guard let id = s.series_id, let name = s.name else { return nil }
            return RawSeriesShell(
                providerKey: String(id),
                name: name,
                cover: s.cover,
                plot: s.plot,
                genreText: s.genre,
                cast: s.cast,
                director: s.director,
                releaseDate: s.releaseDate,
                groupTitle: cats[s.category_id ?? ""],
                addedAt: Self.unixDate(s.last_modified)
            )
        }
    }

    // MARK: - On demand

    public func fetchEpisodes(seriesKey: String) async throws -> [RawSeriesEpisode] {
        let info = try await http.decode(XtreamDTO.SeriesInfo.self, from: api.seriesInfoURL(seriesID: seriesKey))
        guard let episodesBySeason = info.episodes else { return [] }

        var result: [RawSeriesEpisode] = []
        for (seasonKey, episodes) in episodesBySeason {
            let seasonNumber = Int(seasonKey) ?? 1
            for ep in episodes {
                guard let epID = ep.id else { continue }
                result.append(RawSeriesEpisode(
                    providerKey: epID,
                    name: ep.title ?? "Episode \(ep.episode_num ?? 0)",
                    groupTitle: nil,
                    logo: ep.info?.movie_image,
                    streamURL: api.seriesStreamURL(episodeID: epID,
                                                   extension: ep.container_extension ?? "mp4").absoluteString,
                    plot: ep.info?.plot,
                    explicitSeriesName: nil,
                    explicitSeason: seasonNumber,
                    explicitEpisode: ep.episode_num ?? (result.count + 1)
                ))
            }
        }
        return result
    }

    public func fetchDetails(_ request: DetailsRequest) async throws -> RawDetails? {
        let details: XtreamDTO.Details?
        switch request {
        case .movie(let streamURL):
            // …/movie/<user>/<pass>/<vod_id>.<ext>
            let vodID = streamURL.deletingPathExtension().lastPathComponent
            guard !vodID.isEmpty, vodID.allSatisfy(\.isNumber) else { return nil }
            details = try await http.decode(XtreamDTO.VODInfo.self, from: api.vodInfoURL(vodID: vodID)).info?.value
        case .series(let key):
            details = try await http.decode(XtreamDTO.SeriesInfo.self, from: api.seriesInfoURL(seriesID: key)).info?.value
        }
        guard let details else { return nil }
        return Self.rawDetails(details)
    }

    static func rawDetails(_ d: XtreamDTO.Details) -> RawDetails {
        func names(_ text: String?) -> [String] {
            (text ?? "").split(whereSeparator: { $0 == "," || $0 == "/" })
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let plot = (d.plot ?? d.description)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return RawDetails(
            plot: (plot?.isEmpty ?? true) ? nil : plot,
            cast: Array(names(d.cast ?? d.actors).prefix(12)),
            directors: Array(names(d.director).prefix(3)),
            backdropURL: d.backdrop_path?.values.first.flatMap(URL.init(string:)),
            durationMinutes: d.duration_secs.map { $0 / 60 }
        )
    }

    public func resolveStreamURL(for _: String, kind _: ContentKind) async throws -> URL {
        // Xtream stream URLs are deterministic; the catalog already carries them.
        throw ProviderError.streamUnavailable
    }

    // MARK: - Helpers

    /// Xtream `added` / `last_modified` are unix-second strings.
    static func unixDate(_ string: String?) -> Date? {
        guard let string, let seconds = TimeInterval(string.trimmingCharacters(in: .whitespaces)), seconds > 0
        else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private func verifyAuth() async throws {
        let auth = try await http.decode(XtreamDTO.AuthResponse.self, from: api.authURL)
        guard let info = auth.user_info else { throw ProviderError.authenticationFailed }
        if let status = info.status?.lowercased(), status.contains("expired") || status.contains("banned") || status.contains("disabled") {
            throw ProviderError.authenticationFailed
        }
        if info.auth == "0" { throw ProviderError.authenticationFailed }
    }

    private func fetch<T: Decodable>(_ type: T.Type, _ action: XtreamAPI.Action) async throws -> T {
        try await http.decode(T.self, from: api.url(action))
    }

    // MARK: - Category-first (Swedish market)

    /// A stream list, downloading only the Swedish-market categories when that
    /// saves real work.
    ///
    /// A big provider's lists are mostly foreign-market sections (Arabic,
    /// Turkish, Indian…) that the import throws away anyway. Fetching the small
    /// category list first and then only the kept categories (`&category_id=`)
    /// cuts the download, decode time and memory roughly by that share.
    ///
    /// Falls back to the single bulk request whenever per-category fetching
    /// can't be trusted or wouldn't pay: no categories, nothing foreign to
    /// skip, a very long kept list, any request failing — or the panel
    /// ignoring `category_id` (it would hand back the whole list per call).
    private func fetchMarketScoped<T: Decodable & Sendable & XtreamCategorized>(
        _ type: T.Type, list: XtreamAPI.Action, categories categoriesAction: XtreamAPI.Action
    ) async throws -> (items: [T], categories: [String: String]) {
        let cats = await categories(categoriesAction)
        let kept = cats.filter { !RelevanceFilter.isForeignSection($0.value) }.map(\.key).sorted()
        let dropped = cats.count - kept.count

        let worthIt = !cats.isEmpty && !kept.isEmpty
            && Double(dropped) >= Double(cats.count) * 0.2
            && kept.count <= Self.maxScopedCategories
        if worthIt, let scoped = await fetchByCategory(T.self, list: list, categoryIDs: kept) {
            AppLog.provider.info("Xtream \(list.rawValue, privacy: .public): \(kept.count) of \(cats.count) categories, \(scoped.count) items.")
            return (scoped, cats)
        }
        let bulk = try await fetch([T].self, list)
        return (bulk, cats)
    }

    /// Above this many kept categories, one bulk request beats hundreds of
    /// small ones.
    private static let maxScopedCategories = 160

    /// `nil` = don't trust it; use the bulk endpoint instead.
    private func fetchByCategory<T: Decodable & Sendable & XtreamCategorized>(
        _ type: T.Type, list: XtreamAPI.Action, categoryIDs: [String]
    ) async -> [T]? {
        guard let first = categoryIDs.first else { return nil }
        // Probe one category: a panel that ignores `category_id` returns other
        // categories' items too — then every call would be the full list.
        guard let probe = try? await http.decode([T].self, from: api.url(list, categoryID: first)) else {
            return nil
        }
        if probe.contains(where: { $0.category_id != nil && $0.category_id != first }) { return nil }

        var all = probe
        var remaining = categoryIDs.dropFirst()[...]
        // A few at a time — panels throttle bursts, and each response is small.
        while !remaining.isEmpty {
            let batch = Array(remaining.prefix(4))
            remaining = remaining.dropFirst(batch.count)
            let results: [[T]]? = await withTaskGroup(of: [T]?.self) { group in
                for id in batch {
                    group.addTask { [http = self.http, api = self.api] in
                        try? await http.decode([T].self, from: api.url(list, categoryID: id))
                    }
                }
                var collected: [[T]] = []
                for await result in group {
                    guard let items = result else { return nil }
                    collected.append(items)
                }
                return collected
            }
            guard let results else { return nil }      // any failure → bulk
            for items in results { all += items }
        }
        return all
    }

    private func categories(_ action: XtreamAPI.Action) async -> [String: String] {
        guard let list = try? await fetch([XtreamDTO.Category].self, action) else { return [:] }
        return Dictionary(list.compactMap { cat -> (String, String)? in
            guard let id = cat.category_id, let name = cat.category_name else { return nil }
            return (id, name)
        }, uniquingKeysWith: { a, _ in a })
    }

    private func fetchEPG(channels: Set<String>?) async throws -> [RawEPGEvent] {
        // Stream the (often huge) XMLTV off disk and keep only the guide window
        // and the kept channels, so import memory never scales with the size
        // of the feed.
        let file = try await http.downloadToFile(from: api.xmltvURL)
        defer { try? FileManager.default.removeItem(at: file) }
        let filter = (channels?.isEmpty ?? true) ? nil : channels
        return try XMLTVParser.parse(fileURL: file, within: EPGWindow.current(), channels: filter)
    }

    // MARK: - Short EPG (now/next preview)

    /// How many channels get a now/next preview, and how many requests run at once.
    static let previewChannelLimit = 60
    private static let previewConcurrency = 8
    /// The preview is a nicety — never hold the import up longer than this.
    private static let previewDeadline: Duration = .seconds(8)

    /// Now/next for the channels a Swedish viewer is most likely to look at
    /// first: Swedish sections first, then by channel number.
    func shortEPG(for channels: [RawChannel]) async -> [RawEPGEvent] {
        let picks = Self.previewChannels(channels)
        guard !picks.isEmpty else { return [] }
        let http = self.http, api = self.api
        return await withTaskGroup(of: [RawEPGEvent]?.self) { group in
            group.addTask {
                try? await Task.sleep(for: Self.previewDeadline)
                return nil                                   // deadline marker
            }
            group.addTask {
                await withTaskGroup(of: [RawEPGEvent].self) { inner in
                    var it = picks.makeIterator()
                    var running = 0
                    while running < Self.previewConcurrency, let next = it.next() {
                        inner.addTask { await Self.shortEPG(next, http: http, api: api) }
                        running += 1
                    }
                    var all: [RawEPGEvent] = []
                    for await events in inner {
                        all += events
                        if let next = it.next() {
                            inner.addTask { await Self.shortEPG(next, http: http, api: api) }
                        }
                    }
                    return all
                }
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? []
        }
    }

    static func previewChannels(_ channels: [RawChannel]) -> [(streamID: Int, tvgID: String)] {
        func isSwedish(_ group: String?) -> Bool {
            guard let g = group?.uppercased() else { return false }
            let prefixes = ["SE|", "SE:", "SE ", "SE-", "SE_", "[SE]", "|SE|", "SE▎", "SE ▎"]
            return prefixes.contains { g.hasPrefix($0) } || g.contains("SWEDEN") || g.contains("SVERIGE") || g.contains("SVENSK")
        }
        return channels
            .compactMap { c -> (Bool, Int, Int, String)? in
                guard let id = Int(c.providerKey), let tvg = c.tvgID, !tvg.isEmpty else { return nil }
                return (isSwedish(c.groupTitle), c.channelNumber ?? Int.max, id, tvg)
            }
            .sorted { a, b in a.0 != b.0 ? a.0 : a.1 < b.1 }
            .prefix(previewChannelLimit)
            .map { (streamID: $0.2, tvgID: $0.3) }
    }

    private static func shortEPG(_ channel: (streamID: Int, tvgID: String),
                                 http: HTTPClient, api: XtreamAPI) async -> [RawEPGEvent] {
        guard let response = try? await http.decode(XtreamDTO.ShortEPG.self,
                                                    from: api.shortEPGURL(streamID: channel.streamID, limit: 4))
        else { return [] }
        return (response.epg_listings ?? []).compactMap { item in
            guard let start = item.start_timestamp, let stop = item.stop_timestamp, stop > start,
                  let title = item.title.map(decodeBase64), !title.isEmpty else { return nil }
            return RawEPGEvent(channelID: channel.tvgID,
                               title: title,
                               description: item.description.map(decodeBase64).flatMap { $0.isEmpty ? nil : $0 },
                               start: Date(timeIntervalSince1970: TimeInterval(start)),
                               stop: Date(timeIntervalSince1970: TimeInterval(stop)))
        }
    }

    /// Panels send base64; a few send plain text.
    static func decodeBase64(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = Data(base64Encoded: trimmed), let text = String(data: data, encoding: .utf8) {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }
}
