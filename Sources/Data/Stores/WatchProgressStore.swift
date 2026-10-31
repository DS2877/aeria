import Foundation
import Observation

/// Tracks where the user left off in movies and episodes.
///
/// M2: persisted as JSON in `UserDefaults` — small, no dependency, survives
/// relaunch. M1/M-persistence will move this into the database alongside the
/// catalog. The API here won't change.
@MainActor
@Observable
public final class WatchProgressStore {

    private var byID: [String: WatchProgress] = [:]
    private let defaults: UserDefaults
    private let storageKey = "watchProgress.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - Reads

    public func progress(for id: CatalogID) -> WatchProgress? {
        byID[id.rawValue]
    }

    public func fraction(for id: CatalogID) -> Double {
        byID[id.rawValue]?.fraction ?? 0
    }

    /// Items with meaningful, unfinished progress, most recently watched first.
    public func continueWatching(limit: Int = 20) -> [WatchProgress] {
        byID.values
            .filter { $0.isResumable }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(limit)
            .map { $0 }
    }

    /// Every stored progress entry — order unspecified. For `UpNext` and history.
    public func allEntries() -> [WatchProgress] { Array(byID.values) }

    /// Bumped on every write. Screens key their reload on this rather than
    /// re-querying whenever they reappear.
    ///
    /// Deliberately a *stored* counter, not a hash computed on read: SwiftUI
    /// evaluates a `task(id:)` key on every redraw, and hashing the whole
    /// dictionary there would put an O(entries) walk in the render path.
    public private(set) var revision = 0

    /// Everything the user has actually started or finished, most recent first.
    /// Momentary taps (< 30s, not finished) are treated as noise and excluded.
    public func history(limit: Int = 200) -> [WatchProgress] {
        byID.values
            .filter { $0.positionSeconds > 30 || $0.isFinished }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Writes

    public func record(
        id: CatalogID,
        kind: ContentKind,
        positionSeconds: Double,
        durationSeconds: Double
    ) {
        guard durationSeconds > 0, positionSeconds >= 0 else { return }
        let progress = WatchProgress(
            itemID: id,
            kind: kind,
            positionSeconds: positionSeconds,
            durationSeconds: durationSeconds,
            updatedAt: .now
        )
        byID[id.rawValue] = progress
        save()
    }

    public func clear(id: CatalogID) {
        byID[id.rawValue] = nil
        save(immediately: true)
    }

    /// Wipe all watch history (Settings / History → Clear).
    public func clearAll() {
        byID.removeAll()
        save(immediately: true)
    }

    // MARK: - Persistence

    private var writeTask: Task<Void, Never>?

    private func load() {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([WatchProgress].self, from: data)
        else { return }
        byID = Dictionary(uniqueKeysWithValues: decoded.map { ($0.itemID.rawValue, $0) })
    }

    /// In-memory state and `revision` update at once; the encode + write is
    /// coalesced. Playback reports a position every 10 seconds, and encoding the
    /// whole history to `UserDefaults` on each of those is real work during the
    /// one moment the device is busiest. A destructive edit writes immediately.
    private func save(immediately: Bool = false) {
        revision &+= 1
        writeTask?.cancel()
        guard !immediately else { writeTask = nil; flush(); return }
        writeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Write any coalesced change now. Call when the app leaves the
    /// foreground — a suspended app may never run the 2 s debounce.
    public func flush() {
        let list = Array(byID.values)
        guard let data = try? JSONEncoder().encode(list) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
