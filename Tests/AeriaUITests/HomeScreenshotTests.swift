import XCTest

/// Walks Home in the demo library and attaches a screenshot at each stop. Run
/// by CI so the design can be reviewed without a device; asserts nothing
/// beyond the app launching.
final class HomeScreenshotTests: XCTestCase {

    override func setUp() {
        continueAfterFailure = true
    }

    func testCaptureHome() {
        let app = XCUIApplication()
        app.launchArguments += ["-AeriaScreenshots"]
        app.launch()

        // Cold demo import + first Home build + seeded history/ratings. Launch
        // focus lands on the hero's Play button, so ↓ walks the shelves.
        sleep(12)
        snap("01-home-hero")

        let remote = XCUIRemote.shared
        let stops = ["02-row-1", "03-row-2", "04-row-3", "05-row-4", "06-row-5", "07-row-6"]
        for name in stops {
            remote.press(.down)
            sleep(2)
            snap(name)
        }

        // Back to the top (focus should be on the hero again), then the rail.
        for _ in stops { remote.press(.up) }
        sleep(2)
        snap("08-back-to-hero")

        // Hero → More Info → the detail screen, then back.
        remote.press(.right)
        sleep(1)
        remote.press(.select)
        sleep(4)
        snap("10-movie-detail")
        remote.press(.down)
        sleep(2)
        snap("11-movie-detail-lower")
        remote.press(.menu)
        sleep(3)

        // Into the rail — should land on Home, not the item level with focus.
        remote.press(.left)
        remote.press(.left)
        sleep(2)
        snap("09-sidebar")

        // Walk the sections down the rail (focus-driven: each one shows).
        let sections = ["12-search", "13-live-tv", "14-guide", "15-movies", "16-series"]
        for name in sections {
            remote.press(.down)
            sleep(3)
            snap(name)
        }

        // Into the Series grid, open the first show.
        remote.press(.right)
        sleep(2)
        remote.press(.select)
        sleep(5)
        snap("17-series-detail")
        remote.press(.down)
        sleep(2)
        snap("18-series-detail-episodes")

    }

    /// Guide: one click previews the channel in the mini player, focus stays
    /// in the guide.
    func testCaptureGuidePreview() {
        let app = XCUIApplication()
        app.launchArguments += ["-AeriaScreenshots"]
        app.launch()
        sleep(12)

        let remote = XCUIRemote.shared
        remote.press(.left)          // rail, on Home
        sleep(2)
        for _ in 0..<3 {             // Search → Live TV → Guide
            remote.press(.down)
            sleep(2)
        }
        remote.press(.right)         // into the guide's first row
        sleep(2)
        snap("19-guide-focused")
        remote.press(.select)        // preview
        sleep(8)
        snap("20-guide-preview")
        remote.press(.down)          // keep browsing while it plays
        sleep(2)
        snap("21-guide-preview-browsing")
        remote.press(.menu)          // closes the preview, stays in the guide
        sleep(2)
        snap("22-guide-preview-closed")
    }

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
