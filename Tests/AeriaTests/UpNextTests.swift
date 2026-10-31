import XCTest
@testable import Aeria

final class UpNextTests: XCTestCase {

    private let streamURL = URL(string: "https://example.com/x.m3u8")!

    private func movie(_ key: String, title: String, minutes: Int? = 120) -> Movie {
        Movie(id: CatalogID(providerID: "p", kind: .movie, providerItemKey: key),
              title: title, durationMinutes: minutes, streamURL: streamURL)
    }

    private func series(_ key: String, title: String, episodesPerSeason: [Int]) -> Series {
        let seriesID = CatalogID(providerID: "p", kind: .series, providerItemKey: key)
        let seasons = episodesPerSeason.enumerated().map { (seasonIdx, count) -> Season in
            let number = seasonIdx + 1
            let episodes = (1...count).map { ep -> Episode in
                Episode(id: CatalogID(providerID: "p", kind: .series, providerItemKey: "\(key)-s\(number)e\(ep)"),
                        seriesID: seriesID, seasonNumber: number, episodeNumber: ep,
                        title: "Episode \(ep)", streamURL: streamURL)
            }
            return Season(seriesID: seriesID, number: number, episodes: episodes)
        }
        return Series(id: seriesID, title: title, seasons: seasons)
    }

    private func progress(_ id: CatalogID, kind: ContentKind, fraction: Double, at date: Date) -> WatchProgress {
        WatchProgress(itemID: id, kind: kind,
                      positionSeconds: 6000 * fraction, durationSeconds: 6000, updatedAt: date)
    }

    func testResumableMovieIsAPoint() {
        let m = movie("m1", title: "Sicario")
        let catalog = Catalog(movies: [m])
        let p = progress(m.id, kind: .movie, fraction: 0.4, at: .now)

        let points = UpNext.resumePoints(catalog: catalog, progress: [p])
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points.first?.kind, .resumeMovie)
        XCTAssertEqual(points.first?.containerID, m.id)
        XCTAssertEqual(points.first?.secondaryText, "1h 12m left") // 60% of 120m
    }

    func testFinishedMovieIsNotAPoint() {
        let m = movie("m1", title: "Sicario")
        let p = progress(m.id, kind: .movie, fraction: 0.98, at: .now)
        XCTAssertTrue(UpNext.resumePoints(catalog: Catalog(movies: [m]), progress: [p]).isEmpty)
    }

    func testInProgressEpisodeResumes() {
        let s = series("s1", title: "The Bear", episodesPerSeason: [3])
        let ep2 = s.seasons[0].episodes[1]
        let p = progress(ep2.id, kind: .series, fraction: 0.3, at: .now)

        let points = UpNext.resumePoints(catalog: Catalog(series: [s]), progress: [p])
        XCTAssertEqual(points.first?.kind, .resumeEpisode)
        XCTAssertEqual(points.first?.itemID, ep2.id)
        XCTAssertEqual(points.first?.containerID, s.id)
        XCTAssertEqual(points.first?.secondaryText, "S01E02 · Episode 2")
    }

    func testFinishedEpisodeAdvancesToNext() {
        let s = series("s1", title: "GoT", episodesPerSeason: [2, 2])
        let s1e2 = s.seasons[0].episodes[1]
        let s2e1 = s.seasons[1].episodes[0]
        let p = progress(s1e2.id, kind: .series, fraction: 1.0, at: .now)

        let points = UpNext.resumePoints(catalog: Catalog(series: [s]), progress: [p])
        XCTAssertEqual(points.first?.kind, .nextEpisode)
        XCTAssertEqual(points.first?.itemID, s2e1.id)
        XCTAssertEqual(points.first?.secondaryText, "Up Next · S02E01")
        XCTAssertEqual(points.first?.fraction, 0)
    }

    func testSeriesWithEveryEpisodeFinishedDropsOut() {
        let s = series("s1", title: "Chernobyl", episodesPerSeason: [2])
        let now = Date.now
        let all = s.seasons[0].episodes.enumerated().map {
            progress($1.id, kind: .series, fraction: 1.0, at: now.addingTimeInterval(Double($0)))
        }
        XCTAssertTrue(UpNext.resumePoints(catalog: Catalog(series: [s]), progress: all).isEmpty)
    }

    func testMostRecentActionPerSeriesWins() {
        let s = series("s1", title: "TLOU", episodesPerSeason: [3])
        let e1 = s.seasons[0].episodes[0]
        let e2 = s.seasons[0].episodes[1]
        let old = progress(e1.id, kind: .series, fraction: 0.5, at: .now.addingTimeInterval(-1000))
        let recent = progress(e2.id, kind: .series, fraction: 0.2, at: .now)

        let points = UpNext.resumePoints(catalog: Catalog(series: [s]), progress: [old, recent])
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points.first?.itemID, e2.id)
    }

    func testOrderedNewestFirstAndLimited() {
        let m1 = movie("m1", title: "A")
        let m2 = movie("m2", title: "B")
        let p1 = progress(m1.id, kind: .movie, fraction: 0.3, at: .now.addingTimeInterval(-500))
        let p2 = progress(m2.id, kind: .movie, fraction: 0.3, at: .now)

        let points = UpNext.resumePoints(catalog: Catalog(movies: [m1, m2]), progress: [p1, p2], limit: 1)
        XCTAssertEqual(points.map(\.containerID), [m2.id])
    }

    func testLiveChannelProgressIgnored() {
        let id = CatalogID(providerID: "p", kind: .liveChannel, providerItemKey: "c1")
        let p = progress(id, kind: .liveChannel, fraction: 0.5, at: .now)
        XCTAssertTrue(UpNext.resumePoints(catalog: Catalog(), progress: [p]).isEmpty)
    }
}
