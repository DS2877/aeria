import Foundation

/// Orchestrates the pure detectors to turn a `RawCatalog` into a domain
/// `Catalog`. Runs off the main actor; deterministic given the same input.
public struct Normalizer: Sendable {

    public init() {}

    public func normalize(_ raw: RawCatalog) -> Catalog {
        Catalog(
            channels: raw.channels.map { normalizeChannel($0, providerID: raw.providerID) },
            movies:   raw.vod.map { normalizeMovie($0, providerID: raw.providerID) },
            series:   normalizeSeries(raw.seriesEpisodes, providerID: raw.providerID)
                        + raw.seriesShells.map { normalizeShell($0, providerID: raw.providerID) },
            epg:      raw.epg.map(normalizeEPG)
        )
    }

    /// Same result as `normalize`, but the per-item work (the slow part — regex
    /// title/language/genre detection over tens of thousands of rows) runs
    /// across all cores. `progress` fires as each section completes.
    public func normalizeConcurrently(
        _ raw: RawCatalog,
        progress: @Sendable (ImportPhase) -> Void = { _ in }
    ) async -> Catalog {
        let pid = raw.providerID
        let normalizer = self

        async let channels = raw.channels.concurrentMap { normalizer.normalizeChannel($0, providerID: pid) }
        async let movies = raw.vod.concurrentMap { normalizer.normalizeMovie($0, providerID: pid) }
        async let shells = raw.seriesShells.concurrentMap { normalizer.normalizeShell($0, providerID: pid) }
        async let epg = raw.epg.concurrentMap { normalizer.normalizeEPG($0) }

        let c = await channels;  progress(.channels)
        let m = await movies;    progress(.movies)
        // Episode-name reconstruction (M3U) is inherently sequential grouping.
        let reconstructed = normalizeSeries(raw.seriesEpisodes, providerID: pid)
        let s = reconstructed + (await shells)
        progress(.series)
        let e = await epg;       progress(.guide)

        return Catalog(channels: c, movies: m, series: s, epg: e)
    }

    // MARK: - Staged normalization (one section at a time, off the main actor)

    public func normalizeChannels(_ raw: [RawChannel], providerID: String) async -> [Channel] {
        let n = self
        return await raw.concurrentMap { n.normalizeChannel($0, providerID: providerID) }
    }

    public func normalizeVOD(
        movies rawMovies: [RawVODItem],
        shells rawShells: [RawSeriesShell],
        episodes rawEpisodes: [RawSeriesEpisode],
        providerID: String
    ) async -> (movies: [Movie], series: [Series]) {
        let n = self
        async let movies = rawMovies.concurrentMap { n.normalizeMovie($0, providerID: providerID) }
        async let shells = rawShells.concurrentMap { n.normalizeShell($0, providerID: providerID) }
        let reconstructed = normalizeSeries(rawEpisodes, providerID: providerID)
        return (await movies, reconstructed + (await shells))
    }

    public func normalizeGuide(_ raw: [RawEPGEvent]) async -> [EPGEvent] {
        let n = self
        return await raw.concurrentMap { n.normalizeEPG($0) }
    }

    /// Normalize an on-demand batch of episodes for one already-known series.
    public func seasons(
        forEpisodes rawEpisodes: [RawSeriesEpisode],
        seriesID: CatalogID,
        providerID: String
    ) -> [Season] {
        let entries: [(season: Int, episode: Int, raw: RawSeriesEpisode)] = rawEpisodes.map { raw in
            if let s = raw.explicitSeason, let e = raw.explicitEpisode {
                return (s, e, raw)
            }
            if let parsed = EpisodeParser.parse(TitleNormalizer.episodeRawName(raw.name)) {
                return (parsed.season, parsed.episode, raw)
            }
            return (1, (rawEpisodes.firstIndex { $0.providerKey == raw.providerKey } ?? 0) + 1, raw)
        }
        return buildSeasons(from: entries, seriesID: seriesID, providerID: providerID, keyPrefix: seriesID.rawValue)
    }

    private func normalizeShell(_ shell: RawSeriesShell, providerID: String) -> Series {
        let seriesID = CatalogID(providerID: providerID, kind: .series, providerItemKey: "shell:\(shell.providerKey)")
        let (title, nameYear) = TitleNormalizer.movieTitle(shell.name)
        return Series(
            id: seriesID,
            title: title,
            year: shell.releaseDate.flatMap(TitleNormalizer.extractYear) ?? nameYear,
            genres: GenreDetector.detect(from: [shell.genreText, shell.groupTitle, shell.name]),
            audioLanguages: LanguageDetector.detect(name: shell.name, groupTitle: shell.groupTitle).audio,
            subtitleLanguages: LanguageDetector.detect(name: shell.name, groupTitle: shell.groupTitle).subtitles,
            quality: .unknown,
            countryCode: CategoryMapper.countryCode(from: shell.name, groupTitle: shell.groupTitle),
            posterURL: shell.cover.flatMap(URL.init(string:)),
            backdropURL: nil,
            synopsis: shell.plot?.nonEmpty,
            seasons: [],
            providerSeriesKey: shell.providerKey,
            addedAt: shell.addedAt,
            isAdult: AdultContentDetector.isAdult(name: shell.name, groupTitle: shell.groupTitle),
            collection: CategoryMapper.vodCollection(from: shell.groupTitle)
        )
    }

