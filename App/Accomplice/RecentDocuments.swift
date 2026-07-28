import AppKit
import Combine
import Foundation

/// The Open Recent menu.
///
/// It used to read NSDocumentController.recentDocumentURLs and nothing else. That list
/// belongs to AppKit's document architecture, which this app doesn't use — nothing
/// here is an NSDocument — and AppKit writes it back to disk whenever it feels like,
/// typically at a clean quit. Anything that ends the process another way loses every
/// entry, and the menu quietly empties.
///
/// So the list is kept here and written immediately. The document controller is still
/// told, because that's what feeds the Dock icon's Recents menu, but nothing depends
/// on it any more.
@MainActor
final class RecentDocuments: ObservableObject {
    static let shared = RecentDocuments()

    static let key = "recentDocuments"
    static let limit = 10

    @Published private(set) var urls: [URL] = []

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        refresh()
    }

    func note(_ url: URL) {
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        let stored = defaults.stringArray(forKey: Self.key) ?? []
        defaults.set(Self.adding(url.path, to: stored), forKey: Self.key)
        refresh()
    }

    func clear() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        defaults.removeObject(forKey: Self.key)
        refresh()
    }

    func refresh() {
        // Drop anything that's been moved or deleted; offering a dead path is worse
        // than a shorter menu.
        urls = (defaults.stringArray(forKey: Self.key) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// Most recent first, no duplicates, capped. Pure, so the ordering is testable
    /// without touching the filesystem or the menu.
    static func adding(_ path: String, to existing: [String]) -> [String] {
        ([path] + existing.filter { $0 != path }).prefix(limit).map { $0 }
    }
}
