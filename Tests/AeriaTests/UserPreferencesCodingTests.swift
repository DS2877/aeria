import XCTest
@testable import Aeria

final class UserPreferencesCodingTests: XCTestCase {

    func testRoundTrip() throws {
        var prefs = UserPreferences()
        prefs.preferredAudioLanguages = [.english, .swedish]
        prefs.preferredSubtitleLanguage = .swedish
        prefs.hideAdultContent = false
        prefs.homeRows = [.continueWatching, .movies]
        prefs.autoPlayNextEpisode = false
        prefs.aiAssistedSearch = true
        prefs.hasOnboarded = true

        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(UserPreferences.self, from: data)
        XCTAssertEqual(decoded, prefs)
    }

    func testMissingKeysFallBackToDefaults() throws {
        // Simulates an older stored payload that predates several fields.
        let legacy = """
        { "hideAdultContent": false, "hasOnboarded": true }
        """
        let decoded = try JSONDecoder().decode(UserPreferences.self, from: Data(legacy.utf8))

        XCTAssertFalse(decoded.hideAdultContent)          // from JSON
        XCTAssertTrue(decoded.hasOnboarded)               // from JSON
        XCTAssertTrue(decoded.autoPlayNextEpisode)        // default
        XCTAssertFalse(decoded.aiAssistedSearch)          // default
        XCTAssertEqual(decoded.defaultSort, .recentlyAdded)          // default
        XCTAssertEqual(decoded.homeRows, HomeRowKind.defaultEnabled) // default
        XCTAssertTrue(decoded.preferredAudioLanguages.isEmpty)       // default
    }

    func testEmptyObjectDecodesToDefaults() throws {
        let decoded = try JSONDecoder().decode(UserPreferences.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, UserPreferences())
    }
}
