import XCTest
@testable import Aeria

final class RelevanceFilterTests: XCTestCase {

    private func keep(
        _ code: String?, _ name: String = "", _ category: String = "",
        audio: [Language] = [], subs: [Language] = []
    ) -> Bool {
        RelevanceFilter.isRelevant(countryCode: code, name: name, category: category,
                                   audioLanguages: audio, subtitleLanguages: subs)
    }

    func testKeepsSwedishMarketCountryCodes() {
        for c in ["SE", "NO", "DK", "GB", "IE", "US", "CA", "AU", "NZ"] {
            XCTAssertTrue(keep(c), "\(c) should be kept")
        }
    }

    func testDropsEverythingOutsideTheSwedishMarket() {
        // Finland, Iceland and continental Europe are out too — the app is for
        // the typical Swedish viewer.
        for c in ["FI", "IS", "DE", "FR", "PL", "RO", "GR", "HR",
                  "AR", "TR", "IN", "SA", "BR", "RU", "CN", "NG", "SO", "IR", "PK"] {
            XCTAssertFalse(keep(c), "\(c) should be dropped")
        }
    }

    func testUnderstoodAudioOrSwedishSubtitlesKeepsItWhereverItsFrom() {
        XCTAssertTrue(keep("RU", "Kino", "Movies", audio: [.swedish]))
        XCTAssertTrue(keep("TR", "Kanal D", "Series", audio: [.english]))
        XCTAssertTrue(keep("KR", "Squid Game", "Series", subs: [.swedish]))
        XCTAssertTrue(keep("DE", "Dark", "Series", audio: [.danish]))
        // English subtitles alone no longer do — that let foreign series through.
        XCTAssertFalse(keep("SA", "MBC Persia", "Movies", subs: [.english]))
        XCTAssertFalse(keep("SA", "MBC 1", "News", audio: [.arabic]))
    }

    func testForeignSectionsAreOutEvenWithSwedishSubtitles() {
        // Providers stamp "MULTI SUB" on whole foreign sections.
        XCTAssertFalse(keep(nil, "MBC 2", "Arabic Movies", subs: [.swedish]))
        XCTAssertFalse(keep(nil, "Some Film", "Turkish Series", subs: [.swedish]))
    }

    func testForeignScriptTitlesAreDropped() {
        XCTAssertFalse(keep(nil, "مسلسل الحب", "Series", audio: [.english]))
        XCTAssertFalse(keep(nil, "Первый канал", "General"))
        XCTAssertFalse(keep(nil, "東京物語", "Movies", subs: [.swedish]))
        // Latin with diacritics is fine.
        XCTAssertTrue(keep(nil, "Amélie", "Movies"))
        XCTAssertTrue(keep("SE", "Så som i himmelen", "Movies"))
    }

    func testUnknownCountryIsKeptWhenNoForeignMarker() {
        XCTAssertTrue(keep(nil, "beIN Sports 1 HD", "Sports"))
        XCTAssertTrue(keep(nil, "24/7 Friends", "Entertainment"))
        XCTAssertTrue(keep(nil, "Discovery Channel", "Documentary"))
    }

    func testUnknownCountryIsDroppedOnAForeignMarker() {
        XCTAssertFalse(keep(nil, "MBC Masr", "News"))
        XCTAssertFalse(keep(nil, "Zee TV", "Bollywood"))
        XCTAssertFalse(keep(nil, "OSN Yahala", "Arabic Movies"))
        XCTAssertFalse(keep(nil, "Perviy Kanal", "Russian"))
        XCTAssertFalse(keep(nil, "Somali National TV", "Africa"))
        // Continental-European sections are out for the Swedish market.
        XCTAssertFalse(keep(nil, "TVP Polska", "Polish"))
        XCTAssertFalse(keep(nil, "Das Erste", "German"))
        XCTAssertFalse(keep(nil, "RTS 1", "Ex-Yu"))
    }

    func testForeignWordsInATitleNeedNoEvidenceOfUnderstoodAudio() {
        // "Russian Doll" is an English series — the word alone isn't enough
        // when the audio is known to be English…
        XCTAssertTrue(keep(nil, "Russian Doll", "Series", audio: [.english]))
        // …but a European-language *title* word never drops anything.
        XCTAssertTrue(keep(nil, "The French Dispatch", "Movies"))
        XCTAssertTrue(keep(nil, "German Shepherd Rescue", "Documentary"))
    }

    func testWholeWordMatchingAvoidsFalsePositives() {
        // "india" must not match inside "Indiana"
        XCTAssertTrue(keep(nil, "Indiana Jones Marathon", "Movies"))
        // "iran" must not match "Pirates"
        XCTAssertTrue(keep(nil, "Pirates of the Caribbean", "Movies"))
    }

    func testForeignSectionDetection() {
        for section in ["Arabic Movies", "TR | Turkish Series", "Polish VOD", "Ex-Yu", "Hindi",
                        "Deutschland | Filme", "أفلام عربية"] {
            XCTAssertTrue(RelevanceFilter.isForeignSection(section), "\(section) should be foreign")
        }
        for section in ["Movies | Horror", "SE | Barn", "Netflix Series", "UK | Sports", nil] {
            XCTAssertFalse(RelevanceFilter.isForeignSection(section), "\(section ?? "nil") should be kept")
        }
    }

