import Foundation
import Observation

/// Keeps each section's view model alive for the life of the app.
///
/// `SidebarShell` renders its content with a `switch`, so SwiftUI tears the old
/// screen down and builds a new one every time the selection changes — and the
/// sidebar is *focus-driven*, so simply scrolling from Home to History destroys
/// and rebuilds seven screens on the way past. With the models owned by the
/// views, every one of those rebuilds re-ran the queries.
///
/// Holding them here means a section you've already visited comes back with its
/// data already in hand: switching sections is instant, and moving through the
/// sidebar costs nothing.
///
/// Models are created lazily on first visit, so an unopened section costs
/// nothing either.
@MainActor
@Observable
public final class SectionModels {

    private var homeModel: HomeViewModel?
    private var liveTVModel: LiveTVBrowseViewModel?
    private var moviesModel: VODBrowseViewModel?
    private var seriesModel: VODBrowseViewModel?
    private var guideModel: GuideViewModel?
    private var searchModel: SearchViewModel?

    /// The `catalogRevision` each section's data was loaded at. Visiting a
    /// screen early in an import and coming back after it finished must not
    /// leave you looking at the partial library it saw the first time.
    private var loadedRevision: [String: Int] = [:]

    /// Bumped by `reset()`. The section views hold a `@State` *handle* on their
    /// model, which would otherwise keep pointing at the discarded instance
    /// after a provider switch — they key their setup task on this so the
    /// handle is re-fetched.
    public private(set) var generation = 0

    public init() {}

    /// `true` when this section has never loaded, or loaded against an older
    /// catalog than the one on disk now.
    func needsLoad(_ key: SectionKey, revision: Int) -> Bool {
        loadedRevision[key.rawValue] != revision
    }

    /// Record that this section just loaded against `revision`.
    func markLoaded(_ key: SectionKey, revision: Int) {
        loadedRevision[key.rawValue] = revision
    }

    public enum SectionKey: String {
        case home, liveTV, movies, series, guide
    }

    func home(_ env: AppEnvironment) -> HomeViewModel {
        if let homeModel { return homeModel }
        let model = HomeViewModel(
            repository: env.repository,
            watchProgress: env.watchProgress,
            preferences: env.preferences,
            metadata: env.metadata,
            channelHistory: env.channelHistory,
            favorites: env.favorites
        )
        if let providerID = env.activeProvider?.id { model.restoreSnapshot(providerID: providerID) }
        homeModel = model
        return model
    }

    func liveTV(_ env: AppEnvironment) -> LiveTVBrowseViewModel {
        if let liveTVModel { return liveTVModel }
        let model = LiveTVBrowseViewModel(repository: env.repository, favorites: env.favorites)
        liveTVModel = model
        return model
    }

    func vod(_ kind: BrowseKind, _ env: AppEnvironment) -> VODBrowseViewModel {
        switch kind {
        case .movies:
            if let moviesModel { return moviesModel }
            let model = makeVOD(kind, env)
            moviesModel = model
            return model
        case .series:
            if let seriesModel { return seriesModel }
            let model = makeVOD(kind, env)
            seriesModel = model
            return model
        }
    }

    private func makeVOD(_ kind: BrowseKind, _ env: AppEnvironment) -> VODBrowseViewModel {
        let model = VODBrowseViewModel(kind: kind, repository: env.repository,
                                       watchProgress: env.watchProgress)
        // Earlier builds saved "Recently Added" as everyone's default; For
        // You replaces it. A deliberately chosen A–Z / year sort is kept.
        let saved = env.preferences.preferences.defaultSort
        model.filter.sort = saved == .recentlyAdded ? .forYou : saved
        model.forYouProvider = { [weak env] in await env?.forYouProfile() ?? ForYouProfile() }
        return model
    }

    func guide(_ env: AppEnvironment) -> GuideViewModel {
        if let guideModel { return guideModel }
        let model = GuideViewModel(repository: env.repository)
        guideModel = model
        return model
    }

    func search(_ env: AppEnvironment) -> SearchViewModel {
        if let searchModel { return searchModel }
        let model = SearchViewModel(repository: env.repository, engine: env.searchEngine, ai: env.aiService)
        searchModel = model
        return model
    }

    /// Drop everything — the library underneath these models is gone
    /// (provider switched or removed).
    public func reset() {
        // No-op when there's nothing to drop, so the generation only moves when
        // views actually need to re-fetch their handles.
        guard homeModel != nil || liveTVModel != nil || moviesModel != nil
            || seriesModel != nil || guideModel != nil || searchModel != nil
            || !loadedRevision.isEmpty else { return }
        homeModel = nil
        liveTVModel = nil
        moviesModel = nil
        seriesModel = nil
        guideModel = nil
        searchModel = nil
        loadedRevision.removeAll()
        generation += 1
    }
}
