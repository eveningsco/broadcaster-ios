import XCTest

/// Recorded demos that need real taps. A SwiftUI `Menu` (the plus circle)
/// can't be opened from code, so these drive the app through XCUITest while
/// scripts/simulator-screenshots.sh records the simulator: a `-demo` scene
/// with a `test_<scene>` method here (dashes → underscores) is run with
/// `xcodebuild test-without-building` instead of a plain launch. The app
/// draws a fingertip at each touch (`-show-touches 1`, see
/// Sources/Debug/TouchSpotlight.swift).
///
/// Pauses are generous: the CI simulator is software-rendered and the
/// clips are trimmed afterwards (docs/videos/).
final class Demos: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// The plus circle under the library: Go live and Record land on the
    /// stage's matching side, Upload opens the Files picker.
    func test_plus_demo() {
        let app = XCUIApplication()
        app.launchArguments = ["-screenshot", "library", "-show-touches", "1"]
        app.launch()

        let plus = app.descendants(matching: .any)["Add to your station"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 90), "plus circle not found")
        pause(2.5)

        for item in ["Record", "Go live"] {
            plus.tap()
            pause(2.4)
            menuItem(app, item).tap()
            pause(3.2)
            backToLibrary(app)
            pause(1.8)
        }

        plus.tap()
        pause(2.4)
        menuItem(app, "Upload").tap()
        pause(5)
    }

    /// The hittable element with this label. The stage behind the library
    /// card has buttons with similar labels ("Record"); those are covered by
    /// the card and so not hittable, the open menu's items are.
    private func menuItem(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        let predicate = NSPredicate(format: "label == %@", label)
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            let hittable = app.descendants(matching: .any).matching(predicate)
                .allElementsBoundByIndex.first { $0.isHittable }
            if let hittable { return hittable }
            pause(0.25)
        }
        XCTFail("menu item \(label) not found")
        return app.descendants(matching: .any)[label].firstMatch
    }

    /// The stage's "Library ›" pill (BroadcastView.onBack), or a swipe if
    /// it isn't hittable for some reason.
    private func backToLibrary(_ app: XCUIApplication) {
        let predicate = NSPredicate(format: "label BEGINSWITH 'Library'")
        if let back = app.buttons.matching(predicate).allElementsBoundByIndex.first(where: { $0.isHittable }) {
            back.tap()
        } else {
            app.swipeLeft()
        }
    }

    private func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
