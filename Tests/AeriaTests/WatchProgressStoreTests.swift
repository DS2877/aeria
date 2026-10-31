import XCTest
@testable import Aeria

@MainActor
final class WatchProgressStoreTests: XCTestCase {

    private func store() -> WatchProgressStore {
        WatchProgressStore(defaults: UserDefaults(suiteName: "wp-\(UUID().uuidString)")!)
    }

    private func id(_ s: String) -> CatalogID { CatalogID(rawValue: s) }

    func testResumableEntryShowsInContinueWatching() {
        let s = store()
        s.record(id: id("movie:a"), kind: .movie, positionSeconds: 600, durationSeconds: 6000)
        XCTAssertEqual(s.continueWatching().map(\.itemID), [id("movie:a")])
    }

    /// What `AppEnvironment.markWatched` does: record position == duration.
    func testMarkWatchedDropsItFromContinueWatching() {
        let s = store()
        s.record(id: id("movie:a"), kind: .movie, positionSeconds: 600, durationSeconds: 6000)
        XCTAssertFalse(s.continueWatching().isEmpty)

        s.record(id: id("movie:a"), kind: .movie, positionSeconds: 6000, durationSeconds: 6000)
        XCTAssertTrue(s.progress(for: id("movie:a"))?.isFinished ?? false)
        XCTAssertTrue(s.continueWatching().isEmpty)
    }

    /// What `AppEnvironment.removeFromContinueWatching` does.
    func testClearRemovesTheEntryEntirely() {
        let s = store()
        s.record(id: id("ep:1"), kind: .series, positionSeconds: 600, durationSeconds: 6000)
        s.clear(id: id("ep:1"))
        XCTAssertNil(s.progress(for: id("ep:1")))
        XCTAssertTrue(s.continueWatching().isEmpty)
    }

    func testSurvivesReload() {
        let suite = "wp-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let a = WatchProgressStore(defaults: defaults)
        a.record(id: id("movie:x"), kind: .movie, positionSeconds: 1200, durationSeconds: 6000)
        a.flush()   // writes are coalesced; the app flushes on backgrounding

        let b = WatchProgressStore(defaults: defaults)
        XCTAssertEqual(b.fraction(for: id("movie:x")), 0.2, accuracy: 0.001)
    }
}
