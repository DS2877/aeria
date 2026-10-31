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

        remote.press(.left)
        remote.press(.left)
        remote.press(.left)
        sleep(2)
        snap("09-sidebar")
    }

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
