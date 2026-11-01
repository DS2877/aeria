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

        // Search sits above Home.
        remote.press(.up)
        sleep(3)
        snap("12-search")
        remote.press(.down)          // back on Home
        sleep(2)

        // Walk the sections down the rail (focus-driven: each one shows).
        let sections = ["13-live-tv", "14-guide", "15-movies", "16-series"]
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
        // Launch straight into the Guide — no rail walking to go wrong.
        app.launchArguments += ["-AeriaScreenshots", "-AeriaScreenshotSection", "guide"]
        app.launch()
        sleep(12)
        snap("18b-guide-launch")

        let remote = XCUIRemote.shared
        // Focus starts in the rail on Guide. → must enter the guide (the
        // info pane above the rows has nothing focusable).
        remote.press(.right)
        sleep(2)
        snap("19-guide-focused")
        noteFocus(app, "19 after → from rail")
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

    /// Clicking a sidebar item dives into that section (it used to jump to Home).
    func testClickingSidebarItemOpensThatSection() {
        let app = XCUIApplication()
        app.launchArguments += ["-AeriaScreenshots", "-AeriaScreenshotSection", "guide"]
        app.launch()
        sleep(12)
        XCUIRemote.shared.press(.select)
        sleep(3)
        snap("25-guide-after-click")
        noteFocus(app, "25 after clicking Guide in the rail")
    }

    /// Clicking each sidebar item moves focus into that section; Menu on the
    /// section's root brings focus back to the sidebar on that same item.
    func testSidebarClickEntersEverySection() {
        let app = XCUIApplication()
        app.launchArguments += ["-AeriaScreenshots"]
        app.launch()
        sleep(12)

        let remote = XCUIRemote.shared
        remote.press(.left)          // into the rail, on Home (Search is above it)
        sleep(2)
        for name in ["live-tv", "guide", "movies", "series", "favorites", "history"] {
            remote.press(.down)
            sleep(3)
            remote.press(.select)
            sleep(2)
            snap("30-click-\(name)")
            noteFocus(app, "click \(name)")
            // Back to the rail, landing on the same item. In the Guide ← moves
            // back in time, so Menu is the way out there.
            remote.press(name == "guide" ? .menu : .left)
            sleep(2)
            noteFocus(app, "left after \(name)")
        }
    }

    /// Menu deep in the Movies grid jumps back to the first card; a second
    /// Menu opens the sidebar on Movies.
    func testMenuDeepInGridGoesToTopFirst() {
        let app = XCUIApplication()
        app.launchArguments += ["-AeriaScreenshots", "-AeriaScreenshotSection", "movies"]
        app.launch()
        sleep(12)

        let remote = XCUIRemote.shared
        remote.press(.select)        // rail → into the Movies grid
        sleep(2)
        remote.press(.down)
        sleep(1)
        remote.press(.down)
        sleep(2)
        noteFocus(app, "grid deep")
        remote.press(.menu)
        sleep(3)
        snap("26-grid-back-to-top")
        noteFocus(app, "grid after menu")
        remote.press(.menu)
        sleep(2)
        noteFocus(app, "grid after second menu")
    }

    /// Movies opens on the category overview; a genre tile opens that genre,
    /// Menu returns to the overview.
    func testCategoryBrowsing() {
        let app = XCUIApplication()
        app.launchArguments += ["-AeriaScreenshots", "-AeriaScreenshotSection", "movies"]
        app.launch()
        sleep(12)

        let remote = XCUIRemote.shared
        remote.press(.select)        // rail → into Movies (first tile)
        sleep(2)
        snap("40-movies-categories")
        noteFocus(app, "categories entry")
        remote.press(.select)        // open it
        sleep(3)
        snap("41-movies-category-open")
        noteFocus(app, "category opened")
        remote.press(.menu)          // back to the overview
        sleep(3)
        snap("42-movies-category-back")
        noteFocus(app, "category menu")
        remote.press(.down)
        sleep(1)
        remote.press(.down)
        sleep(2)
        snap("43-movies-quick-picks-and-grid")
    }

    /// Menu on a detail screen goes back one step, not to the sidebar.
    func testMenuOnDetailGoesBackOneStep() {
        let app = XCUIApplication()
        app.launchArguments += ["-AeriaScreenshots", "-AeriaScreenshotSection", "movies"]
        app.launch()
        sleep(12)

        let remote = XCUIRemote.shared
        remote.press(.select)        // rail → into the Movies grid
        sleep(2)
        remote.press(.right)
        sleep(2)
        remote.press(.select)        // open the focused film
        sleep(4)
        snap("23-movie-detail-from-grid")
        remote.press(.menu)          // back one step
        sleep(3)
        snap("24-back-on-movies-grid")
    }

    /// Record what holds focus — the screenshots show *where*, this says *what*.
    private func noteFocus(_ app: XCUIApplication, _ step: String) {
        let focused = app.descendants(matching: .any)
            .element(matching: NSPredicate(format: "hasFocus == true"))
        let label = focused.exists ? "\(focused.elementType.rawValue) '\(focused.label)'" : "nothing"
        print("FOCUS[\(step)]: \(label)")
        let note = XCTAttachment(string: "\(step): \(label)")
        note.name = "focus-\(step)"
        note.lifetime = .keepAlways
        add(note)
    }

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
