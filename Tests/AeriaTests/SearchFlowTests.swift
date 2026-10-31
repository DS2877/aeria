import XCTest
@testable import Aeria

@MainActor
final class SearchFlowTests: XCTestCase {

    func testChipMappingCoversEveryConstraint() {
        var intent = SearchIntent()
        intent.kinds = [.movie]
        intent.genres = [.horror]
        intent.audioLanguages = [.english]
        intent.subtitleLanguages = [.swedish]
        intent.minYear = 2021
        intent.maxDurationMinutes = 120
        intent.minQuality = .uhd

        let chips = SearchViewModel.chips(for: intent)
        let labels = Set(chips.map(\.label))
        XCTAssertTrue(labels.contains("Movies"))
        XCTAssertTrue(labels.contains("Horror"))
        XCTAssertTrue(labels.contains("English audio"))
        XCTAssertTrue(labels.contains("Swedish subtitles"))
        XCTAssertTrue(labels.contains("After 2020"))
        XCTAssertTrue(labels.contains("Under 2h"))
        XCTAssertTrue(labels.contains("4K+"))
    }

    func testRemovingAChipClearsThatConstraint() throws {
        var intent = SearchIntent()
        intent.genres = [.horror, .comedy]
        let horrorChip = try XCTUnwrap(SearchViewModel.chips(for: intent).first { $0.label == "Horror" })

        var updated = intent
        horrorChip.remove(&updated)   // `remove` is internal; @testable exposes it
        XCTAssertEqual(updated.genres, [.comedy])
    }

    @MainActor
    func testEndToEndSearch() async {
        let catalog = Normalizer().normalize(MockCatalogData.rawCatalog())
        let repo = InMemoryCatalogRepository()
        await repo.load(catalog)
        let vm = SearchViewModel(repository: repo, engine: SearchEngine(),
                                 ai: AIService(mode: .onDeviceOnly))
        vm.query = "scary movies with swedish subtitles"
        await vm.search(vocabulary: .init())
        XCTAssertTrue(vm.hasSearched)
        XCTAssertFalse(vm.results.isEmpty)
        XCTAssertTrue(vm.results.allSatisfy { $0.kind == .movie })
        XCTAssertTrue(vm.chips.contains { $0.label == "Horror" })
    }
}
