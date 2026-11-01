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

/// Pure music (concerts, music videos) stays out of Movies but has its own
/// entry; a music documentary stays a film; search still finds a concert.
final class MusicSplitTests: XCTestCase {

    func testPureMusicIsSeparatedFromMovies() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("music-\(UUID()).sqlite3")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
            }
        }
        let database = try CatalogDatabase(path: url)
        let stream = URL(string: "https://example.test/s")!
        try await database.insertMovies([
            Movie(id: .init(rawValue: "film"), title: "A Film", genres: [.drama], streamURL: stream),
            Movie(id: .init(rawValue: "concert"), title: "Live at Wembley", genres: [.music], streamURL: stream),
            Movie(id: .init(rawValue: "mv"), title: "Hits 2024", genres: [.drama], streamURL: stream,
                  collection: "Music Videos"),
            Movie(id: .init(rawValue: "doc"), title: "Music Doc", genres: [.documentary, .music], streamURL: stream),
            Movie(id: .init(rawValue: "biopic"), title: "Biopic", genres: [.drama, .music], streamURL: stream),
        ])
        let browse = try await database.movies(.none, .unfiltered, page: 0, pageSize: 50)
        XCTAssertEqual(Set(browse.map(\.id.rawValue)), ["film", "doc", "biopic"])

        var music = CatalogFilter.none
        music.music = .only
        let only = try await database.movies(music, .unfiltered, page: 0, pageSize: 50)
        XCTAssertEqual(Set(only.map(\.id.rawValue)), ["concert", "mv"])
        let count = try await database.musicCount(series: false, .unfiltered)
        XCTAssertEqual(count, 2)

        var search = CatalogFilter.none
        search.music = .included
        search.text = "wembley"
        let found = try await database.movieCandidates(search, .unfiltered, limit: 10)
        XCTAssertEqual(found.map(\.id.rawValue), ["concert"])
    }
}
