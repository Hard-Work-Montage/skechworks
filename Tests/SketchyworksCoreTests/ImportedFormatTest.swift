import Foundation
import Testing

@testable import SketchyworksCore

// Opening someone else's file is an import, not a document to write back to.
//
// Saving Sketchyworks's model into a file still called .sketch makes something
// Sketch can't read and this app can, under a name that promises the opposite —
// and it replaces the original to do it.

@Test func someoneElsesFormatsAreImports() {
    for name in [ "Icons.sketch", "logo.svg", "board.fig", "art.ai", "old.eps", "spec.pdf" ] {
        #expect(SketchyworksFile.isImportedFormat(URL(fileURLWithPath: "/tmp/\(name)")),
                "\(name) should force a Save As")
    }
}

@Test func ourOwnDocumentIsNotAnImport() {
    #expect(!SketchyworksFile.isImportedFormat(URL(fileURLWithPath: "/tmp/Drawing.sw.png")))
}

@Test func aPlainPngIsNotDecidedHere() {
    // A bare .png is a picture to place, handled separately — it must not be
    // caught by the extension list and treated as a document format.
    #expect(!SketchyworksFile.isImportedFormat(URL(fileURLWithPath: "/tmp/photo.png")))
}

@Test func theCaseOfTheExtensionDoesNotMatter() {
    #expect(SketchyworksFile.isImportedFormat(URL(fileURLWithPath: "/tmp/Icons.SKETCH")))
    #expect(!SketchyworksFile.isImportedFormat(URL(fileURLWithPath: "/tmp/Drawing.SW.PNG")))
}
