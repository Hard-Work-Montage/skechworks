import XCTest
import AppKit
import CoreGraphics
import SketchyworksCore
@testable import Sketchyworks

/// What snapping does to a real drag, rather than to a pair of rectangles.
///
/// Snapping.swift is tested against rects, and passes. Whether the canvas hands it
/// the right rects during an actual press-move-release is a different question, and
/// it's the one that decides whether an object lands on the edge of the board it
/// sits on. So this drives NSEvents through the view and reads the committed offset.
@MainActor
final class CanvasSnapTests: XCTestCase {

    /// An artboard at the page origin with one small square inside it.
    private func canvasWithBoard(childAt: CGPoint) -> (PageCanvas, Page) {
        var inner = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 40, height: 40),
                                             transform: nil), closed: true))
        inner.id = "inner"
        inner.name = "Square"
        inner.frame = CGRect(origin: childAt, size: CGSize(width: 40, height: 40))

        var board = Layer(kind: .group([inner]))
        board.id = "board"
        board.name = "Board"
        board.isArtboard = true
        board.frame = CGRect(x: 0, y: 0, width: 400, height: 400)

        var page = Page(name: "P")
        page.layers = [board]

        let canvas = PageCanvas(frame: CGRect(x: 0, y: 0, width: 600, height: 600))
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = canvas
        canvas.page = page
        canvas.tool = .select
        return (canvas, page)
    }

    /// The view is flipped and sits at the window's origin at scale 1, so a page
    /// point and a window point are the same number.
    private func event(_ type: NSEvent.EventType, _ p: CGPoint, in canvas: PageCanvas) -> NSEvent {
        NSEvent.mouseEvent(with: type,
                           location: canvas.convert(p, to: nil),
                           modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: canvas.window?.windowNumber ?? 0,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    /// Presses on the square, drags by `by`, releases, and reports the offset the
    /// canvas committed — which is the proposed move plus whatever snapping added.
    private func drag(_ canvas: PageCanvas, from: CGPoint, by: CGSize,
                      alreadySelected: Set<String> = []) -> CGSize? {
        var committed: CGSize?
        canvas.selected = alreadySelected
        // SwiftUI owns the selection, so it comes back on the next pass of the run
        // loop rather than inside mouseDown. Matching that is the point of the test.
        canvas.onSelect = { id, _ in
            DispatchQueue.main.async { canvas.selected = id.map { [$0] } ?? [] }
        }
        canvas.onDragBegin = { _ in }
        canvas.onDragEnd = { committed = $0 }
        canvas.mouseDown(with: event(.leftMouseDown, from, in: canvas))
        let to = CGPoint(x: from.x + by.width, y: from.y + by.height)
        canvas.mouseDragged(with: event(.leftMouseDragged, to, in: canvas))
        canvas.mouseUp(with: event(.leftMouseUp, to, in: canvas))
        return committed
    }

    /// Dragging a square that lives on a board towards the board's left edge should
    /// land it ON the edge — the object's x inside the board becomes 0.
    func testSquareInsideAnArtboardLandsOnItsLeftEdge() throws {
        let (canvas, _) = canvasWithBoard(childAt: CGPoint(x: 100, y: 100))
        // Centre of the square is at 120,120. Move it left so its leading edge sits
        // 3 units from the board's, which is inside the 7px tolerance.
        let offset = try XCTUnwrap(drag(canvas, from: CGPoint(x: 120, y: 120),
                                        by: CGSize(width: -97, height: 0)))
        XCTAssertEqual(offset.width, -100, accuracy: 0.001,
                       "the square should have been pulled the last 3 units onto the edge")
    }

    /// And the same at the far side, where the object's trailing edge meets the
    /// board's — the case that catches an off-by-a-width in the candidate lines.
    func testSquareInsideAnArtboardLandsOnItsRightEdge() throws {
        let (canvas, _) = canvasWithBoard(childAt: CGPoint(x: 100, y: 100))
        // Square is 40 wide, board 400: its trailing edge meets the board's at x=360.
        let offset = try XCTUnwrap(drag(canvas, from: CGPoint(x: 120, y: 120),
                                        by: CGSize(width: 256, height: 0)))
        XCTAssertEqual(offset.width, 260, accuracy: 0.001)
    }

    /// Make a new artboard and it's the selected thing. Drop a square on it, drag the
    /// square to the edge, and the edge has to still be there to snap to. This is the
    /// one that was broken: the board counted as "moving" because it was selected
    /// when the press landed, so it was left out of the things to line up against.
    func testTheBoardIsStillASnapTargetWhenItWasTheThingSelected() throws {
        let (canvas, _) = canvasWithBoard(childAt: CGPoint(x: 100, y: 100))
        let offset = try XCTUnwrap(drag(canvas, from: CGPoint(x: 120, y: 120),
                                        by: CGSize(width: -97, height: 0),
                                        alreadySelected: ["board"]))
        XCTAssertEqual(offset.width, -100, accuracy: 0.001)
    }

    /// Same shape of mistake with two objects: pressing on B while A is selected
    /// moves only B, so A is a thing to line up against, not a thing in motion.
    func testTheLastThingSelectedIsStillASnapTarget() throws {
        let (canvas, _) = canvasWithBoard(childAt: CGPoint(x: 100, y: 100))
        var other = Layer(kind: .path(CGPath(rect: CGRect(x: 0, y: 0, width: 40, height: 40),
                                             transform: nil), closed: true))
        other.id = "other"
        other.frame = CGRect(x: 200, y: 300, width: 40, height: 40)
        var page = try XCTUnwrap(canvas.page)
        guard case .group(let kids) = page.layers[0].kind else { return XCTFail("no board") }
        page.layers[0].kind = .group(kids + [other])
        canvas.page = page

        // Square's leading edge is at 100; "other" sits at 200, three units from
        // where the square would land after a 97-unit move.
        let offset = try XCTUnwrap(drag(canvas, from: CGPoint(x: 120, y: 120),
                                        by: CGSize(width: 97, height: 0),
                                        alreadySelected: ["other"]))
        XCTAssertEqual(offset.width, 100, accuracy: 0.001)
    }
}