    // MARK: - Channels

    func normalizeChannel(_ raw: RawChannel, providerID: String) -> Channel {
        let name = TitleNormalizer.channelName(raw.displayName)
        let langs = LanguageDetector.detect(name: raw.displayName, groupTitle: raw.groupTitle)
        let quality = QualityDetector.detect(in: [raw.displayName, raw.groupTitle])

        return Channel(
            id: CatalogID(providerID: providerID, kind: .liveChannel, providerItemKey: raw.providerKey),
            name: name,
            category: CategoryMapper.channelCategory(from: raw.groupTitle),
            logoURL: raw.logo.flatMap(URL.init(string:)),
            countryCode: CategoryMapper.countryCode(from: raw.displayName, groupTitle: raw.groupTitle),
            audioLanguages: langs.audio,
            subtitleLanguages: langs.subtitles,
            quality: quality,
            streamURL: URL(string: raw.streamURL) ?? Self.placeholderURL,
            epgID: raw.tvgID?.isEmpty == false ? raw.tvgID : nil,
            sortIndex: raw.channelNumber ?? 0,
            isAdult: AdultContentDetector.isAdult(name: raw.displayName, groupTitle: raw.groupTitle)
        )
    }

    // MARK: - Movies

    func normalizeMovie(_ raw: RawVODItem, providerID: String) -> Movie {
        let (title, year) = TitleNormalizer.movieTitle(raw.name)
        let langs = LanguageDetector.detect(name: raw.name, groupTitle: raw.groupTitle)
        let genres = GenreDetector.detect(from: [raw.genreText, raw.groupTitle, raw.name])
        let quality = QualityDetector.detect(in: [raw.name, raw.groupTitle])

        return Movie(
            id: CatalogID(providerID: providerID, kind: .movie, providerItemKey: raw.providerKey),
            title: title,
            year: year ?? raw.releaseDate.flatMap(TitleNormalizer.extractYear),
            genres: genres,
            durationMinutes: raw.durationSecs.map { max(1, $0 / 60) },
            audioLanguages: langs.audio,
            subtitleLanguages: langs.subtitles,
            quality: quality,
            countryCode: CategoryMapper.countryCode(from: raw.name, groupTitle: raw.groupTitle),
            posterURL: raw.logo.flatMap(URL.init(string:)),
            backdropURL: nil,
            synopsis: raw.plot?.nonEmpty,
            cast: raw.cast?.splitList() ?? [],
            directors: raw.director?.splitList() ?? [],
            streamURL: URL(string: raw.streamURL) ?? Self.placeholderURL,
            addedAt: raw.addedAt,
            isAdult: AdultContentDetector.isAdult(name: raw.name, groupTitle: raw.groupTitle),
            collection: CategoryMapper.vodCollection(from: raw.groupTitle)
        )
    }

    // MARK: - Series

