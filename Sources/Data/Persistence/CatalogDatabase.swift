import Foundation

/// The catalog store. Two SQLite connections to the same file: a **writer**
/// (serial `writerQueue`) that the import owns, and a **reader** (serial
/// `readerQueue`, `PRAGMA query_only`) that every screen queries through. WAL
/// mode lets the reader serve a consistent snapshot while the import commits, so
/// browsing stays responsive mid-import.
///
/// `@unchecked Sendable`: each connection is touched only from its own serial
/// queue, and the class holds no other mutable state.
public final class CatalogDatabase: @unchecked Sendable {

    private let writer: SQLiteConnection
    private let reader: SQLiteConnection
    private let writerQueue = DispatchQueue(label: "se.aeriaplus.catalog.write")
    private let readerQueue = DispatchQueue(label: "se.aeriaplus.catalog.read")
    /// True for the in-memory fallback store, where reader and writer are the
    /// same connection — reads must then run on the writer's queue or the two
    /// would touch one connection from two threads.
    private let sharesConnection: Bool

    /// Adult / region visibility applied to a query as `WHERE` clauses.
    public struct Scope: Sendable, Equatable {
        public var showAdult: Bool
        public var allRegions: Bool
        /// ISO country codes a *channel* may carry to be visible (channels with
        /// no country are always kept). `nil` = no channel-country filter.
        /// Ignored for movie / series queries.
        public var channelCountries: Set<String>?
        public init(showAdult: Bool = true, allRegions: Bool = true,
                    channelCountries: Set<String>? = nil) {
            self.showAdult = showAdult
            self.allRegions = allRegions
            self.channelCountries = channelCountries
        }
        public static let unfiltered = Scope(showAdult: true, allRegions: true)
    }

    // MARK: - Lifecycle

    public init(path: URL) throws {
        // `:memory:` is a private database per connection, so the reader has to
        // share the writer's rather than open a second, empty one.
        let isMemory = path.path == ":memory:"
        sharesConnection = isMemory
        writer = try SQLiteConnection(path: path.path, role: .writer)
        try CatalogSchema.migrate(writer)
        reader = isMemory ? writer : try SQLiteConnection(path: path.path, role: .reader)
    }

    /// Open (creating if needed) the catalog store in Application Support,
    /// falling back to a temporary location if that fails so the app still runs.
    public static func open() -> CatalogDatabase {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let base = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
            let directory = base.appendingPathComponent("AeriaCatalog", isDirectory: true)
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            candidates.append(directory.appendingPathComponent("catalog.sqlite3"))
        }
        candidates.append(fm.temporaryDirectory.appendingPathComponent("aeria-catalog.sqlite3"))

