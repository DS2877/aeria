import XCTest
@testable import Aeria

final class TopShelfPayloadTests: XCTestCase {

    func testRoundTrips() throws {
        let payload = TopShelfPayload(
            continueWatching: [
                .init(title: "Dune", subtitle: "1h 12m left",
                      imageURL: URL(string: "https://img/dune.jpg"),
                      routeKind: "movie", id: "movie:abc123"),
            ],
            recentlyAdded: [
                .init(title: "The Bear", subtitle: "2024", imageURL: nil,
                      routeKind: "series", id: "series:def456"),
            ]
        )

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(TopShelfPayload.self, from: data)
        XCTAssertEqual(decoded.continueWatching, payload.continueWatching)
        XCTAssertEqual(decoded.recentlyAdded, payload.recentlyAdded)
    }

    func testDeepLinkEncodesTheId() throws {
        let item = TopShelfPayload.Item(title: "Dune", subtitle: nil, imageURL: nil,
                                        routeKind: "movie", id: "movie:abc123")
        let link = try XCTUnwrap(item.deepLink)
        XCTAssertEqual(link.scheme, "aeria")
        // ':' must be percent-encoded so the path is unambiguous.
        XCTAssertTrue(link.absoluteString.contains("movie%3Aabc123"))
    }

    func testDeepLinkParsesBackToRoute() {
        let item = TopShelfPayload.Item(title: "The Bear", subtitle: nil, imageURL: nil,
                                        routeKind: "series", id: "series:def456")
        let route = try? XCTUnwrap(AppRoute(deepLink: item.deepLink!))
        XCTAssertEqual(route, .series(CatalogID(rawValue: "series:def456")))
    }

    func testUnknownSchemeIsRejected() {
        XCTAssertNil(AppRoute(deepLink: URL(string: "https://example.com/movie/x")!))
        XCTAssertNil(AppRoute(deepLink: URL(string: "aeria://unknown/x")!))
    }
}
