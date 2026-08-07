import Foundation
import Testing

@testable import AccompliceCore

// Opening someone else's file is an import, not a document to write back to.
//
// Saving Accomplice's model into a file still called .sketch makes something
// Sketch can't read and this app can, under a name that promises the opposite —
// and it replaces the original to do it.

@Test func someoneElsesFormatsAreImports() {
    for name in [ "Icons.sketch", "logo.svg", "board.fig", "art.ai", "old.eps", "spec.pdf" ] {
        #expect(AcmplcFile.isImportedFormat(URL(fileURLWithPath: "/tmp/\(name)")),
                "\(name) should force a Save As")
    }
}

@Test func ourOwnDocumentIsNotAnImport() {
    #expect(!AcmplcFile.isImportedFormat(URL(fileURLWithPath: "/tmp/Drawing.acmplc.png")))
}

@Test func aPlainPngIsNotDecidedHere() {
    // A bare .png is a picture to place, handled separately — it must not be
    // caught by the extension list and treated as a document format.
    #expect(!AcmplcFile.isImportedFormat(URL(fileURLWithPath: "/tmp/photo.png")))
}

@Test func theCaseOfTheExtensionDoesNotMatter() {
    #expect(AcmplcFile.isImportedFormat(URL(fileURLWithPath: "/tmp/Icons.SKETCH")))
    #expect(!AcmplcFile.isImportedFormat(URL(fileURLWithPath: "/tmp/Drawing.ACMPLC.PNG")))
}
