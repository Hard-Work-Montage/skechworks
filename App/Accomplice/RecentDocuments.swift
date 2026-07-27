import AppKit
import SwiftUI

/// Open Recent.
///
/// Backed by NSDocumentController's own list rather than a private one, so the same
/// documents appear in the Dock menu and in Finder's recents — free, and consistent
/// with every other Mac app. SwiftUI's WindowGroup doesn't supply this the way
/// DocumentGroup would, so the menu is built by hand from that list.
@MainActor
final class RecentDocuments: ObservableObject {
    static let shared = RecentDocuments()

    @Published private(set) var urls: [URL] = []

    private init() { refresh() }

    func note(_ url: URL) {
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        refresh()
    }

    func clear() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        refresh()
    }

    func refresh() {
        // Drop anything that's been moved or deleted; offering a dead path is worse
        // than a shorter menu.
        urls = NSDocumentController.shared.recentDocumentURLs
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
