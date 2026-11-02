import XCTest
@testable import Aeria

/// The category-first import against a fake Xtream panel: only Swedish-market
/// categories are downloaded, and a panel that ignores `category_id` falls back
/// to the single bulk request (never the full list once per category).
final class XtreamCategoryImportTests: XCTestCase {

    override func tearDown() {
        FakePanel.reset()
        super.tearDown()
    }

    func testOnlySwedishMarketCategoriesAreDownloaded() async throws {
        FakePanel.reset()
        let movies = try await importMovies()
        XCTAssertEqual(Set(movies.map(\.name)), ["Svensk Film", "English Film"])
        let vodRequests = FakePanel.requests.filter { $0.contains("action=get_vod_streams") }
        XCTAssertFalse(vodRequests.contains { !$0.contains("category_id=") }, "no bulk VOD request")
        XCTAssertFalse(vodRequests.contains { $0.contains("category_id=3") }, "Arabic section skipped")
        XCTAssertFalse(vodRequests.contains { $0.contains("category_id=4") }, "Turkish section skipped")
    }

    func testPanelIgnoringCategoryFilterFallsBackToBulk() async throws {
        FakePanel.reset()
        FakePanel.ignoresCategoryFilter = true
        let movies = try await importMovies()
        // Every item exactly once — from the bulk list, not once per category.
        XCTAssertEqual(movies.count, FakePanel.vod.count)
        XCTAssertTrue(FakePanel.requests.contains { $0.contains("action=get_vod_streams") && !$0.contains("category_id=") })
    }

    /// Two-tier guide: now/next for the kept channels arrives right after the
    /// channels — before films — and foreign channels get no preview.
    func testGuidePreviewArrivesBeforeTheFilms() async throws {
        FakePanel.reset()
        let config = ProviderConfiguration(kind: .xtream, displayName: "Fake",
                                           xtreamHost: "http://fake.panel", xtreamUsername: "u")
        let http = HTTPClient(protocolClasses: [FakePanel.self])
        let client = try XCTUnwrap(XtreamProviderClient(configuration: config, password: "p", http: http))
        let order = StageLog()
        try await client.fetchStaged(progress: .ignore) { stage in
            await order.note(stage)
        }
        let names = await order.names
        XCTAssertEqual(names, ["channels", "guidePreview", "vod", "guide"])
        let preview = await order.preview
        XCTAssertEqual(Set(preview.map(\.title)), ["Rapport"])
        XCTAssertEqual(Set(preview.map(\.channelID)), ["svt1.se"])
        XCTAssertFalse(FakePanel.requests.contains { $0.contains("get_short_epg") && $0.contains("stream_id=102") },
                       "no preview for the foreign channel")
    }

    /// Descriptions come per title (get_vod_info / get_series_info) — and a
    /// panel answering `"info": []` must not throw.
    func testFetchesTitleDetails() async throws {
        FakePanel.reset()
        let config = ProviderConfiguration(kind: .xtream, displayName: "Fake",
                                           xtreamHost: "http://fake.panel", xtreamUsername: "u")
        let http = HTTPClient(protocolClasses: [FakePanel.self])
        let client = try XCTUnwrap(XtreamProviderClient(configuration: config, password: "p", http: http))

        let movie = try await client.fetchDetails(.movie(streamURL: URL(string: "http://fake.panel/movie/u/p/1.mp4")!))
        XCTAssertEqual(movie?.plot, "A Swedish film.")
        XCTAssertEqual(movie?.cast, ["Alicia Vikander", "Mikael Persbrandt"])
        XCTAssertEqual(movie?.backdropURL?.absoluteString, "http://img.test/b.jpg")
        XCTAssertTrue(FakePanel.requests.contains { $0.contains("action=get_vod_info") && $0.contains("vod_id=1") })

        let series = try await client.fetchDetails(.series(key: "7"))
        XCTAssertNil(series, "\"info\": [] means no details, not an error")
    }

    func testShortEPGTitlesAreBase64Decoded() {
        XCTAssertEqual(XtreamProviderClient.decodeBase64("UmFwcG9ydA=="), "Rapport")
        XCTAssertEqual(XtreamProviderClient.decodeBase64("Plain title"), "Plain title")
    }

