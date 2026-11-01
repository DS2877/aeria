import XCTest
@testable import Aeria

/// Surprise Me draws from what's worth watching, not the whole library.
@MainActor
final class SurpriseMeTests: XCTestCase {

    func testNeverPicksPoorlyRatedWatchedOrPosterless() async {
        let stream = URL(string: "https://example.test/s")!
        let poster = URL(string: "https://example.test/p.jpg")!
        func movie(_ id: String, poster p: URL? = poster) -> Movie {
            Movie(id: .init(rawValue: id), title: id, genres: [.drama], posterURL: p,
                  synopsis: "A story.", streamURL: stream, addedAt: Date())
        }
        let catalog = Catalog(movies: [
            movie("good"), movie("great"),
            movie("weak"),                      // TMDB 4.2
            movie("seen"),                      // already watched
            movie("noart", poster: nil),        // no poster
        ])
        let repo = InMemoryCatalogRepository(catalog: catalog, ready: true)
        let defaults = UserDefaults(suiteName: "surprise-\(UUID())")!
        let progress = WatchProgressStore(defaults: defaults)
        progress.record(id: .init(rawValue: "seen"), kind: .movie, positionSeconds: 3000, durationSeconds: 3600)
        let model = VODBrowseViewModel(kind: .movies, repository: repo, watchProgress: progress)

        let ratings = ["good": 7.1, "great": 8.4, "weak": 4.2]
        var picked = Set<String>()
        for _ in 0..<30 {
            if case .movie(let id)? = await model.surprisePick(ratings: ratings) { picked.insert(id.rawValue) }
        }
        XCTAssertTrue(picked.isSubset(of: ["good", "great"]), "picked \(picked)")
        XCTAssertFalse(picked.isEmpty)
    }
}
