import AccompliceCore
import CoreGraphics
import Foundation

// A known document for the UI tests to drive.
//
// UI tests have to start from something predictable, and "whatever was open last
// time" isn't it. Launching with --ui-test-fixture loads this instead of an empty
// page. Named layers, because a test asserting on a UUID tells you nothing when it
// fails.
enum TestFixture {
    static var requested: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-test-fixture")
    }

    /// Puts the window's furniture back where the tests expect it.
    ///
    /// A UI test drives the real app bundle, so it inherits whatever preferences
    /// are on the machine — and Adam collapsing the chat panel while working made
    /// "the chat is open on launch" fail on his laptop and nowhere else. The
    /// fixture is meant to make a run predictable, and the layout is as much a
    /// part of that as the document is.
    static func resetLayoutPreferences() {
        guard requested else { return }
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "showChat")
        defaults.set(false, forKey: "chatCollapsed")
    }

    /// Adds a text layer, for the one test that needs the inspector's TEXT
    /// section. Opt-in because a loose layer changes the page's bounds, and
    /// every canvas-click test derives its coordinates from zoom-to-fit.
    static var includesText: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-test-text")
    }

    /// Artboard ▸ (Backdrop, Group ▸ (Circle, Photo)) — the shape of Adam's coin file,
    /// which is where the selection and drag bugs kept showing up.
    static func document() -> Document {
        var circle = Layer(kind: .path(CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 200, height: 200),
                                              transform: nil), closed: true))
        circle.name = "Circle"
        circle.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        circle.style.fills = [Fill(paint: .color(Color(r: 0.2, g: 0.4, b: 0.8, a: 1)))]

        var photo = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 160, height: 160),
                                             transform: nil), closed: true))
        photo.name = "Photo"
        photo.frame = CGRect(x: 20, y: 20, width: 160, height: 160)
        photo.style.fills = [Fill(paint: .color(Color(r: 0.9, g: 0.3, b: 0.2, a: 1)))]

        var group = Layer(kind: .group([circle, photo]))
        group.name = "Group"
        group.frame = CGRect(x: 150, y: 150, width: 200, height: 200)

        var backdrop = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 100, height: 100),
                                                transform: nil), closed: true))
        backdrop.name = "Backdrop"
        backdrop.frame = CGRect(x: 20, y: 20, width: 100, height: 100)
        backdrop.style.fills = [Fill(paint: .color(Color(r: 0.15, g: 0.15, b: 0.15, a: 1)))]

        var art = Layer(kind: .group([backdrop, group]))
        art.name = "Frame"
        art.isArtboard = true
        art.backgroundColor = Color(r: 1, g: 1, b: 1, a: 1)
        art.frame = CGRect(x: 0, y: 0, width: 500, height: 500)

        var page = Page(name: "Page 1")
        page.layers = [art]

        // Its only job is to make the inspector show the TEXT section — the font
        // picker there once stretched the whole panel to its widest menu item.
        if includesText {
            var run = TextRun()
            run.string = "Caption"
            run.fontName = "Helvetica"
            run.fontSize = 24
            var caption = Layer(kind: .text(run))
            caption.name = "Caption"
            caption.frame = CGRect(x: 600, y: 40, width: 220, height: 40)
            page.layers.append(caption)
        }
        var doc = Document()
        doc.pages = [page]
        return doc
    }
}
