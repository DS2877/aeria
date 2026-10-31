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
        XCTAssertTrue(labels.contains("Filmer"))
        XCTAssertTrue(labels.contains("Skräck"))
        XCTAssertTrue(labels.contains("Tal: Engelska"))
        XCTAssertTrue(labels.contains("Text: Svenska"))
        XCTAssertTrue(labels.contains("Efter 2020"))
        XCTAssertTrue(labels.contains("Under 2 tim"))
        XCTAssertTrue(labels.contains("4K+"))
    }

    func testRemovingAChipClearsThatConstraint() throws {
        var intent = SearchIntent()
        intent.genres = [.horror, .comedy]
        let horrorChip = try XCTUnwrap(SearchViewModel.chips(for: intent).first { $0.label == "Skräck" })

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
        XCTAssertTrue(vm.chips.contains { $0.label == "Skräck" })
    }

    @MainActor
    func testPlainChannelNameFindsTheChannel() async {
        let repo = InMemoryCatalogRepository()
        await repo.load(Normalizer().normalize(MockCatalogData.rawCatalog()))
        let vm = SearchViewModel(repository: repo, engine: SearchEngine(),
                                 ai: AIService(mode: .onDeviceOnly))
        vm.query = "svt1"
        await vm.liveSearch(vocabulary: .init())
        XCTAssertTrue(vm.channels.contains { $0.name == "SVT1" },
                      "channels: \(vm.channels.map(\.name))")
    }

    @MainActor
    func testGuideProgrammesAreSearchable() async {
        let catalog = Normalizer().normalize(MockCatalogData.rawCatalog())
        let repo = InMemoryCatalogRepository()
        await repo.load(catalog)
        let now = Date()
        let channelEPGIDs = Set(catalog.channels.compactMap(\.epgID))
        guard let event = catalog.epg.first(where: {
            $0.stop > now && $0.start < now.addingTimeInterval(20 * 3600) && channelEPGIDs.contains($0.channelEPGID)
        }) else {
            return XCTFail("mock guide has nothing upcoming")
        }
        let hits = await repo.searchProgrammes(text: event.title.lowercased(), limit: 20)
        XCTAssertTrue(hits.contains { $0.event.title == event.title })
    }

    func testProgrammeMatchIgnoresDiacriticsAndWordOrder() {
        XCTAssertTrue(ProgrammeHit.matches("På spåret", query: "pa sparet"))
        XCTAssertTrue(ProgrammeHit.matches("Gomorron Sverige", query: "sverige gomorron"))
        XCTAssertFalse(ProgrammeHit.matches("Rapport", query: "aktuellt"))
    }
}
