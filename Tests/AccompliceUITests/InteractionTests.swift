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

    /// Types a new name into the rename sheet.
    ///
    /// Deletes character by character rather than pressing ⌘A: the select-all doesn't
    /// reach the field, and the new text ends up appended — "Page 2Backs" — which
    /// looks exactly like a rename that didn't take.
    /// Pages still ask for the name in a sheet; layer rows edit in place.
    private func rename(to name: String) {
        let sheet = app.windows.firstMatch.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 3), "renaming should ask for a name")
        let field = sheet.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        field.click()
        for _ in 0..<40 { field.typeKey(.delete, modifierFlags: []) }
        field.typeText(name)
        sheet.buttons["Rename"].click()
    }

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

    /// A popup's intrinsic width is its widest menu item, and every font family
    /// previews itself — so selecting text once stretched the inspector until the
    /// canvas was a sliver. Shipped that way in 0.4.7; pinned here.
    func testSelectingTextDoesNotStretchTheInspector() {
        // Relaunch asking for the text layer: it is not in the shared fixture
        // because a loose layer moves the page bounds every click test measures.
        app.terminate()
        app.launchArguments = ["--ui-test-fixture", "--ui-test-text"]
        app.launch()
        app.activate()
        XCTAssertTrue(row("Caption").waitForExistence(timeout: 15), "text fixture did not load")

        let window = app.windows.firstMatch
        let widthBefore = window.frame.width

        row("Caption").click()
        let picker = window.descendants(matching: .any)["font-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "the text section should show a font picker")

        XCTAssertLessThan(picker.frame.width, 320,
                          "the font popup must compress to the panel, not stretch it")
        XCTAssertLessThan(window.frame.width, widthBefore + 1,
                          "selecting text must not resize the window")
    }

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
        var text = ""
        for _ in 0..<20 {
            text = selectedName ?? ""
            if text.contains("2") { break }
            usleep(150_000)
        }
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

    func testDoubleClickingAGroupSelectsWhatIsInsideIt() {
        // One double-click, not two: entering the group and picking the frontmost
        // thing under the pointer is a single act.
        let canvas = app.windows.firstMatch.descendants(matching: .any)["canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        let centre = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        centre.click()
        XCTAssertEqual(selectedName, "Group")

        centre.doubleClick()
        XCTAssertEqual(selectedName, "Photo",
                       "double-click should enter the group and take the frontmost layer")
    }

    func testOnceInsideAGroupASingleClickStaysInside() {
        let canvas = app.windows.firstMatch.descendants(matching: .any)["canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        let centre = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        centre.doubleClick()
        XCTAssertEqual(selectedName, "Photo")

        // Still inside: clicking the group again picks a member, not the group.
        centre.click()
        XCTAssertEqual(selectedName, "Photo", "a click inside an entered group stays inside")
    }

    func testRotationCanBeTypedIn() {
        row("Photo").click()
        let angle = app.windows.firstMatch.descendants(matching: .any)["field-Angle"]
        XCTAssertTrue(angle.waitForExistence(timeout: 3), "the inspector needs an editable angle")
        angle.click()
        angle.typeKey("a", modifierFlags: .command)
        angle.typeText("1\r")
        XCTAssertEqual(Double((angle.value as? String) ?? ""), 1)
    }

    func testSaveAsOffersOnlyTheBaseNameToTypeOver() {
        // macOS treats ".png" as the extension and highlights "Untitled.acmplc", so
        // typing a name throws away the part that decides which app opens the file.
        // The panel should present the base name and own the extension itself.
        app.typeKey("s", modifierFlags: [.command, .shift])

        // runModal() shows an app-modal panel, which is its own window rather than a
        // sheet on the document.
        let sheet = app.dialogs.firstMatch.exists ? app.dialogs.firstMatch
                                                  : app.windows["Save"].firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "Save As should open a panel")
        let field = sheet.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))

        let shown = (field.value as? String) ?? ""
        XCTAssertFalse(shown.contains(".acmplc"),
                       "the name field should not put .acmplc in the way, got “\(shown)”")
        XCTAssertTrue(shown.hasPrefix("Untitled"), "expected the base name, got “\(shown)”")

        // Never actually write a file from a test.
        sheet.buttons["Cancel"].click()
    }

    // MARK: - Pages and renaming

    func testAddingAPage() {
        let add = app.windows.firstMatch.descendants(matching: .any)["add-page"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), "there should be a way to add a page")
        add.click()
        XCTAssertTrue(app.windows.firstMatch.descendants(matching: .any)["page-Page 2"]
                        .waitForExistence(timeout: 3), "a second page should appear")
    }

    func testDoubleClickingAPageRenamesIt() {
        let page = app.windows.firstMatch.descendants(matching: .any)["page-Page 1"]
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        page.doubleClick()

        rename(to: "Coins")

        XCTAssertTrue(app.windows.firstMatch.descendants(matching: .any)["page-Coins"]
                        .waitForExistence(timeout: 3))
    }

    func testUndoAfterRenamingAPagePutsTheOldNameBack() {
        // Undo is the point here. An app-layer test can't check it: everything it does
        // lands in one run-loop turn and NSUndoManager groups by event, so two
        // operations undo as one. Through the UI the events are real.
        app.windows.firstMatch.descendants(matching: .any)["add-page"].click()
        let page2 = app.windows.firstMatch.descendants(matching: .any)["page-Page 2"]
        XCTAssertTrue(page2.waitForExistence(timeout: 3))

        page2.doubleClick()
        rename(to: "Backs")
        XCTAssertTrue(app.windows.firstMatch.descendants(matching: .any)["page-Backs"]
                        .waitForExistence(timeout: 3))

        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(app.windows.firstMatch.descendants(matching: .any)["page-Page 2"]
                        .waitForExistence(timeout: 3),
                      "undo should put the old name back")
    }

    func testDraggingAPageReordersIt() {
        // Pages had no dragging at all until the list moved off SwiftUI.
        app.windows.firstMatch.descendants(matching: .any)["add-page"].click()
        let first = app.windows.firstMatch.descendants(matching: .any)["page-Page 1"]
        let second = app.windows.firstMatch.descendants(matching: .any)["page-Page 2"]
        XCTAssertTrue(second.waitForExistence(timeout: 3))
        XCTAssertLessThan(first.frame.origin.y, second.frame.origin.y)

        second.press(forDuration: 0.4, thenDragTo: first,
                     withVelocity: .slow, thenHoldForDuration: 0.4)

        XCTAssertLessThan(app.windows.firstMatch.descendants(matching: .any)["page-Page 2"].frame.origin.y,
                          app.windows.firstMatch.descendants(matching: .any)["page-Page 1"].frame.origin.y,
                          "the dragged page should have moved above the other")
    }

    func testDeleteKeyRemovesTheLayerSelectedInTheList() {
        // It worked with the canvas focused and did nothing with the list focused,
        // which is backwards from where you just clicked.
        let photo = row("Photo")
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        photo.click()
        XCTAssertEqual(selectedName, "Photo")

        photo.typeKey(.delete, modifierFlags: [])
        XCTAssertFalse(row("Photo").waitForExistence(timeout: 2),
                       "delete should remove the layer selected in the list")
    }

    func testDeleteKeyRemovesTheSelectedPage() {
        app.windows.firstMatch.descendants(matching: .any)["add-page"].click()
        let second = app.windows.firstMatch.descendants(matching: .any)["page-Page 2"]
        XCTAssertTrue(second.waitForExistence(timeout: 3))

        second.click()
        second.typeKey(.delete, modifierFlags: [])
        XCTAssertFalse(app.windows.firstMatch.descendants(matching: .any)["page-Page 2"]
                        .waitForExistence(timeout: 2))
    }

    /// This was the canary. It failed because renaming was genuinely broken:
    /// the canvas shortcuts are bare letters, SwiftUI made them menu key
    /// equivalents, and menus get every keystroke before a field editor does —
    /// so typing a name inserted rectangles instead. TypingWins fixed it.
    func testDoubleClickingALayerRenamesIt() {
        let photo = row("Photo")
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        photo.doubleClick()

        // In place since July 30: the row's field turns editable with its text
        // selected, so typing replaces the name. Type at the app, not at an
        // element — exactly what a person does, and the only way to prove the
        // keystrokes reach the field instead of the menus.
        app.typeText("Coin front")
        app.typeKey(.enter, modifierFlags: [])

        XCTAssertTrue(row("Coin front").waitForExistence(timeout: 3))
    }

    func testTheCanvasScrollsWithoutEndingOrSpringingBack() {
        // The old canvas was a document sized to the artwork: scrolling stopped at the
        // edge, and anything smaller than the window was pinned to the middle. Here it
        // should just keep going.
        let canvas = app.windows.firstMatch.descendants(matching: .any)["canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        let viewport = app.windows.firstMatch.descendants(matching: .any)["canvas-viewport"]
        XCTAssertTrue(viewport.waitForExistence(timeout: 3))

        func originX() -> Double {
            Double(((viewport.value as? String) ?? "").split(separator: ",").first ?? "0") ?? 0
        }
        let start = originX()

        canvas.scroll(byDeltaX: -400, deltaY: 0)
        let once = originX()
        XCTAssertNotEqual(once, start, accuracy: 0.5, "scrolling should move the page")

        // And again, well past where the old document would have ended.
        for _ in 0..<6 { canvas.scroll(byDeltaX: -400, deltaY: 0) }
        XCTAssertGreaterThan(abs(originX() - start), abs(once - start) * 2,
                             "the canvas should keep going, not stop at the artwork")
    }

    func testChatIsVisibleWithoutHuntingForIt() {
        // It used to be hidden behind a toolbar button, which is a good way to forget
        // a feature exists.
        let input = app.windows.firstMatch.descendants(matching: .any)["chat-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5), "chat should be open on launch")
    }

    func testDraggingALayerOntoAGroupPutsItInside() {
        let backdrop = row("Backdrop")
        let group = row("Group")
        XCTAssertTrue(backdrop.waitForExistence(timeout: 5))
        // The list shows the front-most layer first, so Group starts above Backdrop.
        XCTAssertGreaterThan(backdrop.frame.origin.y, group.frame.origin.y)

        backdrop.press(forDuration: 0.4, thenDragTo: group,
                       withVelocity: .slow, thenHoldForDuration: 0.4)

        // Dropped onto a container, so it should now sit inside it — between the group
        // and the group's own contents.
        let moved = row("Backdrop").frame.origin.y
        XCTAssertGreaterThan(moved, row("Group").frame.origin.y)
        XCTAssertLessThan(moved, row("Photo").frame.origin.y,
                          "dropping onto a group should put the layer inside it")
    }

    func testTheDropMarkerDoesNotSurviveTheDrag() {
        // A blue line used to stay on screen after a drag that ended outside the list.
        let backdrop = row("Backdrop")
        XCTAssertTrue(backdrop.waitForExistence(timeout: 5))
        let canvas = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5))
        backdrop.press(forDuration: 0.5, thenDragTo: app.windows.firstMatch,
                       withVelocity: .slow, thenHoldForDuration: 0.5)
        _ = canvas
        // Nothing to assert on directly — a stuck marker shows up as the next click
        // landing on the wrong row, so check the list still behaves.
        row("Circle").click()
        XCTAssertEqual(selectedName, "Circle")
    }
}