    func normalizeSeries(_ rawEpisodes: [RawSeriesEpisode], providerID: String) -> [Series] {
        var grouped: [String: [(season: Int, episode: Int, raw: RawSeriesEpisode)]] = [:]
        var displayTitle: [String: String] = [:]

        for raw in rawEpisodes {
            let seriesTitle: String
            let season: Int
            let episode: Int

            if let name = raw.explicitSeriesName, let s = raw.explicitSeason, let e = raw.explicitEpisode {
                seriesTitle = name.collapsingWhitespace()
                season = s
                episode = e
            } else if let parsed = EpisodeParser.parse(TitleNormalizer.episodeRawName(raw.name)) {
                seriesTitle = parsed.seriesTitle
                season = parsed.season
                episode = parsed.episode
            } else {
                // Unparseable — treat as a single-episode "series" so it isn't lost.
                seriesTitle = TitleNormalizer.movieTitle(raw.name).title
                season = 1
                episode = 1
            }

            let key = seriesTitle.foldedForSearch()
            grouped[key, default: []].append((season, episode, raw))
            if displayTitle[key] == nil { displayTitle[key] = seriesTitle }
        }

        return grouped.map { key, entries in
            let title = displayTitle[key] ?? key
            let seriesID = CatalogID(providerID: providerID, kind: .series, providerItemKey: key)
            let seasons = buildSeasons(from: entries, seriesID: seriesID, providerID: providerID, keyPrefix: key)

            let allNames = entries.map { $0.raw.name }
            let allGroups = entries.compactMap { $0.raw.groupTitle }
            let langs = LanguageDetector.detect(
                name: allNames.joined(separator: " "),
                groupTitle: allGroups.joined(separator: " ")
            )

            return Series(
                id: seriesID,
                title: title,
                year: allNames.compactMap(TitleNormalizer.extractYear).min(),
                genres: GenreDetector.detect(from: allGroups.map { $0 as String? } + [title as String?]),
                audioLanguages: langs.audio,
                subtitleLanguages: langs.subtitles,
                quality: QualityDetector.detect(in: allNames.map { $0 as String? }),
                countryCode: CategoryMapper.countryCode(from: allNames.first ?? title,
                                                        groupTitle: allGroups.first),
                posterURL: entries.first?.raw.logo.flatMap(URL.init(string:)),
                backdropURL: nil,
                synopsis: entries.compactMap { $0.raw.plot?.nonEmpty }.first,
                seasons: seasons,
                providerSeriesKey: nil,
                isAdult: entries.contains {
                    AdultContentDetector.isAdult(name: $0.raw.name, groupTitle: $0.raw.groupTitle)
                }
            )
        }
        .sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
    }

    private func buildSeasons(
        from entries: [(season: Int, episode: Int, raw: RawSeriesEpisode)],
        seriesID: CatalogID,
        providerID: String,
        keyPrefix: String
    ) -> [Season] {
        let bySeason = Dictionary(grouping: entries, by: { $0.season })
        return bySeason.keys.sorted().map { seasonNumber -> Season in
            let eps = bySeason[seasonNumber]!
                .sorted { $0.episode < $1.episode }
                .map { entry -> Episode in
                    Episode(
                        id: CatalogID(providerID: providerID, kind: .series,
                                      providerItemKey: "\(keyPrefix)-s\(entry.season)e\(entry.episode)"),
                        seriesID: seriesID,
                        seasonNumber: entry.season,
                        episodeNumber: entry.episode,
                        title: episodeTitle(entry.raw.name, season: entry.season, episode: entry.episode),
                        overview: entry.raw.plot?.nonEmpty,
                        durationMinutes: nil,
                        stillURL: entry.raw.logo.flatMap(URL.init(string:)),
                        streamURL: URL(string: entry.raw.streamURL) ?? Self.placeholderURL
                    )
                }
            return Season(seriesID: seriesID, number: seasonNumber, episodes: eps)
        }
    }

    private func episodeTitle(_ raw: String, season: Int, episode: Int) -> String {
        // Strip the leading "Series SxxExx" part if present, leaving any real
        // episode title behind.
        let cleaned = TitleNormalizer.episodeRawName(raw)
        let markerPattern = CompiledPattern(#"^.*?(?:s\d{1,2}[\s\-_.]*e\d{1,4}|\d{1,2}x\d{1,4}|season[\s\-_.]*\d{1,2}[\s\-_.]*episode[\s\-_.]*\d{1,4})[\s\-_.:]*"#)
        var remainder = markerPattern.removingMatches(in: cleaned).collapsingWhitespace()
        remainder = Self.trailingTagJunk.removingMatches(in: remainder).collapsingWhitespace()
        // Leftover language / quality codes ("SWE", "EN", "MULTI") aren't titles.
        let looksLikeCode = remainder.count <= 5
            && remainder == remainder.uppercased()
            && remainder.allSatisfy { $0.isLetter }
        return (remainder.isEmpty || looksLikeCode) ? "Episode \(episode)" : remainder
    }

    private static let trailingTagJunk = CompiledPattern(
        #"[\s\-–—]*\b(?:swe|sve|eng|en|se|sv|nor|dan|fin|ger|multi|multisub|dual|sub|subs|swesub|engsub|vo|vf|vostfr|1080p?|720p?|2160p?|hd|fhd|uhd|4k|web[\s\-]?dl|bluray)\b[\s\-–—]*$"#
    )

    // MARK: - EPG

    func normalizeEPG(_ raw: RawEPGEvent) -> EPGEvent {
        EPGEvent(
            channelEPGID: raw.channelID,
            title: raw.title.collapsingWhitespace(),
            subtitle: raw.subtitle?.nonEmpty,
            description: raw.description?.nonEmpty,
            start: raw.start,
            stop: raw.stop,
            category: raw.category?.nonEmpty
        )
    }

    static let placeholderURL = URL(string: "about:blank")!
}

// MARK: - Small helpers

private extension String {
    var nonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    func splitList() -> [String] {
        components(separatedBy: CharacterSet(charactersIn: ",;/"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