        for url in candidates {
            if let database = try? CatalogDatabase(path: url) { return database }
            // A corrupt file (or a half-written WAL) — drop it and try once more.
            for suffix in ["", "-wal", "-shm"] {
                try? fm.removeItem(at: URL(fileURLWithPath: url.path + suffix))
            }
            if let database = try? CatalogDatabase(path: url) { return database }
        }
        if let scratch = try? CatalogDatabase(path: fm.temporaryDirectory
            .appendingPathComponent("aeria-catalog-\(UUID().uuidString).sqlite3")) {
            return scratch
        }
        // Every path on disk failed. An in-memory store can't persist between
        // launches, but the app runs and re-imports — far better than refusing
        // to start.
        AppLog.app.error("No writable catalog store; falling back to memory.")
        return try! CatalogDatabase(path: URL(fileURLWithPath: ":memory:"))
    }

    // MARK: - Queue plumbing

    private func read<T: Sendable>(_ body: @escaping @Sendable (SQLiteConnection) throws -> T) async throws -> T {
        let queue = sharesConnection ? writerQueue : readerQueue
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try body(self.reader)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func write<T: Sendable>(_ body: @escaping @Sendable (SQLiteConnection) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            writerQueue.async {
                do { continuation.resume(returning: try body(self.writer)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    // MARK: - Meta

    public enum MetaKey {
        public static let providerID = "provider_id"
        public static let importComplete = "import_complete"
        public static let importedAt = "imported_at"
        public static let importGeneration = "import_gen"
        public static let channelCount = "channel_count"
        public static let movieCount = "movie_count"
        public static let seriesCount = "series_count"
        public static let epgCount = "epg_count"
        /// `RelevanceFilter.rulesVersion` the stored library was filtered with.
        public static let relevanceRules = "relevance_rules"
        // Facet cache — recomputed at the end of every import.
        public static let facetGenres = "facet_genres"
        public static let facetAudioLanguages = "facet_audio_langs"
        public static let facetSubLanguages = "facet_sub_langs"
        public static let facetChannelCategories = "facet_channel_cats"

        /// Home genre-shelf tallies, one per VOD scope (adult × region) — the
        /// only two scope flags that touch movies / series. Lines of
        /// "genre<TAB>count", most prevalent first.
        public static func genreTally(_ scope: Scope) -> String {
            "genre_tally.\(scope.showAdult ? 1 : 0)\(scope.allRegions ? 1 : 0)"
        }

        /// Every genre-tally key, for invalidation.
        public static var genreTallyKeys: [String] {
            [true, false].flatMap { adult in
                [true, false].map { regions in genreTally(Scope(showAdult: adult, allRegions: regions)) }
            }
        }
    }

    public func metaValue(_ key: String) async throws -> String? {
        try await read { conn in
            try conn.queryOne("SELECT value FROM meta WHERE key = ?", [.text(key)]) { $0.stringOrNil(0) } ?? nil
        }
    }

    public func setMeta(_ key: String, _ value: String?) async throws {
        try await write { conn -> Void in
            _ = try conn.run(
                "INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                [.text(key), SQLiteValue(value)]
            )
        }
    }

    private func rawMeta(_ key: String) async -> String? {
        guard let outer = try? await metaValue(key) else { return nil }
        return outer
    }

    public func intMeta(_ key: String) async -> Int {
        guard let text = await rawMeta(key), let value = Int(text) else { return 0 }
        return value
    }

    /// A completed import exists for this provider.
    public func isReady(providerID: String) async -> Bool {
        let loaded = await rawMeta(MetaKey.providerID)
        let complete = await intMeta(MetaKey.importComplete)
        return loaded == providerID && complete == 1
    }

    /// A completed import exists for whichever provider was last imported.
    public func importIsComplete() async -> Bool {
        let complete = await intMeta(MetaKey.importComplete)
        let loaded = await rawMeta(MetaKey.providerID)
        return complete == 1 && loaded != nil
    }

    public func loadedProviderID() async -> String? {
        await rawMeta(MetaKey.providerID)
    }

    /// When the current catalog finished importing, if ever.
    public func importedAt() async -> Date? {
        guard let text = await rawMeta(MetaKey.importedAt), let seconds = Double(text) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// When one part was last refreshed; falls back to the whole-import stamp
    /// for libraries imported before per-part stamps existed.
    public func importedAt(_ part: ImportParts) async -> Date? {
        if let text = await rawMeta(MetaKey.importedAt + "." + part.key), let seconds = Double(text) {
            return Date(timeIntervalSince1970: seconds)
        }
        return await importedAt()
    }

    /// Guide ids of the stored channels — a guide-only refresh keeps just
    /// these channels' programmes.
    public func channelEPGIDs() async throws -> Set<String> {
        try await read { conn in
            Set(try conn.query("SELECT DISTINCT epg_id FROM channel WHERE epg_id IS NOT NULL AND epg_id <> ''") {
                $0.string(0)
            })
        }
    }

    /// The generation number the next import should stamp its rows with.
    public func nextGeneration() async -> Int {
        (await intMeta(MetaKey.importGeneration)) + 1
    }

    // MARK: - Column lists (SELECT order must match the decoders below)

    private static let movieColumns = """
    id, title, year, duration_min, audio_langs, sub_langs, genres, quality, \
    country_code, poster_url, backdrop_url, synopsis, cast_list, directors, stream_url, added_at, is_adult
    """

    /// Same shape as `movieColumns` — so `decodeMovie` is unchanged — but the
    /// three fat, card-irrelevant columns come back empty. Cast lists and plots
    /// are the bulk of a movie row; a shelf card shows none of them, and the
    /// detail screen re-fetches the full row by id anyway. Used by every Home /
    /// shelf query, which is where the launch cost lives.
    private static let movieCardColumns = """
    id, title, year, duration_min, audio_langs, sub_langs, genres, quality, \
    country_code, poster_url, backdrop_url, synopsis, '' AS cast_list, '' AS directors, \
    '' AS stream_url, added_at, is_adult
    """

    private static let seriesColumns = """
    id, title, year, audio_langs, sub_langs, genres, quality, country_code, \
    poster_url, backdrop_url, synopsis, provider_key, added_at, is_adult
    """

    private static let channelColumns = """
    id, name, category, logo_url, country_code, audio_langs, sub_langs, quality, \
    stream_url, epg_id, sort_index, is_adult
    """

    private static let episodeColumns = """
    id, series_id, season, episode, title, overview, duration_min, still_url, stream_url
    """

    private static let epgColumns = "channel_epg_id, title, subtitle, description, start_at, stop_at, category"

    // MARK: - Row decoders

    private static func decodeMovie(_ row: SQLiteRow) -> Movie {
        Movie(
            id: CatalogID(rawValue: row.string(0)),
            title: row.string(1),
            year: row.intOrNil(2),
            genres: CatalogValues.decodeGenres(row.string(6)),
            durationMinutes: row.intOrNil(3),
            audioLanguages: CatalogValues.decodeLanguages(row.string(4)),
            subtitleLanguages: CatalogValues.decodeLanguages(row.string(5)),
            quality: CatalogValues.decodeQuality(row.string(7)),
            countryCode: row.stringOrNil(8),
            posterURL: row.url(9),
            backdropURL: row.url(10),
            synopsis: row.stringOrNil(11),
            cast: CatalogValues.decodeList(row.string(12)),
            directors: CatalogValues.decodeList(row.string(13)),
            streamURL: row.url(14) ?? Normalizer.placeholderURL,
            addedAt: row.date(15),
            isAdult: row.bool(16)
        )
    }

    private static func decodeSeries(_ row: SQLiteRow, seasons: [Season]) -> Series {
        Series(
            id: CatalogID(rawValue: row.string(0)),
            title: row.string(1),
            year: row.intOrNil(2),
            genres: CatalogValues.decodeGenres(row.string(5)),
            audioLanguages: CatalogValues.decodeLanguages(row.string(3)),
            subtitleLanguages: CatalogValues.decodeLanguages(row.string(4)),
            quality: CatalogValues.decodeQuality(row.string(6)),
            countryCode: row.stringOrNil(7),
            posterURL: row.url(8),
            backdropURL: row.url(9),
            synopsis: row.stringOrNil(10),
            seasons: seasons,
            providerSeriesKey: row.stringOrNil(11),
            addedAt: row.date(12),
            isAdult: row.bool(13)
        )
    }

    private static func decodeChannel(_ row: SQLiteRow) -> Channel {
        Channel(
            id: CatalogID(rawValue: row.string(0)),
            name: row.string(1),
            category: row.string(2),
            logoURL: row.url(3),
            countryCode: row.stringOrNil(4),
            audioLanguages: CatalogValues.decodeLanguages(row.string(5)),
            subtitleLanguages: CatalogValues.decodeLanguages(row.string(6)),
            quality: CatalogValues.decodeQuality(row.string(7)),
            streamURL: row.url(8) ?? Normalizer.placeholderURL,
            epgID: row.stringOrNil(9),
            sortIndex: row.int(10),
            isAdult: row.bool(11)
        )
    }

    private static func decodeEpisode(_ row: SQLiteRow) -> Episode {
        Episode(
            id: CatalogID(rawValue: row.string(0)),
            seriesID: CatalogID(rawValue: row.string(1)),
            seasonNumber: row.int(2),
            episodeNumber: row.int(3),
            title: row.string(4),
            overview: row.stringOrNil(5),
            durationMinutes: row.intOrNil(6),
            stillURL: row.url(7),
            streamURL: row.url(8) ?? Normalizer.placeholderURL
        )
    }

    private static func decodeEPG(_ row: SQLiteRow) -> EPGEvent {
        EPGEvent(
            channelEPGID: row.string(0),
            title: row.string(1),
            subtitle: row.stringOrNil(2),
            description: row.stringOrNil(3),
            start: Date(timeIntervalSince1970: row.double(4)),
            stop: Date(timeIntervalSince1970: row.double(5)),
            category: row.stringOrNil(6)
        )
    }

    // MARK: - Facets
    //
    // The distinct genre / language / category sets are the same after every
    // query and only change when the library does, so they're computed once at
    // the end of an import (`refreshFacetCache`) and stashed in `meta`. Each
    // accessor reads the cache and only falls back to a full-table scan when it's
    // missing (an import from before this cache existed, or a partial library
    // mid-import).

    public func channelCategories() async throws -> [String] {
        if let cached = try await metaList(MetaKey.facetChannelCategories) { return ["All"] + cached }
        return try await read { conn in
            ["All"] + (try conn.query("SELECT DISTINCT category FROM channel ORDER BY category") { $0.string(0) })
        }
    }

    public func presentGenres() async throws -> [Genre] {
        // The cache stores genres already ordered by prevalence — keep that order
        // so the filter chips lead with the genres the library actually has most
        // of. The scan fallback keeps the stable `allCases` order.
        if let cached = try await metaList(MetaKey.facetGenres) {
            return cached.compactMap { Genre(rawValue: $0) }
        }
        let raw: Set<String> = try await read { conn in
            Set(try conn.query("SELECT DISTINCT genre FROM movie_genre") { $0.string(0) }
                + conn.query("SELECT DISTINCT genre FROM series_genre") { $0.string(0) })
        }
        return Genre.allCases.filter { raw.contains($0.rawValue) }
    }

    // MARK: - Category browsing

    /// The provider's sections that make good browsing collections: at least
    /// `minimum` visible titles, biggest first, each with the newest poster in
    /// it as its artwork.
    public func collections(series: Bool, _ scope: Scope, minimum: Int = 4, limit: Int = 40) async throws -> [BrowseCategory] {
        let table = series ? "series" : "movie"
        let (where_, params) = Self.scopeClause(scope)
        return try await read { conn in
            try conn.query("""
                SELECT collection, COUNT(*) AS n,
                       (SELECT poster_url FROM \(table) p
                        WHERE p.collection = t.collection AND p.poster_url IS NOT NULL
                        ORDER BY p.added_at DESC LIMIT 1)
                FROM \(table) t
                WHERE collection IS NOT NULL AND \(where_)
                GROUP BY collection HAVING n >= ?
                ORDER BY n DESC, collection LIMIT ?
                """, params + [.integer(Int64(minimum)), .integer(Int64(limit))]) { row in
                BrowseCategory(kind: .collection(row.string(0)), count: row.int(1), artworkURL: row.url(2))
            }
        }
    }

    /// How many pure-music titles there are — sizes the "Music" entry.
    public func musicCount(series: Bool, _ scope: Scope) async throws -> Int {
        let (where_, params) = Self.scopeClause(scope, music: .only)
        return try await read { conn in
            try conn.scalarInt("SELECT count(*) FROM \(series ? "series" : "movie") WHERE \(where_)", params)
        }
    }

    /// Every genre with visible titles, biggest first, with the newest poster.
    public func genreCategories(series: Bool, _ scope: Scope) async throws -> [BrowseCategory] {
        let table = series ? "series" : "movie"
        let link = series ? "series_genre" : "movie_genre"
        let idColumn = series ? "series_id" : "movie_id"
        let (where_, params) = Self.scopeClause(scope)
        let counted: [(String, Int)] = try await read { conn in
            try conn.query("""
                SELECT g.genre, COUNT(*) AS n FROM \(link) g
                JOIN \(table) t ON t.id = g.\(idColumn)
                WHERE \(where_.replacingOccurrences(of: "is_", with: "t.is_"))
                GROUP BY g.genre ORDER BY n DESC
                """, params) { ($0.string(0), $0.int(1)) }
        }
        var out: [BrowseCategory] = []
        for (raw, count) in counted {
            guard let genre = Genre(rawValue: raw), genre != .other else { continue }
            let poster: URL? = try await read { conn in
                try conn.queryOne("""
                    SELECT t.poster_url FROM \(link) g JOIN \(table) t ON t.id = g.\(idColumn)
                    WHERE g.genre = ? AND t.poster_url IS NOT NULL
                    ORDER BY t.added_at DESC LIMIT 1
                    """, [.text(raw)]) { $0.url(0) } ?? nil
            }
            out.append(BrowseCategory(kind: .genre(genre), count: count, artworkURL: poster))
        }
        return out
    }

    public func presentLanguages(subtitles: Bool) async throws -> [Language] {
        let key = subtitles ? MetaKey.facetSubLanguages : MetaKey.facetAudioLanguages
        if let cached = try await metaList(key) {
            return cached.compactMap { Language(code: $0) }.sorted()
        }
        let column = subtitles ? "sub_langs" : "audio_langs"
        return try await read { conn in
            let rows = try conn.query(
                "SELECT \(column) FROM movie WHERE \(column) <> '' " +
                "UNION SELECT \(column) FROM series WHERE \(column) <> ''"
            ) { $0.string(0) }
            var codes = Set<String>()
            for wrapped in rows { for part in wrapped.split(separator: ",") { codes.insert(String(part)) } }
            return codes.compactMap { Language(code: $0) }.sorted()
        }
    }

    /// Recompute the facet cache from the current tables. Called at the end of an
    /// import, on the writer connection.
    public func refreshFacetCache() async throws {
        try await write { conn in
            // Genres, ordered by how many titles carry each — the filter chips
            // then lead with what the library has most of.
            var genreCounts: [String: Int] = [:]
            for table in ["movie_genre", "series_genre"] {
                let rows = try conn.query("SELECT genre, count(*) FROM \(table) GROUP BY genre") { row -> (String, Int) in
                    (row.string(0), row.int(1))
                }
                for row in rows { genreCounts[row.0, default: 0] += row.1 }
            }
            let genres = genreCounts.sorted { $0.value > $1.value }.map(\.key)

            func langCodes(_ column: String) throws -> [String] {
                let rows = try conn.query(
                    "SELECT \(column) FROM movie WHERE \(column) <> '' " +
                    "UNION SELECT \(column) FROM series WHERE \(column) <> ''"
                ) { $0.string(0) }
                var codes = Set<String>()
                for wrapped in rows { for part in wrapped.split(separator: ",") { codes.insert(String(part)) } }
                return codes.sorted()
            }
            let audio = try langCodes("audio_langs")
            let subs = try langCodes("sub_langs")
            let categories = try conn.query("SELECT DISTINCT category FROM channel ORDER BY category") { $0.string(0) }

            // Home genre shelves read these on every full rebuild; the live
            // query is a double GROUP BY join, so do it once per import here.
            var tallies: [(key: String, lines: [String])] = []
            for adult in [true, false] {
                for regions in [true, false] {
                    let scope = Scope(showAdult: adult, allRegions: regions)
                    let lines = try Self.genreTallyRows(conn, scope).map { "\($0.rawGenre)\t\($0.tally)" }
                    tallies.append((key: MetaKey.genreTally(scope), lines: lines))
                }
            }

            func setList(_ key: String, _ values: [String]) throws {
                _ = try conn.run(
                    "INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    [.text(key), .text(values.joined(separator: "\n"))]
                )
            }
            try conn.transaction {
                try setList(MetaKey.facetGenres, genres)
                try setList(MetaKey.facetAudioLanguages, audio)
                try setList(MetaKey.facetSubLanguages, subs)
                try setList(MetaKey.facetChannelCategories, categories)
                for tally in tallies { try setList(tally.key, tally.lines) }
            }
        }
    }

    /// A newline-delimited `meta` list, or `nil` when the key is unset.
    private func metaList(_ key: String) async throws -> [String]? {
        guard let raw = try await metaValue(key) else { return nil }
        return raw.isEmpty ? [] : raw.split(separator: "\n").map(String.init)
    }

    // MARK: - Counts

    public func movieCount(_ filter: CatalogFilter, _ scope: Scope) async throws -> Int {
        try await read { conn in
            let (where_, params) = Self.movieWhere(filter, scope)
            return try conn.scalarInt("SELECT count(*) FROM movie WHERE \(where_)", params)
        }
    }

    public func seriesCount(_ filter: CatalogFilter, _ scope: Scope) async throws -> Int {
        try await read { conn in
            let (where_, params) = Self.seriesWhere(filter, scope)
            return try conn.scalarInt("SELECT count(*) FROM series WHERE \(where_)", params)
        }
    }

    public func channelCount(category: String?, _ scope: Scope) async throws -> Int {
        try await read { conn in
            let (where_, params) = Self.channelWhere(category: category, scope)
            return try conn.scalarInt("SELECT count(*) FROM channel WHERE \(where_)", params)
        }
    }

    /// `true` when the table has at least one row — an `EXISTS` probe, so it
    /// stops at the first row instead of counting the whole table.
    public func hasRows(_ table: String) async throws -> Bool {
        try await read { conn in
            try conn.scalarInt("SELECT EXISTS(SELECT 1 FROM \(table))") == 1
        }
    }

    // MARK: - Paged lists

    /// A page of the browse grid. Uses the card projection — the grid shows a
    /// poster, title, year and genre, and the detail screen re-fetches the full
    /// row by id when you open one.
    public func movies(_ filter: CatalogFilter, _ scope: Scope, page: Int, pageSize: Int) async throws -> [Movie] {
        try await read { conn in
            let (where_, params) = Self.movieWhere(filter, scope)
            let sql = "SELECT \(Self.movieCardColumns) FROM movie WHERE \(where_) " +
                      "ORDER BY \(Self.orderClause(filter)) LIMIT ? OFFSET ?"
            return try conn.query(sql, params + [.integer(Int64(pageSize)), .integer(Int64(page * pageSize))], Self.decodeMovie)
        }
    }

    /// A single random matching movie — `ORDER BY random() LIMIT 1` over the
    /// filtered set. Card projection (opened via the detail screen anyway).
    public func randomMovie(_ filter: CatalogFilter, _ scope: Scope) async throws -> Movie? {
        try await read { conn in
            let (where_, params) = Self.movieWhere(filter, scope)
            return try conn.queryOne(
                "SELECT \(Self.movieCardColumns) FROM movie WHERE \(where_) ORDER BY random() LIMIT 1",
                params, Self.decodeMovie
            )
        }
    }

    public func randomSeries(_ filter: CatalogFilter, _ scope: Scope) async throws -> Series? {
        try await read { conn in
            let (where_, params) = Self.seriesWhere(filter, scope)
            return try conn.queryOne(
                "SELECT \(Self.seriesColumns) FROM series WHERE \(where_) ORDER BY random() LIMIT 1",
                params, { row in Self.decodeSeries(row, seasons: []) }
            )
        }
    }

    public func series(_ filter: CatalogFilter, _ scope: Scope, page: Int, pageSize: Int) async throws -> [Series] {
        try await read { conn in
            let (where_, params) = Self.seriesWhere(filter, scope)
            let sql = "SELECT \(Self.seriesColumns) FROM series WHERE \(where_) " +
                      "ORDER BY \(Self.orderClause(filter)) LIMIT ? OFFSET ?"
            return try conn.query(sql, params + [.integer(Int64(pageSize)), .integer(Int64(page * pageSize))]) {
                row in Self.decodeSeries(row, seasons: [])
            }
        }
    }

    public func channels(category: String?, sort: ChannelSort, _ scope: Scope, page: Int, pageSize: Int) async throws -> [Channel] {
        try await read { conn in
            let (where_, params) = Self.channelWhere(category: category, scope)
            let order: String
            switch sort {
            case .number:  order = "(recent_rank IS NULL), recent_rank, region_priority, sort_index, name_fold"
            case .nameAsc: order = "name_fold, sort_index"
            }
            let sql = "SELECT \(Self.channelColumns) FROM channel WHERE \(where_) ORDER BY \(order) LIMIT ? OFFSET ?"
            return try conn.query(sql, params + [.integer(Int64(pageSize)), .integer(Int64(page * pageSize))], Self.decodeChannel)
        }
    }

    // MARK: - A–Z rail anchors
    //
    // The rail needs, per first letter, the position of its first row in the
    // sorted+filtered list. That's a `row_number()` window over the same order
    // the grid pages in — computed in SQL so ~30 `(letter, index)` rows cross
    // the boundary instead of every matching title.

    public func movieTitleAnchors(_ filter: CatalogFilter, _ scope: Scope) async throws -> [BrowseAnchor] {
        try await read { conn in
            let (where_, params) = Self.movieWhere(filter, scope)
            return try Self.anchorRows(conn, table: "movie", where_: where_, params: params,
                                       order: Self.orderClause(filter))
        }
    }

    public func seriesTitleAnchors(_ filter: CatalogFilter, _ scope: Scope) async throws -> [BrowseAnchor] {
        try await read { conn in
            let (where_, params) = Self.seriesWhere(filter, scope)
            return try Self.anchorRows(conn, table: "series", where_: where_, params: params,
                                       order: Self.orderClause(filter))
        }
    }

    public func channelNameAnchors(category: String?, _ scope: Scope) async throws -> [BrowseAnchor] {
        try await read { conn in
            let (where_, params) = Self.channelWhere(category: category, scope)
            return try Self.anchorRows(conn, table: "channel", where_: where_, params: params,
                                       order: "name_fold, sort_index", titleColumn: "name_fold")
        }
    }

    private static func anchorRows(
        _ conn: SQLiteConnection, table: String, where_: String,
        params: [SQLiteValue], order: String, titleColumn: String = "title_fold"
    ) throws -> [BrowseAnchor] {
        let sql = """
        SELECT letter, MIN(rn) AS idx FROM (
            SELECT substr(\(titleColumn), 1, 1) AS letter,
                   (row_number() OVER (ORDER BY \(order))) - 1 AS rn
            FROM \(table) WHERE \(where_)
        ) WHERE letter <> '' GROUP BY letter ORDER BY idx
        """
        let raw = try conn.query(sql, params) { row -> (letter: String, index: Int) in
            (letter: row.string(0), index: row.int(1))
        }
        return foldAnchors(raw)
    }

    /// Collapse first-character rows into display buckets: digits → `#`, letters
    /// → uppercase. Keeps each bucket's lowest index and returns them in
    /// list order.
    static func foldAnchors(_ raw: [(letter: String, index: Int)]) -> [BrowseAnchor] {
        var best: [String: Int] = [:]
        for entry in raw {
            guard let ch = entry.letter.first else { continue }
            let bucket = ch.isNumber ? "#" : String(ch).uppercased()
            best[bucket] = Swift.min(best[bucket] ?? entry.index, entry.index)
        }
        return best.map { BrowseAnchor(letter: $0.key, index: $0.value) }
            .sorted { $0.index < $1.index }
    }

    // MARK: - By id

    public func movie(id: CatalogID) async throws -> Movie? {
        try await read { conn in
            try conn.queryOne("SELECT \(Self.movieColumns) FROM movie WHERE id = ?", [.text(id.rawValue)], Self.decodeMovie)
        }
    }

    public func channel(id: CatalogID) async throws -> Channel? {
        try await read { conn in
            try conn.queryOne("SELECT \(Self.channelColumns) FROM channel WHERE id = ?", [.text(id.rawValue)], Self.decodeChannel)
        }
    }

    public func series(id: CatalogID) async throws -> Series? {
        try await read { conn in
            let shell = try conn.queryOne(
                "SELECT \(Self.seriesColumns) FROM series WHERE id = ?",
                [.text(id.rawValue)],
                { row in Self.decodeSeries(row, seasons: []) }
            )
            guard var show = shell else { return nil }
            show.seasons = try Self.loadSeasons(conn, seriesID: id)
            return show
        }
    }

    public func moviesByID(_ ids: [CatalogID]) async throws -> [Movie] {
        try await read { conn in try Self.fetchByIDs(conn, ids, table: "movie", columns: Self.movieColumns, decode: Self.decodeMovie) }
    }

    public func channelsByID(_ ids: [CatalogID]) async throws -> [Channel] {
        try await read { conn in try Self.fetchByIDs(conn, ids, table: "channel", columns: Self.channelColumns, decode: Self.decodeChannel) }
    }

    public func seriesByID(_ ids: [CatalogID]) async throws -> [Series] {
        try await read { conn in try Self.fetchByIDs(conn, ids, table: "series", columns: Self.seriesColumns) { row in Self.decodeSeries(row, seasons: []) } }
    }

    private static func fetchByIDs<T>(_ conn: SQLiteConnection, _ ids: [CatalogID], table: String, columns: String, decode: (SQLiteRow) throws -> T) throws -> [T] {
        guard !ids.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        return try conn.query(
            "SELECT \(columns) FROM \(table) WHERE id IN (\(placeholders))",
            ids.map { SQLiteValue.text($0.rawValue) }, decode
        )
    }

    // MARK: - Seasons / episodes

    private static func loadSeasons(_ conn: SQLiteConnection, seriesID: CatalogID) throws -> [Season] {
        let episodes = try conn.query(
            "SELECT \(episodeColumns) FROM episode WHERE series_id = ? ORDER BY season, episode",
            [.text(seriesID.rawValue)], decodeEpisode
        )
        let bySeason = Dictionary(grouping: episodes, by: { $0.seasonNumber })
        return bySeason.keys.sorted().map { number in
            Season(seriesID: seriesID, number: number, episodes: bySeason[number] ?? [])
        }
    }

    public func seasons(seriesID: CatalogID) async throws -> [Season] {
        try await read { conn in try Self.loadSeasons(conn, seriesID: seriesID) }
    }

    public func episode(id: CatalogID) async throws -> Episode? {
        try await read { conn in
            try conn.queryOne("SELECT \(Self.episodeColumns) FROM episode WHERE id = ?", [.text(id.rawValue)], Self.decodeEpisode)
        }
    }

    public func episodesByID(_ ids: [CatalogID]) async throws -> [Episode] {
        try await read { conn in try Self.fetchByIDs(conn, ids, table: "episode", columns: Self.episodeColumns, decode: Self.decodeEpisode) }
    }

    /// Series for the given ids, each with its full season / episode tree.
    public func seriesWithSeasons(ids: [CatalogID]) async throws -> [Series] {
        try await read { conn in
            try Self.fetchByIDs(conn, ids, table: "series", columns: Self.seriesColumns) { row in Self.decodeSeries(row, seasons: []) }
                .map { shell in
                    var full = shell
                    full.seasons = (try? Self.loadSeasons(conn, seriesID: shell.id)) ?? []
                    return full
                }
        }
    }

    public func hasEpisodes(seriesID: CatalogID) async throws -> Bool {
        try await read { conn in
            try conn.scalarInt("SELECT count(*) FROM episode WHERE series_id = ? LIMIT 1", [.text(seriesID.rawValue)]) > 0
        }
    }

    // MARK: - Recently added

    public func recentlyAddedMovies(limit: Int, _ scope: Scope) async throws -> [Movie] {
        try await read { conn in
            let (clause, params) = Self.scopeClause(scope)
            return try conn.query(
                "SELECT \(Self.movieCardColumns) FROM movie WHERE \(clause) ORDER BY added_at DESC LIMIT ?",
                params + [.integer(Int64(limit))], Self.decodeMovie
            )
        }
    }

    public func recentlyAddedSeries(limit: Int, _ scope: Scope) async throws -> [Series] {
        try await read { conn in
            let (clause, params) = Self.scopeClause(scope)
            return try conn.query(
                "SELECT \(Self.seriesColumns) FROM series WHERE \(clause) ORDER BY added_at DESC LIMIT ?",
                params + [.integer(Int64(limit))]
            ) { row in Self.decodeSeries(row, seasons: []) }
        }
    }

    // MARK: - Genre shelves (Home)

    public struct GenreTally: Sendable {
        public let genre: Genre
        public let count: Int
    }

    /// Genres by how many titles carry them, most first. Served from the
    /// per-import `meta` cache (see `refreshFacetCache`); falls back to the
    /// live query when the cache is missing (mid-import, or a library imported
    /// before the cache existed).
    public func genreCounts(_ scope: Scope) async throws -> [GenreTally] {
        if let cached = try await metaList(MetaKey.genreTally(scope)) {
            return cached.compactMap { line -> GenreTally? in
                let parts = line.split(separator: "\t", maxSplits: 1)
                guard parts.count == 2,
                      let genre = Genre(rawValue: String(parts[0])),
                      let count = Int(parts[1]) else { return nil }
                return GenreTally(genre: genre, count: count)
            }
        }
        return try await read { conn in
            try Self.genreTallyRows(conn, scope).compactMap { row -> GenreTally? in
                guard let genre = Genre(rawValue: row.rawGenre) else { return nil }
                return GenreTally(genre: genre, count: row.tally)
            }
        }
    }

    /// The live genre tally for `scope` — shared by `genreCounts` (fallback)
    /// and `refreshFacetCache` (which caches it).
    private static func genreTallyRows(_ conn: SQLiteConnection, _ scope: Scope) throws -> [(rawGenre: String, tally: Int)] {
        let (clause, params) = scopeClause(scope)
        return try conn.query("""
        SELECT genre, sum(n) AS total FROM (
            SELECT g.genre AS genre, count(*) AS n FROM movie_genre g
                JOIN movie m ON m.id = g.movie_id WHERE \(clause) GROUP BY g.genre
            UNION ALL
            SELECT g.genre AS genre, count(*) AS n FROM series_genre g
                JOIN series s ON s.id = g.series_id WHERE \(clause) GROUP BY g.genre
        ) GROUP BY genre ORDER BY total DESC
        """, params + params) { row in (rawGenre: row.string(0), tally: row.int(1)) }
    }

    public func moviesInGenre(_ genre: Genre, _ scope: Scope, limit: Int) async throws -> [Movie] {
        try await read { conn in
            let (clause, params) = Self.scopeClause(scope)
            return try conn.query("""
            SELECT \(Self.movieCardColumns) FROM movie
            WHERE \(clause) AND EXISTS (SELECT 1 FROM movie_genre g WHERE g.movie_id = movie.id AND g.genre = ?)
            ORDER BY added_at DESC LIMIT ?
            """, params + [.text(genre.rawValue), .integer(Int64(limit))], Self.decodeMovie)
        }
    }

    public func seriesInGenre(_ genre: Genre, _ scope: Scope, limit: Int) async throws -> [Series] {
        try await read { conn in
            let (clause, params) = Self.scopeClause(scope)
            return try conn.query("""
            SELECT \(Self.seriesColumns) FROM series
            WHERE \(clause) AND EXISTS (SELECT 1 FROM series_genre g WHERE g.series_id = series.id AND g.genre = ?)
            ORDER BY added_at DESC LIMIT ?
            """, params + [.text(genre.rawValue), .integer(Int64(limit))]) { row in Self.decodeSeries(row, seasons: []) }
        }
    }

    public func moviesInAudioLanguages(_ languages: [Language], _ scope: Scope, limit: Int) async throws -> [Movie] {
        guard !languages.isEmpty else { return [] }
        return try await read { conn in
            let (clause, params) = Self.scopeClause(scope)
            let langClause = languages.map { _ in "instr(audio_langs, ?) > 0" }.joined(separator: " OR ")
            return try conn.query(
                "SELECT \(Self.movieCardColumns) FROM movie WHERE \(clause) AND (\(langClause)) " +
                "ORDER BY added_at DESC LIMIT ?",
                params + languages.map { SQLiteValue.text(CatalogValues.needle($0)) } + [.integer(Int64(limit))],
                Self.decodeMovie
            )
        }
    }

    public func moviesInSubtitleLanguage(_ language: Language, _ scope: Scope, limit: Int) async throws -> [Movie] {
        try await read { conn in
            let (clause, params) = Self.scopeClause(scope)
            return try conn.query(
                "SELECT \(Self.movieCardColumns) FROM movie WHERE \(clause) AND instr(sub_langs, ?) > 0 " +
                "ORDER BY added_at DESC LIMIT ?",
                params + [.text(CatalogValues.needle(language)), .integer(Int64(limit))], Self.decodeMovie
            )
        }
    }

    // MARK: - Guide

    public func guideChannels(limit: Int, _ scope: Scope) async throws -> [Channel] {
        try await read { conn in
            var clauses = [Self.scopeClause(scope, vod: false).0]
            var params: [SQLiteValue] = []
            Self.appendChannelCountry(to: &clauses, params: &params, scope: scope)
            clauses.append("epg_id IS NOT NULL AND epg_id <> ''")
            return try conn.query(
                "SELECT \(Self.channelColumns) FROM channel WHERE \(clauses.joined(separator: " AND ")) " +
                "ORDER BY (recent_rank IS NULL), recent_rank, region_priority, sort_index, name_fold LIMIT ?",
                params + [.integer(Int64(limit))], Self.decodeChannel
            )
        }
    }

    // MARK: - Search candidates (ranking stays in SearchEngine)

    public func movieCandidates(_ filter: CatalogFilter, _ scope: Scope, limit: Int) async throws -> [Movie] {
        try await read { conn in
            let (where_, params) = Self.movieWhere(filter, scope)
            return try conn.query(
                "SELECT \(Self.movieColumns) FROM movie WHERE \(where_) LIMIT ?",
                params + [.integer(Int64(limit))], Self.decodeMovie
            )
        }
    }

    public func seriesCandidates(_ filter: CatalogFilter, _ scope: Scope, limit: Int) async throws -> [Series] {
        try await read { conn in
            let (where_, params) = Self.seriesWhere(filter, scope)
            return try conn.query(
                "SELECT \(Self.seriesColumns) FROM series WHERE \(where_) LIMIT ?",
                params + [.integer(Int64(limit))]
            ) { row in Self.decodeSeries(row, seasons: []) }
        }
    }

    public func channelCandidates(text: String, _ scope: Scope, limit: Int) async throws -> [Channel] {
        try await read { conn in
            let (clause, params) = Self.scopeClause(scope, vod: false)
            // Every word, any order; within the viewer's channel scope.
            var clauses = [clause]
            var allParams = params
            Self.appendChannelCountry(to: &clauses, params: &allParams, scope: scope)
            for token in text.foldedForSearch().split(separator: " ") where !token.isEmpty {
                clauses.append("instr(name_fold, ?) > 0")
                allParams.append(.text(String(token)))
            }
            return try conn.query(
                "SELECT \(Self.channelColumns) FROM channel WHERE \(clauses.joined(separator: " AND ")) " +
                "ORDER BY region_priority, sort_index LIMIT ?",
                allParams + [.integer(Int64(limit))], Self.decodeChannel
            )
        }
    }

    // MARK: - "More like this"

    public func similarMovies(to id: CatalogID, genres: [Genre], _ scope: Scope, limit: Int) async throws -> [Movie] {
        guard !genres.isEmpty else { return [] }
        return try await read { conn in
            let (clause, params) = Self.scopeClause(scope)
            let ph = Array(repeating: "?", count: genres.count).joined(separator: ",")
            let genreArgs = genres.map { SQLiteValue.text($0.rawValue) }
            // A varied candidate pool — best genre overlap first, then a random
            // spread (not always the newest) — that `RelatedRanker` narrows.
            // Restrict to titles that share at least one genre *before* scoring —
            // the correlated `shared` count then runs over that small candidate
            // set, not the whole visible library.
            let sql = """
            SELECT \(Self.movieColumns), \
            (SELECT count(*) FROM movie_genre g WHERE g.movie_id = movie.id AND g.genre IN (\(ph))) AS shared
            FROM movie WHERE \(clause) AND id <> ? \
            AND id IN (SELECT movie_id FROM movie_genre WHERE genre IN (\(ph)))
            ORDER BY shared DESC, random() LIMIT ?
            """
            let args = params + genreArgs + [.text(id.rawValue)] + genreArgs + [.integer(Int64(limit))]
            return try conn.query(sql, args, Self.decodeMovie)
        }
    }

    public func similarSeries(to id: CatalogID, genres: [Genre], _ scope: Scope, limit: Int) async throws -> [Series] {
        guard !genres.isEmpty else { return [] }
        return try await read { conn in
            let (clause, params) = Self.scopeClause(scope)
            let ph = Array(repeating: "?", count: genres.count).joined(separator: ",")
            let genreArgs = genres.map { SQLiteValue.text($0.rawValue) }
            let sql = """
            SELECT \(Self.seriesColumns), \
            (SELECT count(*) FROM series_genre g WHERE g.series_id = series.id AND g.genre IN (\(ph))) AS shared
            FROM series WHERE \(clause) AND id <> ? \
            AND id IN (SELECT series_id FROM series_genre WHERE genre IN (\(ph)))
            ORDER BY shared DESC, random() LIMIT ?
            """
            let args = params + genreArgs + [.text(id.rawValue)] + genreArgs + [.integer(Int64(limit))]
            return try conn.query(sql, args) { row in Self.decodeSeries(row, seasons: []) }
        }
    }

    // MARK: - Artwork seeds (newest first)

    public func artworkSeeds(movieLimit: Int, seriesLimit: Int) async throws -> [ArtworkSeed] {
        try await read { conn in
            let movies = try conn.query(
                "SELECT id, title, year FROM movie ORDER BY added_at DESC LIMIT ?",
                [.integer(Int64(movieLimit))]
            ) { ArtworkSeed(id: CatalogID(rawValue: $0.string(0)), title: $0.string(1), year: $0.intOrNil(2), isSeries: false) }
            let series = try conn.query(
                "SELECT id, title, year FROM series ORDER BY added_at DESC LIMIT ?",
                [.integer(Int64(seriesLimit))]
            ) { ArtworkSeed(id: CatalogID(rawValue: $0.string(0)), title: $0.string(1), year: $0.intOrNil(2), isSeries: true) }
            return movies + series
        }
    }

    // MARK: - EPG

    public func epgEvents(epgID: String, in window: DateInterval) async throws -> [EPGEvent] {
        try await read { conn in
            try conn.query(
                "SELECT \(Self.epgColumns) FROM epg_event WHERE channel_epg_id = ? AND stop_at > ? AND start_at < ? ORDER BY start_at",
                [.text(epgID), .real(window.start.timeIntervalSince1970), .real(window.end.timeIntervalSince1970)],
                Self.decodeEPG
            )
        }
    }

    public func nowPlaying(epgID: String, at date: Date) async throws -> EPGEvent? {
        let t = date.timeIntervalSince1970
        return try await read { conn in
            try conn.queryOne(
                "SELECT \(Self.epgColumns) FROM epg_event WHERE channel_epg_id = ? AND start_at <= ? AND stop_at > ? ORDER BY start_at DESC LIMIT 1",
                [.text(epgID), .real(t), .real(t)], Self.decodeEPG
            )
        }
    }

    /// Every event for the given EPG ids inside the window, grouped by id.
    public func epgIndex(epgIDs: [String], in window: DateInterval) async throws -> [String: [EPGEvent]] {
        guard !epgIDs.isEmpty else { return [:] }
        return try await read { conn in
            let placeholders = Array(repeating: "?", count: epgIDs.count).joined(separator: ",")
            let rows = try conn.query(
                "SELECT \(Self.epgColumns) FROM epg_event WHERE channel_epg_id IN (\(placeholders)) " +
                "AND stop_at > ? AND start_at < ? ORDER BY channel_epg_id, start_at",
                epgIDs.map { SQLiteValue.text($0) } +
                [.real(window.start.timeIntervalSince1970), .real(window.end.timeIntervalSince1970)],
                Self.decodeEPG
            )
            return Dictionary(grouping: rows, by: { $0.channelEPGID })
        }
    }

    /// Programmes whose title contains every word of `text`, airing between
    /// `window.start` and `window.end`, with a visible channel to watch them on.
    ///
    /// The SQL prefilters on the longest word with `LIKE`, every vowel turned
    /// into a one-character wildcard — "pa sparet" → `%sp_r_t%` still finds
    /// "På spåret" (SQLite can't fold å/ä/ö, and `LIKE` is case-insensitive for
    /// ASCII only). The exact folded, every-word match then happens in Swift.
    public func searchProgrammes(text: String, in window: DateInterval, _ scope: Scope,
                                 limit: Int) async throws -> [ProgrammeHit] {
        let words = text.foldedForSearch().split(separator: " ").map(String.init).filter { $0.count > 1 }
        guard let longest = words.max(by: { $0.count < $1.count }) else { return [] }
        var pattern = ""
        for ch in longest {
            switch ch {
            case "a", "e", "i", "o", "u", "y": pattern.append("_")
            case "%", "_", "\\": pattern.append("\\"); pattern.append(ch)
            default: pattern.append(ch)
            }
        }
        let escaped = pattern
        return try await read { conn in
            let events = try conn.query(
                "SELECT \(Self.epgColumns) FROM epg_event WHERE stop_at > ? AND start_at < ? " +
                "AND title LIKE ? ESCAPE '\\' ORDER BY start_at LIMIT 600",
                [.real(window.start.timeIntervalSince1970), .real(window.end.timeIntervalSince1970),
                 .text("%\(escaped)%")],
                Self.decodeEPG
            ).filter { ProgrammeHit.matches($0.title, query: text) }
            guard !events.isEmpty else { return [] }

            let ids = Array(Set(events.map(\.channelEPGID)))
            let (where_, params) = Self.channelWhere(category: nil, scope)
            let ph = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let channels = try conn.query(
                "SELECT \(Self.channelColumns) FROM channel WHERE epg_id IN (\(ph)) AND \(where_) " +
                "ORDER BY region_priority, sort_index",
                ids.map { SQLiteValue.text($0) } + params,
                Self.decodeChannel
            )
            // Several channels can share one guide id (HD / SD feeds) — the
            // best-ranked one stands for all of them.
            var byEPG: [String: Channel] = [:]
            for channel in channels {
                if let epgID = channel.epgID, byEPG[epgID] == nil { byEPG[epgID] = channel }
            }
            let hits = events.compactMap { event in
                byEPG[event.channelEPGID].map { ProgrammeHit(event: event, channel: $0) }
            }
            return ProgrammeHit.ranked(hits, now: Date(), limit: limit)
        }
    }

    // MARK: - WHERE builders (pure — no instance state)

    /// The visibility predicate, written as plain equalities (not `(? OR …)`) so
    /// SQLite can seek the composite `(is_relevant, is_adult, …)` indexes rather
    /// than scanning past the filtered-out bulk of a large provider's dump.
    /// Always a valid boolean expression — `"1"` when the scope constrains
    /// nothing.
    private static func scopeClause(_ scope: Scope, vod: Bool = true,
                                    music: CatalogFilter.Music = .hidden) -> (String, [SQLiteValue]) {
        var parts: [String] = []
        if !scope.allRegions { parts.append("is_relevant = 1") }
        if !scope.showAdult { parts.append("is_adult = 0") }
        if vod {
            switch music {
            case .hidden:   parts.append("NOT \(pureMusic)")
            case .only:     parts.append(pureMusic)
            case .included: break
            }
        }
        return (parts.isEmpty ? "1" : parts.joined(separator: " AND "), [])
    }

    /// Pure music — concerts, music videos, karaoke — as opposed to films that
    /// are *about* music (a music documentary or a biopic stays a film). Kept
    /// out of Movies / Series / Home and reached through its own "Music"
    /// entry. A title is pure music when its only genre is Music, or it sits in
    /// a music / concert section; anything tagged Documentary is never.
    static let pureMusic = """
    (instr(genres, ',documentary,') = 0 AND (genres = ',music,' OR genres = ',music,other,' \
    OR genres = ',other,music,' OR (collection IS NOT NULL AND (lower(collection) LIKE '%music%' \
    OR lower(collection) LIKE '%musik%' OR lower(collection) LIKE '%concert%' \
    OR lower(collection) LIKE '%konsert%' OR lower(collection) LIKE '%karaoke%'))))
    """

    private static func movieWhere(_ filter: CatalogFilter, _ scope: Scope) -> (String, [SQLiteValue]) {
        let (scopeExpr, scopeParams) = scopeClause(scope, music: filter.music)
        var clauses = [scopeExpr]
        var params = scopeParams
        appendCommon(to: &clauses, params: &params, filter: filter, genreTable: "movie_genre", idColumn: "movie_id", hasDuration: true)
        return (clauses.joined(separator: " AND "), params)
    }

    private static func seriesWhere(_ filter: CatalogFilter, _ scope: Scope) -> (String, [SQLiteValue]) {
        let (scopeExpr, scopeParams) = scopeClause(scope, music: filter.music)
        var clauses = [scopeExpr]
        var params = scopeParams
        appendCommon(to: &clauses, params: &params, filter: filter, genreTable: "series_genre", idColumn: "series_id", hasDuration: false)
        return (clauses.joined(separator: " AND "), params)
    }

    private static func channelWhere(category: String?, _ scope: Scope) -> (String, [SQLiteValue]) {
        let (scopeExpr, scopeParams) = scopeClause(scope, vod: false)
        var clauses = [scopeExpr]
        var params = scopeParams
        appendChannelCountry(to: &clauses, params: &params, scope: scope)
        if let category, category != "All" {
            clauses.append("category = ?")
            params.append(.text(category))
        }
        return (clauses.joined(separator: " AND "), params)
    }

    /// Adds `AND (country_code IS NULL OR country_code IN (…))` when the scope
    /// limits channel countries. No-country channels (generic feeds) always pass.
    private static func appendChannelCountry(to clauses: inout [String], params: inout [SQLiteValue], scope: Scope) {
        guard let countries = scope.channelCountries, !countries.isEmpty else { return }
        let ordered = countries.sorted()
        let ph = Array(repeating: "?", count: ordered.count).joined(separator: ",")
        clauses.append("(country_code IS NULL OR country_code IN (\(ph)))")
        params += ordered.map { SQLiteValue.text($0) }
    }

    private static func appendCommon(
        to clauses: inout [String], params: inout [SQLiteValue],
        filter: CatalogFilter, genreTable: String, idColumn: String, hasDuration: Bool
    ) {
        if !filter.collections.isEmpty {
            let ph = Array(repeating: "?", count: filter.collections.count).joined(separator: ",")
            clauses.append("collection IN (\(ph))")
            params += filter.collections.map { SQLiteValue.text($0) }
        }
        if !filter.genres.isEmpty {
            let ph = Array(repeating: "?", count: filter.genres.count).joined(separator: ",")
            clauses.append("id IN (SELECT \(idColumn) FROM \(genreTable) WHERE genre IN (\(ph)))")
            params += filter.genres.map { SQLiteValue.text($0.rawValue) }
        }
        for lang in filter.audioLanguages {
            clauses.append("instr(audio_langs, ?) > 0")
            params.append(.text(CatalogValues.needle(lang)))
        }
        for lang in filter.subtitleLanguages {
            clauses.append("instr(sub_langs, ?) > 0")
            params.append(.text(CatalogValues.needle(lang)))
        }
        if let minYear = filter.minYear {
            clauses.append("year IS NOT NULL AND year >= ?")
            params.append(.integer(Int64(minYear)))
        }
        if let maxYear = filter.maxYear {
            clauses.append("year IS NOT NULL AND year <= ?")
            params.append(.integer(Int64(maxYear)))
        }
        if let minQuality = filter.minQuality, minQuality > .unknown {
            clauses.append("(CASE quality WHEN 'uhd' THEN 4 WHEN 'fhd' THEN 3 WHEN 'hd' THEN 2 WHEN 'sd' THEN 1 ELSE 0 END) >= ?")
            params.append(.integer(Int64(qualityRank(minQuality))))
        }
        if hasDuration, let maxDuration = filter.maxDurationMinutes {
            clauses.append("(duration_min IS NULL OR duration_min <= ?)")
            params.append(.integer(Int64(maxDuration)))
        }
        // Every word must appear somewhere in the title, in any order —
        // "thrones game" finds "Game of Thrones". Ranking (exact > prefix >
        // contains) happens in `SearchEngine`.
        for token in filter.text.foldedForSearch().split(separator: " ") where !token.isEmpty {
            clauses.append("instr(title_fold, ?) > 0")
            params.append(.text(String(token)))
        }
    }

    private static func qualityRank(_ q: VideoQuality) -> Int {
        switch q {
        case .unknown: return 0
        case .sd:      return 1
        case .hd:      return 2
        case .fhd:     return 3
        case .uhd:     return 4
        }
    }

    private static func orderClause(_ filter: CatalogFilter) -> String {
        if filter.sort == .forYou { return forYouOrder(filter.forYou ?? ForYouProfile()) }
        return orderClause(filter.sort)
    }

    /// "For You": a score from your languages (audio beats subtitles; the first
    /// language weighs most), the genres you watch most, freshness and picture
    /// quality — then newest added. Values are inlined: language codes are two
    /// letters and genres an enum, so nothing user-typed reaches the SQL.
    static func forYouOrder(_ profile: ForYouProfile, now: Date = Date()) -> String {
        var terms: [String] = []
        for (i, lang) in profile.languages.prefix(2).enumerated() {
            let needle = CatalogValues.needle(lang)
            terms.append("(CASE WHEN instr(audio_langs, '\(needle)') > 0 THEN \(6 - 2 * i) " +
                         "WHEN instr(sub_langs, '\(needle)') > 0 THEN \(3 - i) ELSE 0 END)")
        }
        for (i, genre) in profile.genres.prefix(3).enumerated() {
            terms.append("(CASE WHEN instr(genres, '\(CatalogValues.needle(genre))') > 0 THEN \(4 - i) ELSE 0 END)")
        }
        let month = Int(now.addingTimeInterval(-30 * 86_400).timeIntervalSince1970)
        let recentYear = Calendar(identifier: .gregorian).component(.year, from: now) - 3
        terms.append("(CASE WHEN added_at > \(month) THEN 2 ELSE 0 END)")
        terms.append("(CASE WHEN year >= \(recentYear) THEN 1 ELSE 0 END)")
        terms.append("(CASE WHEN quality IN ('hd','fhd','uhd') THEN 1 ELSE 0 END)")
        return "(" + terms.joined(separator: " + ") + ") DESC, added_at DESC, title_fold"
    }

    private static func orderClause(_ sort: BrowseSort) -> String {
        switch sort {
        case .forYou:         return "added_at DESC, title_fold"   // no profile: freshest
        // SQLite sorts NULL lowest, so `DESC` already puts undated rows last —
        // no `(x IS NULL)` lead term, which would hide the column from the
        // `*_visible_added` / `*_visible_year` indexes and force a full sort of
        // the library on every page.
        case .recentlyAdded:  return "added_at DESC, title_fold"
        case .titleAscending: return "title_fold, (year IS NULL), year"
        case .newest:         return "year DESC, title_fold"
        case .oldest:         return "(year IS NULL), year ASC, title_fold"
        }
    }

    // MARK: - Writes

    /// Wipe every catalog table (keeps `meta`), inside one transaction.
    public func clearCatalog() async throws {
        try await write { conn in
            try conn.transaction {
                for table in ["channel", "movie", "movie_genre", "series", "series_genre", "episode", "epg_event"] {
                    try conn.execute("DELETE FROM \(table)")
                }
                for key in [MetaKey.facetGenres, MetaKey.facetAudioLanguages,
                            MetaKey.facetSubLanguages, MetaKey.facetChannelCategories] + MetaKey.genreTallyKeys {
                    _ = try conn.run("DELETE FROM meta WHERE key = ?", [.text(key)])
                }
            }
        }
    }

    public func insertChannels(_ channels: [Channel], homeRegions: Set<String>, generation: Int = 1) async throws {
        let gen = Int64(generation)
        let rows = channels.map { channel -> [SQLiteValue] in
            let relevant = RelevanceFilter.isRelevant(
                countryCode: channel.countryCode, name: channel.name, category: channel.category,
                audioLanguages: channel.audioLanguages, subtitleLanguages: channel.subtitleLanguages
            )
            return [
                .text(channel.id.rawValue),
                .text(channel.name),
                .text(channel.name.foldedForSearch()),
                .text(channel.category),
                SQLiteValue(channel.logoURL),
                SQLiteValue(channel.countryCode),
                .text(CatalogValues.encode(channel.audioLanguages)),
                .text(CatalogValues.encode(channel.subtitleLanguages)),
                .text(CatalogValues.encode(channel.quality)),
                .text(channel.streamURL.absoluteString),
                SQLiteValue(channel.epgID),
                .integer(Int64(channel.sortIndex)),
                SQLiteValue(channel.isAdult),
                SQLiteValue(relevant),
                .integer(Int64(RelevanceFilter.priority(countryCode: channel.countryCode, home: homeRegions))),
                .integer(gen),
            ]
        }
        try await write { conn in
            try conn.transaction {
                try conn.executeMany("""
                INSERT OR REPLACE INTO channel
                (id, name, name_fold, category, logo_url, country_code, audio_langs, sub_langs, quality,
                 stream_url, epg_id, sort_index, is_adult, is_relevant, region_priority, gen)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, rows)
            }
        }
    }

    public func insertMovies(_ movies: [Movie], generation: Int = 1) async throws {
        let gen = Int64(generation)
        let rows = movies.map { movie -> [SQLiteValue] in
            let relevant = RelevanceFilter.isRelevant(
                countryCode: movie.countryCode, name: movie.title,
                category: movie.genres.first?.displayName ?? "",
                audioLanguages: movie.audioLanguages, subtitleLanguages: movie.subtitleLanguages
            )
            return [
                .text(movie.id.rawValue),
                .text(movie.title),
                .text(movie.title.foldedForSearch()),
                SQLiteValue(movie.year),
                SQLiteValue(movie.durationMinutes),
                .text(CatalogValues.encode(movie.audioLanguages)),
                .text(CatalogValues.encode(movie.subtitleLanguages)),
                .text(CatalogValues.encode(movie.genres)),
                .text(CatalogValues.encode(movie.quality)),
                SQLiteValue(movie.countryCode),
                SQLiteValue(movie.posterURL),
                SQLiteValue(movie.backdropURL),
                SQLiteValue(movie.synopsis),
                .text(CatalogValues.encode(list: movie.cast)),
                .text(CatalogValues.encode(list: movie.directors)),
                .text(movie.streamURL.absoluteString),
                SQLiteValue(date: movie.addedAt),
                SQLiteValue(movie.isAdult),
                SQLiteValue(relevant),
                SQLiteValue(movie.collection),
                .integer(gen),
            ]
        }
        let genreClears = movies.map { [SQLiteValue.text($0.id.rawValue)] }
        let genreRows = movies.flatMap { movie in
            movie.genres.map { [SQLiteValue.text(movie.id.rawValue), .text($0.rawValue)] }
        }
        try await write { conn in
            try conn.transaction {
                try conn.executeMany("""
                INSERT OR REPLACE INTO movie
                (id, title, title_fold, year, duration_min, audio_langs, sub_langs, genres, quality,
                 country_code, poster_url, backdrop_url, synopsis, cast_list, directors, stream_url,
                 added_at, is_adult, is_relevant, collection, gen)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, rows)
                try conn.executeMany("DELETE FROM movie_genre WHERE movie_id = ?", genreClears)
                try conn.executeMany("INSERT OR IGNORE INTO movie_genre (movie_id, genre) VALUES (?,?)", genreRows)
            }
        }
    }

    public func insertSeries(_ series: [Series], generation: Int = 1) async throws {
        let gen = Int64(generation)
        let rows = series.map { show -> [SQLiteValue] in
            let relevant = RelevanceFilter.isRelevant(
                countryCode: show.countryCode, name: show.title,
                category: show.genres.first?.displayName ?? "",
                audioLanguages: show.audioLanguages, subtitleLanguages: show.subtitleLanguages
            )
            return [
                .text(show.id.rawValue),
                .text(show.title),
                .text(show.title.foldedForSearch()),
                SQLiteValue(show.year),
                .text(CatalogValues.encode(show.audioLanguages)),
                .text(CatalogValues.encode(show.subtitleLanguages)),
                .text(CatalogValues.encode(show.genres)),
                .text(CatalogValues.encode(show.quality)),
                SQLiteValue(show.countryCode),
                SQLiteValue(show.posterURL),
                SQLiteValue(show.backdropURL),
                SQLiteValue(show.synopsis),
                SQLiteValue(show.providerSeriesKey),
                SQLiteValue(date: show.addedAt),
                SQLiteValue(show.isAdult),
                SQLiteValue(relevant),
                SQLiteValue(show.collection),
                .integer(show.seasons.isEmpty ? 0 : 1),
                .integer(gen),
            ]
        }
        let genreClears = series.map { [SQLiteValue.text($0.id.rawValue)] }
        let genreRows = series.flatMap { show in
            show.genres.map { [SQLiteValue.text(show.id.rawValue), .text($0.rawValue)] }
        }
        let episodeRows = series.flatMap { $0.seasons.flatMap(\.episodes) }.map { Self.episodeRow($0, gen: gen) }

        try await write { conn in
            try conn.transaction {
                try conn.executeMany("""
                INSERT OR REPLACE INTO series
                (id, title, title_fold, year, audio_langs, sub_langs, genres, quality, country_code,
                 poster_url, backdrop_url, synopsis, provider_key, added_at, is_adult, is_relevant, collection,
                 seasons_loaded, gen)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, rows)
                try conn.executeMany("DELETE FROM series_genre WHERE series_id = ?", genreClears)
                try conn.executeMany("INSERT OR IGNORE INTO series_genre (series_id, genre) VALUES (?,?)", genreRows)
                try conn.executeMany("""
                INSERT OR REPLACE INTO episode
                (id, series_id, season, episode, title, overview, duration_min, still_url, stream_url, gen)
                VALUES (?,?,?,?,?,?,?,?,?,?)
                """, episodeRows)
            }
        }
    }

    /// Replace one series' episodes after an on-demand fetch (Xtream). Stamps them
    /// with the current committed generation so the next import doesn't sweep them.
    public func replaceSeasons(_ seasons: [Season], seriesID: CatalogID) async throws {
        let committedGen = Int64(await intMeta(MetaKey.importGeneration))
        let episodeRows = seasons.flatMap(\.episodes).map { Self.episodeRow($0, gen: committedGen) }
        try await write { conn -> Void in
            try conn.transaction { () -> Void in
                _ = try conn.run("DELETE FROM episode WHERE series_id = ?", [.text(seriesID.rawValue)])
                try conn.executeMany("""
                INSERT OR REPLACE INTO episode
                (id, series_id, season, episode, title, overview, duration_min, still_url, stream_url, gen)
                VALUES (?,?,?,?,?,?,?,?,?,?)
                """, episodeRows)
                _ = try conn.run("UPDATE series SET seasons_loaded = 1 WHERE id = ?", [.text(seriesID.rawValue)])
            }
        }
    }

    private static func episodeRow(_ episode: Episode, gen: Int64) -> [SQLiteValue] {
        [
            .text(episode.id.rawValue),
            .text(episode.seriesID.rawValue),
            .integer(Int64(episode.seasonNumber)),
            .integer(Int64(episode.episodeNumber)),
            .text(episode.title),
            SQLiteValue(episode.overview),
            SQLiteValue(episode.durationMinutes),
            SQLiteValue(episode.stillURL),
            .text(episode.streamURL.absoluteString),
            .integer(gen),
        ]
    }

    /// Insert an EPG batch, dropping anything outside `window` first so
    /// `epg_event` never scales with the size of the feed.
    public func insertEPG(_ events: [EPGEvent], window: DateInterval, generation: Int = 1) async throws {
        let gen = Int64(generation)
        let rows = events.compactMap { event -> [SQLiteValue]? in
            guard event.stop > window.start, event.start < window.end else { return nil }
            return [
                .text(event.channelEPGID),
                .text(event.title),
                SQLiteValue(event.subtitle),
                SQLiteValue(event.description),
                .real(event.start.timeIntervalSince1970),
                .real(event.stop.timeIntervalSince1970),
                SQLiteValue(event.category),
                .integer(gen),
            ]
        }
        try await write { conn in
            try conn.transaction {
                try conn.executeMany("""
                INSERT OR REPLACE INTO epg_event
                (channel_epg_id, title, subtitle, description, start_at, stop_at, category, gen)
                VALUES (?,?,?,?,?,?,?,?)
                """, rows)
            }
        }
    }

    /// End an import: delete every row an earlier generation left behind
    /// (provider-removed titles, aged-out EPG), then commit the new generation.
    /// Prune rows an earlier generation left behind — but only in the parts
    /// this import actually refreshed. A channels-only refresh must not delete
    /// every film because the films weren't re-stamped.
    public func finishGeneration(_ generation: Int, parts: ImportParts = .all) async throws {
        let gen = Int64(generation)
        var tables: [String] = []
        if parts.contains(.channels) { tables.append("channel") }
        if parts.contains(.vod) { tables += ["movie", "series", "episode"] }
        if parts.contains(.guide) { tables.append("epg_event") }
        try await write { conn -> Void in
            try conn.transaction { () -> Void in
                for table in tables {
                    _ = try conn.run("DELETE FROM \(table) WHERE gen <> ?", [.integer(gen)])
                }
                _ = try conn.run("DELETE FROM movie_genre WHERE movie_id NOT IN (SELECT id FROM movie)")
                _ = try conn.run("DELETE FROM series_genre WHERE series_id NOT IN (SELECT id FROM series)")
            }
        }
        try await setMeta(MetaKey.importGeneration, String(generation))
    }

    // MARK: - Dynamic query state (columns, not app state)

    public func updateRegionPriorities(homeRegions: Set<String>) async throws {
        try await write { conn in
            let rows = try conn.query("SELECT id, country_code FROM channel") { ($0.string(0), $0.stringOrNil(1)) }
            let updates = rows.map { id, country in
                [SQLiteValue.integer(Int64(RelevanceFilter.priority(countryCode: country, home: homeRegions))), .text(id)]
            }
            try conn.transaction {
                try conn.executeMany("UPDATE channel SET region_priority = ? WHERE id = ?", updates)
            }
        }
    }

    public func updateRecentChannels(_ ids: [CatalogID]) async throws {
        try await write { conn in
            try conn.transaction {
                try conn.execute("UPDATE channel SET recent_rank = NULL WHERE recent_rank IS NOT NULL")
                let updates = ids.enumerated().map { index, id in
                    [SQLiteValue.integer(Int64(index)), .text(id.rawValue)]
                }
                try conn.executeMany("UPDATE channel SET recent_rank = ? WHERE id = ?", updates)
            }
        }
    }

    // MARK: - Maintenance

    /// Reclaim pages and refresh planner stats after a big import.
    public func optimize() async throws {
        try await write { conn in
            // Fresh planner statistics after every import. Without them SQLite
            // guesses at selectivity and can pick an index that sorts the whole
            // library instead of the one that walks it in order. The limit keeps
            // this to a sampled pass (milliseconds), not a full scan.
            try conn.execute("PRAGMA analysis_limit = 400")
            try conn.execute("ANALYZE")
            try conn.execute("PRAGMA optimize")
            try conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }
}
