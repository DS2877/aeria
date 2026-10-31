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

    // MARK: - Harness

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
