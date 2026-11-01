import XCTest
@testable import Aeria

/// Category browsing: provider sections become tidy collections, and the store
/// lists and filters by them.
final class CategoryBrowsingTests: XCTestCase {

    func testProviderSectionsBecomeCollections() {
        XCTAssertEqual(CategoryMapper.vodCollection(from: "SE | Netflix Filmer"), "Netflix Filmer")
        XCTAssertEqual(CategoryMapper.vodCollection(from: "[SE] Barnfilm"), "Barnfilm")
        XCTAssertEqual(CategoryMapper.vodCollection(from: "SE | NORDIC | Viaplay"), "Viaplay")
        XCTAssertEqual(CategoryMapper.vodCollection(from: "NETFLIX SERIER"), "Netflix Serier")
        XCTAssertEqual(CategoryMapper.vodCollection(from: "HBO MAX"), "HBO MAX")
        XCTAssertEqual(CategoryMapper.vodCollection(from: "Movies | Horror"), nil, "a genre is already a genre tile")
        XCTAssertNil(CategoryMapper.vodCollection(from: "SE | Filmer"), "catch-all section")
        XCTAssertNil(CategoryMapper.vodCollection(from: "VOD"))
        XCTAssertNil(CategoryMapper.vodCollection(from: nil))
    }

    func testStoreListsAndFiltersCollections() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cat-\(UUID()).sqlite3")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
            }
        }
        let database = try CatalogDatabase(path: url)
        let stream = URL(string: "https://example.test/s")!
        var movies: [Movie] = []
        for i in 0..<5 {
            movies.append(Movie(id: .init(rawValue: "n\(i)"), title: "Netflix \(i)", genres: [.drama],
                                streamURL: stream, collection: "Netflix"))
        }
        for i in 0..<2 {
            movies.append(Movie(id: .init(rawValue: "v\(i)"), title: "Viaplay \(i)", genres: [.comedy],
                                streamURL: stream, collection: "Viaplay"))
        }
        try await database.insertMovies(movies)

        let collections = try await database.collections(series: false, .unfiltered)
        XCTAssertEqual(collections.map(\.title), ["Netflix"], "Viaplay has under four titles")
        XCTAssertEqual(collections.first?.count, 5)

        let genres = try await database.genreCategories(series: false, .unfiltered)
        XCTAssertEqual(genres.map(\.title), [Genre.drama.displayName, Genre.comedy.displayName])

        var filter = CatalogFilter.none
        filter.collections = ["Viaplay"]
        let count = try await database.movieCount(filter, .unfiltered)
        XCTAssertEqual(count, 2)
    }
}
