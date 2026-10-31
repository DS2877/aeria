import Foundation
import Observation

/// Dependency container + top-level app state. Injected once at the root via
/// `.environment(...)` and read with `@Environment(AppEnvironment.self)`.
@MainActor
@Observable
public final class AppEnvironment {

    public enum LoadState: Equatable {
        case idle
        case loading
        case ready
        case failed(ProviderError)
    }

    // Dependencies
    public let database: CatalogDatabase
    public let repository: SQLiteCatalogRepository
    public let searchEngine: SearchEngine
    public let aiService: AIService
    public let watchProgress: WatchProgressStore
    public let channelHistory: ChannelHistoryStore
    public let favorites: FavoritesStore
    public let providers: ProviderStore
    public let preferences: PreferencesStore
    public let parental: ParentalControlsStore
    public let metadata = MetadataService()
    public let network = NetworkMonitor()
    private let normalizer: Normalizer
    private var provider: (any ProviderClient)?
    private var refreshTask: Task<Void, Never>?

    /// How old a cached catalog can be before we silently refresh it on launch.
    private let staleAfter: TimeInterval = 60 * 60 * 6

    /// True while a background library refresh is running (cache was shown first).
    public private(set) var isRefreshing = false

    // State
    public private(set) var loadState: LoadState = .idle
    public private(set) var vocabulary: SearchVocabulary = .init()
    /// Phases the current/most-recent import has reached — drives the
    /// "Preparing your library" checklist.
    public private(set) var reachedPhases: Set<ImportPhase> = []
    /// True once a catalog has loaded at least once this session.
    public private(set) var hasLoadedOnce = false
    /// False while the EPG (and, on a cold start, the full VOD set) is still
    /// loading in the background after the app became interactive.
    public private(set) var catalogComplete = false
    /// Bumps every time the background load finishes — views observe it to refresh.
    public private(set) var catalogRevision = 0
    /// Bumps as the background TMDB sweep lands batches of ratings/artwork.
    /// Only Home observes this (for the "Top Rated" row).
    public private(set) var metadataRevision = 0

    /// Set when a deep link (Top Shelf) needs a detail screen shown over the app.
    public var pendingRoute: AppRoute?

    private var topShelfWriteTask: Task<Void, Never>?

    public var activeProvider: ProviderDescriptor? {
        providers.activeConfiguration?.descriptor
    }

    /// True when there's no provider configured yet — the UI shows onboarding.
    public var needsProviderSetup: Bool { !providers.hasAnyProvider }

    public init() {
        self.database = CatalogDatabase.open()
        self.searchEngine = SearchEngine()
        self.repository = SQLiteCatalogRepository(database: self.database, searchEngine: self.searchEngine)
        self.aiService = AIService(mode: .onDeviceOnly)
        self.watchProgress = WatchProgressStore()
        self.channelHistory = ChannelHistoryStore()
        self.favorites = FavoritesStore()
        self.providers = ProviderStore()
        self.preferences = PreferencesStore()
        self.parental = ParentalControlsStore()
        self.normalizer = Normalizer()
        #if DEBUG
        if Self.isScreenshotRun {
            // Straight into the demo library on Home, past onboarding.
            providers.setActive(ProviderStore.demoID)
            preferences.completeOnboarding()
            UserDefaults.standard.removeObject(forKey: "sidebar.lastSection.v1")
        }
        #endif
    }

    #if DEBUG
    /// Launched by the CI screenshot test (`-AeriaScreenshots`).
    static var isScreenshotRun: Bool {
        ProcessInfo.processInfo.arguments.contains("-AeriaScreenshots")
    }

