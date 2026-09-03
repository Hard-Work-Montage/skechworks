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
    // Ten was the menu's whole width for a shop that opens several one-off
    // coins a day; a file from last week was already gone.
    static let limit = 20

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
        // than a shorter menu. A document iCloud has evicted is not gone, though:
        // the path is absent and a ".name.icloud" placeholder stands in for it,
        // and opening it pulls the file back down. Filtering those out is how
        // projects kept vanishing from the menu.
        urls = (defaults.stringArray(forKey: Self.key) ?? [])
            .filter { Self.present($0) }
            .map { URL(fileURLWithPath: $0) }
    }

    static func present(_ path: String) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) { return true }
        let url = URL(fileURLWithPath: path)
        let placeholder = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).icloud")
        return fm.fileExists(atPath: placeholder.path)
    }

    /// Most recent first, no duplicates, capped. Pure, so the ordering is testable
    /// without touching the filesystem or the menu.
    static func adding(_ path: String, to existing: [String]) -> [String] {
        ([path] + existing.filter { $0 != path }).prefix(limit).map { $0 }
    }
}
