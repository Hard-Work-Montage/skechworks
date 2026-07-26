import AppKit
import SwiftUI

@main
struct AccompliceApp: App {
    @StateObject private var store = DocumentStore()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear { delegate.store = store }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                Button("Open…") { store.openPanel() }
                    .keyboardShortcut("o", modifiers: .command)
                Divider()
                Button("Export Page as SVG…") { store.exportCurrentPage() }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(store.document == nil)
                Button("Export All Pages as SVG…") { store.exportAllPages() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(store.document == nil)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?

    /// URLs that arrived before the UI existed.
    ///
    /// `application(_:open:)` fires as part of launch, which is *before* the SwiftUI
    /// view hierarchy appears and hands us the store. Opening directly there drops the
    /// document on the floor with no error — the app just comes up empty, which is
    /// exactly what it did the first time.
    private var pendingURLs: [URL] = []

    var store: DocumentStore? {
        didSet { flushPending() }
    }

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    /// Double-clicking a document in Finder, or `open -a Accomplice <file>`.
    func application(_ sender: NSApplication, open urls: [URL]) {
        pendingURLs.append(contentsOf: urls)
        flushPending()
    }

    private func flushPending() {
        guard let store, let url = pendingURLs.first else { return }
        pendingURLs.removeAll()
        store.open(url)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}