    /// Give the demo library some history and ratings so every Home row
    /// (Continue Watching, Top 10, Because You Watched) shows in screenshots.
    private func seedScreenshotState() async {
        let movies = await repository.newestMovies(limit: 12)
        for (i, movie) in movies.prefix(3).enumerated() {
            let duration = Double((movie.durationMinutes ?? 110) * 60)
            watchProgress.record(id: movie.id, kind: .movie,
                                 positionSeconds: duration * [0.35, 0.62, 0.18][i],
                                 durationSeconds: duration)
        }
        let series = await repository.newestSeries(limit: 8)
        var ratings: [CatalogID: Double] = [:]
        for (i, movie) in movies.enumerated() { ratings[movie.id] = 8.9 - Double(i) * 0.15 }
        for (i, show) in series.enumerated() { ratings[show.id] = 8.4 - Double(i) * 0.2 }
        await metadata.debugSeedRatings(ratings)
        metadataRevision += 1
    }
    #endif

    /// Keychain accounts for the optional API keys.
    static let aiKeyAccount = "anthropic.apiKey.v1"
    static let tmdbKeyAccount = "tmdb.apiKey.v1"

    /// Push the current preferences into the parts of the app that need them.
    /// Call after a load and whenever preferences change.
    ///
    /// `bumpRevision` nudges every feature screen to re-query — right after a
    /// user toggles a filter, yes; on the launch fast path, no (nothing changed
    /// and an extra `catalogRevision` bump there costs a full Home rebuild).
    public func applyPreferences(bumpRevision: Bool = true) async {
        let prefs = preferences.preferences
        await repository.setHideAdult(prefs.hideAdultContent)
        await repository.setRegionLimit(prefs.limitToRelevantRegions)
        await repository.setHomeRegions(RelevanceFilter.homeRegions(for: prefs.preferredAudioLanguages))
        await repository.setChannelRegionScope(prefs.channelRegionScope)
        await repository.setRecentChannels(channelHistory.recent())
        await aiService.setMode(prefs.aiAssistedSearch ? .assisted : .onDeviceOnly)

        let aiKey = KeychainStore.get(Self.aiKeyAccount) ?? ""
        await aiService.setRemoteParser(aiKey.isEmpty ? nil : ClaudeQueryParser(apiKey: aiKey))
        await metadata.setKey(effectiveTMDBKey)

        // A toggle (adult / region) may have re-filtered the catalog — nudge the
        // feature screens to re-query.
        if bumpRevision, hasLoadedOnce { catalogRevision += 1 }
    }

    /// A key entered in Settings wins; otherwise the bundled default.
    private var effectiveTMDBKey: String {
        let custom = (KeychainStore.get(Self.tmdbKeyAccount) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? TMDBDefaults.readAccessToken : custom
    }

    public func setTMDBKey(_ key: String) async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { KeychainStore.delete(Self.tmdbKeyAccount) }
        else { KeychainStore.set(trimmed, for: Self.tmdbKeyAccount) }
        await metadata.setKey(effectiveTMDBKey)
    }

    /// True when a *custom* key is set (the default always works regardless).
    public var hasTMDBKey: Bool {
        !(KeychainStore.get(Self.tmdbKeyAccount) ?? "").isEmpty
    }

