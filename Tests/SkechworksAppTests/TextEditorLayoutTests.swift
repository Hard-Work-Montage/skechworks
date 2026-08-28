import AppKit
import XCTest
@testable import SkechworksCore

/// The in-place editor has to break lines exactly where the artwork does.
///
/// Double-clicking a finished caption used to visibly rearrange it: the same
/// words came back on five lines instead of four, overflowing the bubble, and
/// went back to normal the moment you clicked away. Two causes, both here.
final class TextEditorLayoutTests: XCTestCase {

    /// Where CoreText breaks the string — what the renderer actually draws.
    private func rendererBreaks(_ text: String, font: NSFont, kern: CGFloat, width: CGFloat) -> [Int] {
        var attrs: [CFString: Any] = [kCTFontAttributeName: font]
        if kern != 0 { attrs[kCTKernAttributeName] = kern }
        let astr = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!
        let typesetter = CTTypesetterCreateWithAttributedString(astr)
        let length = CFAttributedStringGetLength(astr)
        var start = 0
        var breaks: [Int] = []
        while start < length {
            var count = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
            if count <= 0 { count = length - start }
            start += count
            breaks.append(start)
        }
        return breaks
    }

    /// Where an NSTextView breaks it, set up the way beginTextEdit sets one up.
    private func editorBreaks(_ text: String, font: NSFont, kern: CGFloat, width: CGFloat,
                              zeroPadding: Bool, applyKern: Bool) -> [Int] {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 4000))
        if zeroPadding {
            view.textContainerInset = .zero
            view.textContainer?.lineFragmentPadding = 0
        }
        view.textContainer?.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        view.string = text
        guard let storage = view.textStorage, let manager = view.layoutManager,
              let container = view.textContainer else { return [] }
        let whole = NSRange(location: 0, length: storage.length)
        storage.addAttribute(.font, value: font, range: whole)
        if applyKern, kern != 0 { storage.addAttribute(.kern, value: kern, range: whole) }
        manager.ensureLayout(for: container)

        var breaks: [Int] = []
        var index = 0
        while index < storage.length {
            var effective = NSRange()
            manager.lineFragmentRect(forGlyphAt: index, effectiveRange: &effective)
            index = effective.location + effective.length
            breaks.append(index)
        }
        return breaks
    }

    private let caption = "A MONTHS WORTH OF WORK IN AN AFTERNOON! STILL NOT SURE I'LL EVER GET USED TO THIS..."

    func testTheEditorBreaksWhereTheArtworkDoes() {
        let font = NSFont(name: "Helvetica", size: 40) ?? .systemFont(ofSize: 40)
        let width: CGFloat = 520
        for kern in [CGFloat(0), 3.5] {
            let drawn = rendererBreaks(caption, font: font, kern: kern, width: width)
            let typed = editorBreaks(caption, font: font, kern: kern, width: width,
                                     zeroPadding: true, applyKern: true)
            XCTAssertEqual(drawn, typed,
                           "with kerning \(kern), the editor must wrap where the renderer wraps")
        }
    }

    func testTheContainerPaddingIsWhatMovedTheLineBreaks() {
        // Left alone, a text container insets and pads by ~5pt a side, so it
        // wraps roughly ten points narrower than the box. This is the regression
        // guard: if the fix is ever removed, this stops matching.
        let font = NSFont(name: "Helvetica", size: 40) ?? .systemFont(ofSize: 40)
        let width: CGFloat = 520
        let drawn = rendererBreaks(caption, font: font, kern: 0, width: width)
        let padded = editorBreaks(caption, font: font, kern: 0, width: width,
                                  zeroPadding: false, applyKern: true)
        XCTAssertNotEqual(drawn, padded, "padding should be what breaks it — if not, the cause moved")
    }

    func testLeavingTrackingOutOfTheEditorAloneMovesTheBreaks() {
        // Tracking is part of how wide a line is, so an editor without it wraps
        // in different places even with the padding fixed.
        let font = NSFont(name: "Helvetica", size: 40) ?? .systemFont(ofSize: 40)
        let width: CGFloat = 520
        let drawn = rendererBreaks(caption, font: font, kern: 3.5, width: width)
        let untracked = editorBreaks(caption, font: font, kern: 3.5, width: width,
                                     zeroPadding: true, applyKern: false)
        XCTAssertNotEqual(drawn, untracked)
    }
}
