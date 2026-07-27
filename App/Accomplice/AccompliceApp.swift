import AppKit
import SwiftUI

/// One store per window.
///
/// The store used to live on the App, which meant every window shared a single
/// document — fine for a viewer, wrong the moment you can have two files open. Owning
/// it here gives each window (and therefore each macOS tab) its own document.
struct DocumentWindow: View {
    @StateObject private var store = DocumentStore()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentView()
            .environmentObject(store)
            .frame(minWidth: 900, minHeight: 560)
            .onAppear {
                AppDelegate.shared?.register(store)
                if store.source == nil && store.url == nil { store.newDocument() }
            }
            .onDisappear { AppDelegate.shared?.unregister(store) }
    }
}

@main
struct AccompliceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup(id: "document") {
            DocumentWindow()
        }
        Settings { SettingsView() }
        .commands {
            // Each window owns its own document now, so menu items act on whichever
            // one is frontmost rather than on a single app-wide store.
            CommandGroup(replacing: .newItem) {
                Button("New") { openWindow(id: "document") }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Open…") { AppDelegate.shared?.active?.openPanel() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            // Replace the stock undo items: SwiftUI's environment UndoManager isn't
            // the one driving document edits, so the built-ins would be inert.
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { AppDelegate.shared?.active?.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                Button("Redo") { AppDelegate.shared?.active?.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .pasteboard) {
                Button("Cut") { AppDelegate.shared?.active?.cutSelection() }
                    .keyboardShortcut("x", modifiers: .command)
                Button("Copy") { AppDelegate.shared?.active?.copySelection() }
                    .keyboardShortcut("c", modifiers: .command)
                Button("Paste") { AppDelegate.shared?.active?.paste() }
                    .keyboardShortcut("v", modifiers: .command)
                Button("Duplicate") { AppDelegate.shared?.active?.duplicateSelection() }
                    .keyboardShortcut("d", modifiers: .command)
                Divider()
                Button("Delete") { AppDelegate.shared?.active?.deleteSelection() }
                Button("Select All") { AppDelegate.shared?.active?.selectAll() }
                    .keyboardShortcut("a", modifiers: .command)
            }
            CommandMenu("Tools") {
                ForEach(DocumentStore.Tool.allCases, id: \.self) { t in
                    Button(t.title) { AppDelegate.shared?.active?.tool = t }
                        .keyboardShortcut(KeyEquivalent(Character(t == .select ? "v" : t == .pen ? "p" : "b")),
                                          modifiers: [])
                }
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { AppDelegate.shared?.active?.save() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Save As…") { AppDelegate.shared?.active?.saveAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("Export Page as SVG…") { AppDelegate.shared?.active?.exportCurrentPage() }
                    .keyboardShortcut("e", modifiers: .command)
                Button("Export All Pages as SVG…") { AppDelegate.shared?.active?.exportAllPages() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
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

    /// Every open window's store, most recently registered last.
    private var stores: [DocumentStore] = []

    /// Best guess at the frontmost document. Menu commands route here.
    var active: DocumentStore? { stores.last }

    func register(_ s: DocumentStore) {
        stores.removeAll { $0 === s }
        stores.append(s)
        flushPending()
    }

    func unregister(_ s: DocumentStore) {
        stores.removeAll { $0 === s }
    }

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        AppDelegate.shared = self
        // Reapply the chosen colourway; a signed bundle can't rewrite its own .icns,
        // so the choice only exists at runtime.
        AppIconTheme.current.apply()
    }

    func applicationWillFinishLaunching(_ n: Notification) {
        // Group extra windows into tabs rather than scattering them, which is what
        // Adam asked for and what every macOS document app does.
        NSWindow.allowsAutomaticWindowTabbing = true
    }

    /// Double-clicking a document in Finder, or `open -a Accomplice <file>`.
    func application(_ sender: NSApplication, open urls: [URL]) {
        pendingURLs.append(contentsOf: urls)
        flushPending()
    }

    private func flushPending() {
        guard let store = active, let url = pendingURLs.first else { return }
        pendingURLs.removeAll()
        store.open(url)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}
