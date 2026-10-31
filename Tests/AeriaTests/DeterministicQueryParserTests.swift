import XCTest
@testable import Aeria

final class DeterministicQueryParserTests: XCTestCase {

    private let parser = DeterministicQueryParser()

    private func parse(_ q: String) -> SearchIntent {
        parser.parseSync(q)
    }

    // MARK: - Swedish queries

    func testSwedishHorrorWithSwedishSubtitles() {
        let intent = parse("skräckfilm med svenska undertexter")
        XCTAssertEqual(intent.genres, [.horror])
        XCTAssertEqual(intent.subtitleLanguages, [.swedish])
        XCTAssertTrue(intent.freeText.isEmpty, "got free text \(intent.freeText)")
    }

    func testSwedishComedyUnderTwoHours() {
        let intent = parse("en rolig film under 2 timmar")
        XCTAssertEqual(intent.kinds, [.movie])
        XCTAssertEqual(intent.genres, [.comedy])
        XCTAssertEqual(intent.maxDurationMinutes, 120)
        XCTAssertTrue(intent.freeText.isEmpty, "got free text \(intent.freeText)")
    }

    func testSwedishSeriesAfterYear() {
        let intent = parse("engelska serier efter 2015")
        XCTAssertEqual(intent.kinds, [.series])
        XCTAssertEqual(intent.audioLanguages, [.english])
        XCTAssertEqual(intent.minYear, 2016)
    }

    func testSwedishDecadeAndKids() {
        let intent = parse("barnfilmer från 90-talet")
        XCTAssertEqual(intent.genres, [.kids])
        XCTAssertEqual(intent.minYear, 1990)
        XCTAssertEqual(intent.maxYear, 1999)
    }

    func testSwedishOneWordSubtitles() {
        let intent = parse("svensktextad deckare")
        XCTAssertEqual(intent.subtitleLanguages, [.swedish])
        XCTAssertEqual(intent.genres, [.crime])
    }

    func testSwedishTitleKeepsItsWords() {
        // A plain title search stays a title search.
        let intent = parse("Bron")
        XCTAssertEqual(intent.freeText, "bron")
        XCTAssertTrue(intent.genres.isEmpty)
    }

    func testHorrorMovieWithSwedishSubtitles() {
        let intent = parse("Find a scary movie with Swedish subtitles")
        XCTAssertEqual(intent.kinds, [.movie])
        XCTAssertEqual(intent.genres, [.horror])
        XCTAssertEqual(intent.subtitleLanguages, [.swedish])
        XCTAssertTrue(intent.audioLanguages.isEmpty)
        XCTAssertTrue(intent.freeText.isEmpty)
    }

    func testEnglishHorrorMoviesWithSwedishSubtitles() {
        let intent = parse("English horror movies with Swedish subtitles")
        XCTAssertEqual(intent.kinds, [.movie])
        XCTAssertEqual(intent.genres, [.horror])
        XCTAssertEqual(intent.audioLanguages, [.english])
        XCTAssertEqual(intent.subtitleLanguages, [.swedish])
    }

    func testEnglishSeriesAfter2020() {
        let intent = parse("Show me English series with Swedish subtitles released after 2020")
        XCTAssertEqual(intent.kinds, [.series])
        XCTAssertEqual(intent.audioLanguages, [.english])
        XCTAssertEqual(intent.subtitleLanguages, [.swedish])
        XCTAssertEqual(intent.minYear, 2021)
        XCTAssertNil(intent.maxYear)
    }

    func testDurationUnderTwoHoursTonight() {
        let intent = parse("What can I watch tonight that's under two hours")
        XCTAssertEqual(intent.maxDurationMinutes, 120)
        XCTAssertEqual(intent.timeContext, .tonight)
    }

    func testDurationNinetyMinutes() {
        XCTAssertEqual(parse("something under 90 minutes").maxDurationMinutes, 90)
        XCTAssertEqual(parse("less than 1h30").maxDurationMinutes, 90)
    }

    func testSomethingLikeGameOfThrones() {
        let intent = parse("Something like Game of Thrones")
        XCTAssertTrue(intent.kinds.isEmpty)
        XCTAssertTrue(intent.genres.isEmpty)
        XCTAssertEqual(intent.freeText, "game of thrones")
    }

    func testMoodSynonymsMapToGenres() {
        XCTAssertEqual(parse("something funny").genres, [.comedy])
        XCTAssertEqual(parse("a spooky film").genres, [.horror])
        XCTAssertTrue(parse("epic fantasy with dragons").genres.contains(.fantasy))
    }

    func testDecade() {
        let intent = parse("action movies from the 1980s")
        XCTAssertEqual(intent.minYear, 1980)
        XCTAssertEqual(intent.maxYear, 1989)
        XCTAssertEqual(intent.genres, [.action])
    }

    func testQualityConstraint() {
        XCTAssertEqual(parse("4k movies").minQuality, .uhd)
    }

    func testEmptyQuery() {
        XCTAssertEqual(parse("   "), .empty)
    }

    func testSortHint() {
        XCTAssertEqual(parse("newest sci-fi series").sort, .newest)
    }

    func testDeterministicAcrossRuns() {
        let a = parse("scary english movies with swedish subs under 2 hours")
        let b = parse("scary english movies with swedish subs under 2 hours")
        XCTAssertEqual(a, b)
    }
}