    func testXMLTVChannelFilterSkipsOtherChannels() throws {
        let now = Date()
        func stamp(_ d: Date) -> String {
            let f = DateFormatter(); f.dateFormat = "yyyyMMddHHmmss Z"
            f.locale = Locale(identifier: "en_US_POSIX"); return f.string(from: d)
        }
        let xml = """
        <tv>
        <programme channel="svt1.se" start="\(stamp(now))" stop="\(stamp(now.addingTimeInterval(1800)))"><title>Rapport</title></programme>
        <programme channel="aljazeera" start="\(stamp(now))" stop="\(stamp(now.addingTimeInterval(1800)))"><title>News</title></programme>
        </tv>
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("filter-\(UUID()).xml")
        try Data(xml.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let events = try XMLTVParser.parse(fileURL: url, within: EPGWindow.current(), channels: ["svt1.se"])
        XCTAssertEqual(events.map(\.title), ["Rapport"])
    }

    // MARK: - Harness

    private actor StageLog {
        var names: [String] = []
        var preview: [RawEPGEvent] = []
        func note(_ stage: RawStage) {
            switch stage {
            case .channels: names.append("channels")
            case .vod: names.append("vod")
            case .guide: names.append("guide")
            case .guidePreview(let events): names.append("guidePreview"); preview = events
            }
        }
    }

    private func importMovies() async throws -> [RawVODItem] {
        let config = ProviderConfiguration(kind: .xtream, displayName: "Fake",
                                           xtreamHost: "http://fake.panel", xtreamUsername: "u")
        let http = HTTPClient(protocolClasses: [FakePanel.self])
        let client = try XCTUnwrap(XtreamProviderClient(configuration: config, password: "p", http: http))
        let collected = Collected()
        try await client.fetchStaged(progress: .ignore) { stage in
            if case .vod(let movies, _, _) = stage { await collected.set(movies) }
        }
        return await collected.movies
    }

    private actor Collected {
        var movies: [RawVODItem] = []
        func set(_ m: [RawVODItem]) { movies = m }
    }
}

/// A tiny Xtream panel. VOD categories: 1 Swedish, 2 English, 3 Arabic,
/// 4 Turkish — two of four foreign, so per-category fetching pays.
final class FakePanel: URLProtocol {
    nonisolated(unsafe) static var requests: [String] = []
    nonisolated(unsafe) static var ignoresCategoryFilter = false
    private static let lock = NSLock()

    static let vod: [(id: Int, name: String, cat: String)] = [
        (1, "Svensk Film", "1"), (2, "English Film", "2"),
        (3, "Arabic Film", "3"), (4, "Turkish Film", "4"),
    ]

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        requests = []
        ignoresCategoryFilter = false
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "fake.panel"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        Self.lock.lock()
        Self.requests.append(url.absoluteString)
        let ignores = Self.ignoresCategoryFilter
        Self.lock.unlock()

        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let action = items.first { $0.name == "action" }?.value
        let category = items.first { $0.name == "category_id" }?.value

        let body: String
        switch action {
        case nil:
            body = #"{"user_info":{"auth":1,"status":"Active"}}"#
        case "get_vod_categories":
            body = #"[{"category_id":"1","category_name":"SE | Filmer"},{"category_id":"2","category_name":"EN | Movies"},{"category_id":"3","category_name":"Arabic Movies"},{"category_id":"4","category_name":"Turkish Movies"}]"#
        case "get_live_categories":
            body = #"[{"category_id":"10","category_name":"SE | Kanaler"},{"category_id":"11","category_name":"Arabic TV"}]"#
        case "get_live_streams":
            let live = [(101, "SVT1", "10", "svt1.se"), (102, "Al Jazeera", "11", "aljazeera")]
                .filter { category == nil || ignores || $0.2 == category }
            body = "[" + live.map {
                #"{"stream_id":\#($0.0),"name":"\#($0.1)","category_id":"\#($0.2)","epg_channel_id":"\#($0.3)","num":\#($0.0)}"#
            }.joined(separator: ",") + "]"
        case "get_vod_info":
            body = #"{"info":{"plot":"A Swedish film.","cast":"Alicia Vikander, Mikael Persbrandt","director":"","backdrop_path":["http://img.test/b.jpg"]},"movie_data":{}}"#
        case "get_series_info":
            body = #"{"info":[],"episodes":{}}"#
        case "get_short_epg":
            let start = Int(Date().timeIntervalSince1970) - 600
            body = #"{"epg_listings":[{"title":"UmFwcG9ydA==","description":"","start_timestamp":"\#(start)","stop_timestamp":"\#(start + 1800)"}]}"#
        case "get_vod_streams":
            let wanted = Self.vod.filter { category == nil || ignores || $0.cat == category }
            body = "[" + wanted.map {
                #"{"stream_id":\#($0.id),"name":"\#($0.name)","category_id":"\#($0.cat)","container_extension":"mp4"}"#
            }.joined(separator: ",") + "]"
        default:
            body = "[]"   // live, series, categories for those
        }
        let data = url.path.hasSuffix("xmltv.php") ? Data("<tv></tv>".utf8) : Data(body.utf8)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
