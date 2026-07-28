import XCTest

/// Drives the real app through the accessibility tree.
///
/// These exist for the class of bug nothing else catches: clicking a layer row stopped
/// selecting anything the moment .onDrag was attached to it, and every unit test still
/// passed. The logic underneath was fine — the gesture never reached it.
///
/// Kept to a handful of load-bearing flows. UI tests are slow and go stale when the
/// layout moves, so they earn their place only where a person would otherwise have to
/// check by hand every time.
final class InteractionTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-test-fixture"]
        app.launch()
        app.activate()
        // The fixture opens with every container expanded, so the rows are all present.
        XCTAssertTrue(row("Photo").waitForExistence(timeout: 15), "fixture did not load")
    }

    override func tearDown() { app?.terminate() }

    private func row(_ name: String) -> XCUIElement {
        app.windows.firstMatch.descendants(matching: .any)["layer-\(name)"]
    }

    /// The layer named in the inspector. On macOS a StaticText carries its text in
    /// `value`; `label` comes back empty, which reads exactly like "nothing selected".
    private var selectedName: String? {
        let e = app.windows.firstMatch.descendants(matching: .any)["selected-layer"]
        guard e.waitForExistence(timeout: 2) else { return nil }
        if let v = e.value as? String, !v.isEmpty { return v }
        return e.label.isEmpty ? nil : e.label
    }

    // MARK: -

    func testClickingALayerRowSelectsIt() {
        let photo = row("Photo")
        XCTAssertTrue(photo.waitForExistence(timeout: 5), "the fixture's layers should be listed")
        photo.click()
        XCTAssertEqual(selectedName, "Photo",
                       "clicking a row must select it — .onDrag once swallowed this tap")
    }

    func testClickingADifferentRowMovesTheSelection() {
        row("Photo").click()
        XCTAssertEqual(selectedName, "Photo")
        row("Circle").click()
        XCTAssertEqual(selectedName, "Circle")
    }

    func testShiftClickingSelectsMoreThanOne() {
        row("Photo").click()
        let circle = row("Circle")
        XCUIElement.perform(withKeyModifiers: .shift) { circle.click() }
        // Two selected: the inspector stops naming one layer and reports the count.
        let summary = app.windows.firstMatch.descendants(matching: .any)["selection-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 2))
        let text = (summary.value as? String) ?? summary.label
        XCTAssertTrue(text.contains("2"), "expected two layers selected, got “\(text)”")
    }

    func testClickingTheCanvasSelectsTheGroupNotTheLayerInsideIt() {
        // A group is one object. The fixture's Group sits in the middle of the artboard.
        let canvas = app.windows.firstMatch.descendants(matching: .any)["canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertEqual(selectedName, "Group",
                       "clicking inside a group should select the group, not its contents")
    }

    func testDrillingIntoAGroupWithShiftCommandClick() {
        let canvas = app.windows.firstMatch.descendants(matching: .any)["canvas"]
        let centre = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        XCUIElement.perform(withKeyModifiers: [.shift, .command]) { centre.click() }
        XCTAssertNotEqual(selectedName, "Group",
                          "⇧⌘ should reach the layer under the pointer")
    }

    func testChatIsVisibleWithoutHuntingForIt() {
        // It used to be hidden behind a toolbar button, which is a good way to forget
        // a feature exists.
        let input = app.windows.firstMatch.descendants(matching: .any)["chat-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5), "chat should be open on launch")
    }

    func testDraggingALayerRowReordersIt() {
        let backdrop = row("Backdrop")
        let group = row("Group")
        XCTAssertTrue(backdrop.waitForExistence(timeout: 5))

        let before = backdrop.frame.origin.y < group.frame.origin.y
        // Drop below the other row, past its midpoint so it reads as "after".
        backdrop.click(forDuration: 0.2, thenDragTo: group)

        // The rows swap, so the one that was higher is now lower.
        let after = row("Backdrop").frame.origin.y < row("Group").frame.origin.y
        XCTAssertNotEqual(before, after, "dragging a row should have reordered the list")
    }

    func testTheDropMarkerDoesNotSurviveTheDrag() {
        // A blue line used to stay on screen after a drag that ended outside the list.
        let backdrop = row("Backdrop")
        XCTAssertTrue(backdrop.waitForExistence(timeout: 5))
        let canvas = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5))
        backdrop.click(forDuration: 0.2, thenDragTo: app.windows.firstMatch)
        _ = canvas
        // Nothing to assert on directly — a stuck marker shows up as the next click
        // landing on the wrong row, so check the list still behaves.
        row("Circle").click()
        XCTAssertEqual(selectedName, "Circle")
    }
}