    func testPriorityRanksHomeThenNordicThenEuropeThenRest() {
        let home: Set<String> = ["SE"]
        XCTAssertEqual(RelevanceFilter.priority(countryCode: "SE", home: home), 0)
        XCTAssertEqual(RelevanceFilter.priority(countryCode: "NO", home: home), 1)
        XCTAssertEqual(RelevanceFilter.priority(countryCode: "GB", home: home), 2)
        XCTAssertEqual(RelevanceFilter.priority(countryCode: "DE", home: home), 2)
        XCTAssertEqual(RelevanceFilter.priority(countryCode: nil,  home: home), 2)
        XCTAssertEqual(RelevanceFilter.priority(countryCode: "SA", home: home), 3)
    }

    func testHomeRegionsFromLanguages() {
        XCTAssertEqual(RelevanceFilter.homeRegions(for: []), ["SE"])
        XCTAssertEqual(RelevanceFilter.homeRegions(for: [.swedish]), ["SE"])
        XCTAssertEqual(RelevanceFilter.homeRegions(for: [.norwegian, .danish]), ["NO", "DK"])
    }

    func testChannelCountryCodesByScope() {
        let home: Set<String> = ["SE"]
        XCTAssertEqual(RelevanceFilter.channelCountryCodes(for: .homeCountry, home: home), ["SE"])
        XCTAssertEqual(RelevanceFilter.channelCountryCodes(for: .nordic, home: home),
                       ["SE", "NO", "DK", "FI", "IS"])
        XCTAssertTrue(RelevanceFilter.channelCountryCodes(for: .european, home: home)?.contains("DE") ?? false)
        XCTAssertNil(RelevanceFilter.channelCountryCodes(for: .all, home: home))
    }

    @MainActor
    func testChannelRegionScopeFiltersLiveTV() async {
        let repo = InMemoryCatalogRepository()
        let url = URL(string: "https://x/s")!
        func ch(_ id: String, _ name: String, _ code: String?) -> Channel {
            Channel(id: .init(rawValue: id), name: name, category: "General",
                    countryCode: code, streamURL: url)
        }
        await repo.load(Catalog(channels: [
            ch("se1", "SVT1", "SE"), ch("no1", "NRK1", "NO"),
            ch("de1", "Das Erste", "DE"), ch("gen", "24/7 Nature", nil),
        ]))
        await repo.setHomeRegions(["SE"])

        await repo.setChannelRegionScope(.homeCountry)
        var names = Set(await repo.channels(in: nil, sort: .nameAsc, page: 0, pageSize: 50).map(\.name))
        XCTAssertEqual(names, ["SVT1", "24/7 Nature"])   // home country + generic feeds

        await repo.setChannelRegionScope(.nordic)
        names = Set(await repo.channels(in: nil, sort: .nameAsc, page: 0, pageSize: 50).map(\.name))
        XCTAssertEqual(names, ["SVT1", "NRK1", "24/7 Nature"])

        await repo.setChannelRegionScope(.all)
        let all = await repo.channels(in: nil, sort: .nameAsc, page: 0, pageSize: 50)
        XCTAssertEqual(all.count, 4)
    }

    @MainActor
    func testChannelSortPutsHomeCountryAndRegularsFirst() async {
        let repo = InMemoryCatalogRepository()
        let url = URL(string: "https://x/s")!
        func ch(_ id: String, _ name: String, _ code: String?, num: Int) -> Channel {
            Channel(id: .init(rawValue: id), name: name, category: "General",
                    countryCode: code, streamURL: url, sortIndex: num)
        }
        await repo.load(Catalog(channels: [
            ch("gb1", "BBC One", "GB", num: 1),
            ch("se2", "SVT2", "SE", num: 2),
            ch("no1", "NRK1", "NO", num: 1),
            ch("se1", "SVT1", "SE", num: 1),
        ]))
        await repo.setHomeRegions(["SE"])

        var order = await repo.channels(in: nil, sort: .number, page: 0, pageSize: 10).map(\.name)
        XCTAssertEqual(order, ["SVT1", "SVT2", "NRK1", "BBC One"])

        // Watching BBC One floats it to the very top.
        await repo.setRecentChannels([.init(rawValue: "gb1")])
        order = await repo.channels(in: nil, sort: .number, page: 0, pageSize: 10).map(\.name)
        XCTAssertEqual(order.first, "BBC One")
    }

    @MainActor
    func testRepositoryAppliesTheFilter() async {
        let repo = InMemoryCatalogRepository()
        let url = URL(string: "https://x/s")!
        await repo.load(Catalog(channels: [
            Channel(id: .init(rawValue: "c1"), name: "SVT1", category: "General",
                    countryCode: "SE", streamURL: url),
            Channel(id: .init(rawValue: "c2"), name: "MBC 1", category: "General",
                    countryCode: "SA", streamURL: url),
        ]))

        var all = await repo.channels(in: nil, sort: .number, page: 0, pageSize: 50)
        XCTAssertEqual(all.map(\.name), ["SVT1", "MBC 1"])

        await repo.setRegionLimit(true)
        all = await repo.channels(in: nil, sort: .number, page: 0, pageSize: 50)
        XCTAssertEqual(all.map(\.name), ["SVT1"])
    }
}
