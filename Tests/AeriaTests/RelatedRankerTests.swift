import XCTest
@testable import Aeria

final class RelatedRankerTests: XCTestCase {

    private func item(_ id: String, _ title: String, genres: [Genre], year: Int,
                      people: Set<String> = [], poster: Bool = true) -> RelatedRanker.Item {
        RelatedRanker.Item(id: .init(rawValue: id), title: title, genres: genres, year: year,
                           people: people, audio: [.swedish], hasPoster: poster)
    }

    func testRowIsVariedNotJustTheSameMix() {
        let source = item("src", "Source", genres: [.drama, .crime], year: 2015, people: ["actor a"])
        // 20 identical-looking 2023 dramas + a crime drama from 2012 with the same actor
        // + a 1990s crime drama.
        var pool = (0..<20).map { item("d\($0)", "Drama \($0)", genres: [.drama, .crime], year: 2023) }
        pool.append(item("star", "Same Actor", genres: [.crime, .drama], year: 2012, people: ["actor a"]))
        pool.append(item("old", "Nineties", genres: [.crime, .drama], year: 1996))
        let row = RelatedRanker.rank(source: source, candidates: pool, ratings: [:], limit: 8)
        XCTAssertEqual(row.first?.rawValue, "star", "shared cast + close in time leads")
        XCTAssertTrue(row.map(\.rawValue).contains("old"), "another decade makes the row")
        XCTAssertEqual(row.count, 8)
    }

    func testSkipsDuplicatesWeakAndPosterless() {
        let source = item("src", "Heat", genres: [.crime], year: 1995)
        let pool = [
            item("dup", "Heat", genres: [.crime], year: 1995),                 // another version
            item("weak", "Weak", genres: [.crime], year: 1995),
            item("noart", "No Art", genres: [.crime], year: 1995, poster: false),
            item("good", "Good", genres: [.crime], year: 1994),
        ]
        let row = RelatedRanker.rank(source: source, candidates: pool, ratings: ["weak": 4.0], limit: 3)
        XCTAssertFalse(row.map(\.rawValue).contains("dup"))
        XCTAssertEqual(row.first?.rawValue, "good")
        XCTAssertEqual(row.last?.rawValue, "noart", "posterless sinks to the end")
    }
}