    /// Store or clear the AI-assisted-search API key, then re-wire the parser.
    public func setAIKey(_ key: String) async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainStore.delete(Self.aiKeyAccount)
        } else {
            KeychainStore.set(trimmed, for: Self.aiKeyAccount)
        }
        await applyPreferences()
    }

    public var hasAIKey: Bool {
        !(KeychainStore.get(Self.aiKeyAccount) ?? "").isEmpty
    }

    public static func live() -> AppEnvironment { AppEnvironment() }

    /// App launch. Only the TMDB key is wired before the catalog check — Home
    /// paints its cached snapshot on the very first frame and its cards ask
    /// TMDB for missing posters right away, so the key must already be set.
    /// Everything else in `applyPreferences` (AI key, recent channels, region
    /// rewrite) runs behind the first frame on the fast path, or before going
    /// interactive on a cold import — both inside `bootstrap`.
    public func startUp() async {
        await metadata.setKey(effectiveTMDBKey)
        await bootstrap()
        #if DEBUG
        if Self.isScreenshotRun { await seedScreenshotState() }
        #endif
    }

    /// Load the active provider's catalog. If a completed import is already in
    /// the SQLite store, the app is interactive immediately and a stale copy is
    /// refreshed in the background. Otherwise the import is streamed in — the app
    /// goes interactive the moment the channel list lands, and movies / series /
    /// guide fill in behind it, none of it ever fully resident in memory.
    public func bootstrap(forceReload: Bool = false) async {
        if case .loading = loadState { return }
        if case .ready = loadState, !forceReload { return }

        guard let config = providers.activeConfiguration,
              let client = providers.makeClient(for: config) else {
            loadState = .idle
            return
        }
        provider = client
        let providerID = config.id
        let homeRegions = RelevanceFilter.homeRegions(for: preferences.preferences.preferredAudioLanguages)

        // Fast path: a completed import for this provider is already on disk.
        // Nothing here may block the first frame — flip the app ready, then do
        // the rest (vocabulary, Top Shelf, staleness check) in the background.
        if !forceReload, await database.isReady(providerID: providerID) {
            // Only the two scope flags gate what the first queries return, and
            // they're just in-memory booleans on the repository actor — set them
            // now, flip the app interactive, and run the rest of
            // `applyPreferences` (the region-priority rewrite, recent channels,
            // API keys) behind the first frame.
            await repository.setHideAdult(preferences.preferences.hideAdultContent)
            await repository.setRegionLimit(preferences.preferences.limitToRelevantRegions)
            await repository.setHomeRegions(RelevanceFilter.homeRegions(for: preferences.preferences.preferredAudioLanguages))
            await repository.setChannelRegionScope(preferences.preferences.channelRegionScope)
            loadState = .ready
            hasLoadedOnce = true
            catalogComplete = true
            reachedPhases = Set(ImportPhase.allCases)
            catalogRevision += 1
            AppLog.app.info("Catalog already on disk — ready without an import.")

            Task { [weak self] in
                guard let self else { return }
                await self.applyPreferences(bumpRevision: false)
                self.vocabulary = await self.repository.searchVocabulary()
                self.startMetadataWarmUp()
                await self.writeTopShelfSnapshot()

                let age = await self.database.importedAt().map { Date().timeIntervalSince($0) } ?? .infinity
                if age > self.staleAfter {
                    self.startBackgroundRefresh(client: client, providerID: providerID, homeRegions: homeRegions)
                }
            }
            return
        }

        // Cold import — stream it into the store.
        reachedPhases = []
        catalogComplete = false
        loadState = .loading
        let reporter = ImportProgressReporter { [weak self] phase in
            Task { @MainActor in self?.markPhase(phase) }
        }
        let freshImport = !(await database.isReady(providerID: providerID))
        let writer = CatalogWriter(database: database, normalizer: normalizer,
                                   providerID: providerID, homeRegions: homeRegions)
        do {
            let importStart = Date()
            try await writer.begin(fresh: freshImport)

            try await client.fetchStaged(progress: reporter) { [weak self] stage in
                await self?.handleImportStage(stage, providerID: providerID, writer: writer)
            }
            guard providers.activeConfiguration?.id == providerID else { return }

            try await writer.finish()
            markPhase(.finalizing)
            catalogComplete = true
            catalogRevision += 1
            if loadState != .ready {
                await applyPreferences()
                loadState = .ready
                hasLoadedOnce = true
            }
            vocabulary = await repository.searchVocabulary()

            let elapsed = String(format: "%.1f", Date().timeIntervalSince(importStart))
            AppLog.app.info("Catalog imported to SQLite in \(elapsed)s.")
            startMetadataWarmUp()
            await writeTopShelfSnapshot()
        } catch {
            if loadState == .ready {
                catalogComplete = true
                AppLog.provider.notice("Import failed after going interactive; keeping the partial catalog.")
            } else {
                let providerError = ProviderError.from(error)
                loadState = .failed(providerError)
                AppLog.provider.error("Bootstrap failed: \(String(describing: providerError))")
            }
        }
    }

    /// Normalise + write one staged slice, then flip the app interactive on the
    /// first content stage and nudge the feature screens to re-query. `@MainActor`
    /// so it can touch published state; the heavy work is on the writer actor.
    private func handleImportStage(_ stage: RawStage, providerID: String, writer: CatalogWriter) async {
        guard providers.activeConfiguration?.id == providerID else { return }
        do { try await writer.ingest(stage) }
        catch { AppLog.provider.error("Import stage failed: \(String(describing: error))") }

        switch stage {
        case .channels, .vod:
            if loadState != .ready {
                await applyPreferences()
                loadState = .ready
                hasLoadedOnce = true
            }
        case .guide:
            break
        }
        catalogRevision += 1
    }

    /// Manually re-pull the active provider's library (Settings → Refresh).
    public func refreshLibrary() async {
        guard let client = provider, let providerID = providers.activeConfiguration?.id else { return }
        let homeRegions = RelevanceFilter.homeRegions(for: preferences.preferences.preferredAudioLanguages)
        startBackgroundRefresh(client: client, providerID: providerID, homeRegions: homeRegions)
        await refreshTask?.value
    }

    /// Re-import in the background, updating rows in place so nothing on screen
    /// goes blank while it runs.
    private func startBackgroundRefresh(client: any ProviderClient, providerID: String, homeRegions: Set<String>) {
        guard refreshTask == nil else { return }
        isRefreshing = true
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer { self.refreshTask = nil; self.isRefreshing = false }
            let writer = CatalogWriter(database: self.database, normalizer: self.normalizer,
                                       providerID: providerID, homeRegions: homeRegions)
            do {
                try await writer.begin(fresh: false)
                try await client.fetchStaged(progress: .ignore) { stage in
                    try? await writer.ingest(stage)
                }
                guard !Task.isCancelled,
                      self.providers.activeConfiguration?.id == providerID else { return }
                try await writer.finish()
                await self.applyPreferences()
                self.vocabulary = await self.repository.searchVocabulary()
                self.catalogRevision += 1
                AppLog.app.info("Catalog refreshed in the background.")
            } catch {
                AppLog.provider.notice("Background refresh failed; keeping the existing catalog.")
            }
        }
    }

    /// Kick off a background TMDB sweep so posters and ratings fill in without
    /// the user having to scroll. Rate-limited inside `MetadataService`.
    private func startMetadataWarmUp() {
        Task { [weak self] in
            guard let self else { return }
            guard await self.metadata.isEnabled else { return }
            let seeds = await self.repository.artworkSeeds(movieLimit: 600, seriesLimit: 250)
            await self.metadata.warmUp(seeds) {
                Task { @MainActor [weak self] in self?.metadataRevision += 1 }
            }
        }
    }

    private func markPhase(_ phase: ImportPhase) {
        let order = ImportPhase.allCases
        guard let idx = order.firstIndex(of: phase) else { return }
        reachedPhases.formUnion(order.prefix(idx + 1))
    }

    /// Make `config` active and load its catalog. The store keeps one provider's
    /// catalog at a time; switching triggers a fresh import (which wipes first).
    public func activate(_ config: ProviderConfiguration) async {
        refreshTask?.cancel()
        refreshTask = nil
        await metadata.cancelWarmUp()
        HomeSnapshotStore.clear()   // the cached screen belongs to the old library
        providers.setActive(config.id)
        loadState = .idle
        hasLoadedOnce = false
        catalogComplete = false
        reachedPhases = []
        await bootstrap(forceReload: false)
    }

    /// Remove a provider; wipe the catalog store if it was the loaded one.
    public func removeProvider(_ id: String) async {
        let wasLoaded = await database.loadedProviderID() == id
        providers.remove(id)
        if wasLoaded || !providers.hasAnyProvider {
            HomeSnapshotStore.clear()
            try? await database.clearCatalog()
            try? await database.setMeta(CatalogDatabase.MetaKey.providerID, nil)
            try? await database.setMeta(CatalogDatabase.MetaKey.importComplete, "0")
        }
        if !providers.hasAnyProvider {
            loadState = .idle
            hasLoadedOnce = false
        }
    }

    /// Load episodes for a series that was imported as a shell (Xtream).
    public func ensureEpisodes(forSeries id: CatalogID) async -> Series? {
        guard var series = await repository.series(id: id) else { return nil }
        if series.hasEpisodes { return series }
        guard let key = series.providerSeriesKey, let client = provider,
              let providerID = providers.activeConfiguration?.id else { return series }
        do {
            let rawEpisodes = try await client.fetchEpisodes(seriesKey: key)
            let normalizer = self.normalizer
            let seasons = await Task.detached(priority: .userInitiated) {
                normalizer.seasons(forEpisodes: rawEpisodes, seriesID: id, providerID: providerID)
            }.value
            await repository.attachSeasons(seasons, toSeriesID: id)
            series.seasons = seasons
            return series
        } catch {
            AppLog.provider.error("Episode load failed: \(String(describing: ProviderError.from(error)))")
            return series
        }
    }

    public func setAIMode(_ mode: AIService.Mode) async {
        await aiService.setMode(mode)
    }

    // MARK: - Playback

    /// Build a `PlaybackItem` for a movie, applying any saved resume position.
    /// `fromStart` ignores the resume point so the viewer can restart the film.
    public func playback(forMovie id: CatalogID, fromStart: Bool = false) async -> PlaybackItem? {
        guard let movie = await repository.movie(id: id) else { return nil }
        let resume = fromStart ? nil : watchProgress.progress(for: id)
        return PlaybackItem(
            id: movie.id,
            kind: .movie,
            url: movie.streamURL,
            title: movie.title,
            subtitle: [movie.year.map(String.init), movie.genres.first?.displayName]
                .compactMap { $0 }.joined(separator: " · "),
            isLive: false,
            resumeAt: resume?.isResumable == true ? resume?.positionSeconds : nil,
            durationSeconds: movie.durationMinutes.map { Double($0 * 60) }
        )
    }

    public func playback(forEpisode episode: Episode, seriesTitle: String) -> PlaybackItem {
        let resume = watchProgress.progress(for: episode.id)
        return PlaybackItem(
            id: episode.id,
            kind: .series,
            url: episode.streamURL,
            title: seriesTitle,
            subtitle: "\(episode.code) · \(episode.title)",
            isLive: false,
            resumeAt: resume?.isResumable == true ? resume?.positionSeconds : nil,
            durationSeconds: episode.durationMinutes.map { Double($0 * 60) }
        )
    }

    public func playback(forChannel id: CatalogID) async -> PlaybackItem? {
        guard let channel = await repository.channel(id: id) else { return nil }
        recordChannelView(channel.id)
        return PlaybackItem(
            id: channel.id,
            kind: .liveChannel,
            url: channel.streamURL,
            title: channel.name,
            subtitle: channel.category,
            isLive: true
        )
    }

    public func recordProgress(id: CatalogID, kind: ContentKind, position: Double, duration: Double) {
        watchProgress.record(id: id, kind: kind, positionSeconds: position, durationSeconds: duration)
        scheduleTopShelfWrite()
    }

    /// Called when live playback of a channel starts — feeds the "your regulars
    /// first" ordering in Live TV and the Home "Live Now" row.
    public func recordChannelView(_ id: CatalogID) {
        channelHistory.record(id)
        Task {
            await repository.setRecentChannels(channelHistory.recent())
            catalogRevision += 1
        }
    }

    /// "Mark as Watched" from a Continue Watching card — records a finished entry
    /// so the item drops out (a series advances to its next episode).
    public func markWatched(id: CatalogID, kind: ContentKind) {
        let duration = watchProgress.progress(for: id)?.durationSeconds ?? 1
        watchProgress.record(id: id, kind: kind, positionSeconds: duration, durationSeconds: duration)
        Task { await writeTopShelfSnapshot() }
    }

    /// "Remove" from a Continue Watching card.
    public func removeFromContinueWatching(id: CatalogID) {
        watchProgress.clear(id: id)
        Task { await writeTopShelfSnapshot() }
    }

    /// Clear an item's resume point / watched flag entirely.
    public func markUnwatched(id: CatalogID) {
        watchProgress.clear(id: id)
        Task { await writeTopShelfSnapshot() }
    }

    /// Mark a batch of episodes finished in one go (a whole season). Records
    /// them all, then writes the Top Shelf hand-off once.
    public func markEpisodesWatched(_ ids: [CatalogID]) {
        guard !ids.isEmpty else { return }
        for id in ids {
            let duration = watchProgress.progress(for: id)?.durationSeconds ?? 1
            watchProgress.record(id: id, kind: .series, positionSeconds: duration, durationSeconds: duration)
        }
        Task { await writeTopShelfSnapshot() }
    }

    /// Clear the resume point / watched flag for a batch of episodes at once.
    public func markEpisodesUnwatched(_ ids: [CatalogID]) {
        guard !ids.isEmpty else { return }
        ids.forEach { watchProgress.clear(id: $0) }
        Task { await writeTopShelfSnapshot() }
    }

    // MARK: - Deep links (Top Shelf)

    /// Handle an `aeria://…` URL opened from the Top Shelf. Shown as a cover over
    /// whatever screen is active.
    public func open(_ url: URL) {
        guard let route = AppRoute(deepLink: url) else {
            AppLog.app.notice("Ignored unrecognised deep link.")
            return
        }
        pendingRoute = route
    }

    public func clearPendingRoute() { pendingRoute = nil }

    // MARK: - Top Shelf snapshot

    /// Coalesced write of the Top Shelf hand-off (Continue Watching + Recently
    /// Added) to the shared App Group container.
    func scheduleTopShelfWrite() {
        topShelfWriteTask?.cancel()
        topShelfWriteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            await self?.writeTopShelfSnapshot()
        }
    }

    func writeTopShelfSnapshot() async {
        guard await repository.isReady() else { return }
        let progress = watchProgress.allEntries()

        let resume = await repository.resumePoints(progress: progress, limit: 12)
        var continueItems: [TopShelfPayload.Item] = []
        for point in resume {
            var image = point.artworkURL
            if image == nil {
                image = await metadata.metadata(for: point.containerID, title: point.primaryTitle,
                                                year: nil, isSeries: point.isSeries)?.posterURL
            }
            continueItems.append(.init(
                title: point.primaryTitle, subtitle: point.secondaryText, imageURL: image,
                routeKind: point.isSeries ? "series" : "movie", id: point.containerID.rawValue
            ))
        }

        let recentMovies = await repository.newestMovies(limit: 8)
        let recentSeries = await repository.newestSeries(limit: 4)
        var recentItems: [TopShelfPayload.Item] = []
        for movie in recentMovies {
            var image = movie.posterURL
            if image == nil {
                image = await metadata.metadata(for: movie.id, title: movie.title,
                                                year: movie.year, isSeries: false)?.posterURL
            }
            recentItems.append(.init(title: movie.title, subtitle: movie.year.map(String.init),
                                     imageURL: image, routeKind: "movie", id: movie.id.rawValue))
        }
        for series in recentSeries {
            var image = series.posterURL
            if image == nil {
                image = await metadata.metadata(for: series.id, title: series.title,
                                                year: series.year, isSeries: true)?.posterURL
            }
            recentItems.append(.init(title: series.title, subtitle: series.year.map(String.init),
                                     imageURL: image, routeKind: "series", id: series.id.rawValue))
        }

        let payload = TopShelfPayload(continueWatching: continueItems, recentlyAdded: recentItems)
        await Task.detached { TopShelfStore.save(payload) }.value
    }
}
