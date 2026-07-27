import AppKit
import AccompliceCore
import CoreGraphics
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
            .background(WindowTabbing(store: store))
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
    @StateObject private var recents = RecentDocuments.shared

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
                Menu("Open Recent") {
                    ForEach(recents.urls, id: \.self) { url in
                        Button(url.lastPathComponent) {
                            if let store = AppDelegate.shared?.active,
                               store.source != nil, store.url != nil {
                                // A window already holding a document gets a new tab
                                // rather than having its contents replaced.
                                AppDelegate.shared?.openInNewWindow(url)
                            } else {
                                AppDelegate.shared?.active?.open(url)
                            }
                        }
                    }
                    if !recents.urls.isEmpty {
                        Divider()
                        Button("Clear Menu") { recents.clear() }
                    }
                }
                .disabled(recents.urls.isEmpty)
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
            CommandMenu("Arrange") {
                Button("Bring Forward") { AppDelegate.shared?.active?.bringForward() }
                    .keyboardShortcut("]", modifiers: .command)
                Button("Bring to Front") { AppDelegate.shared?.active?.bringToFront() }
                    .keyboardShortcut("]", modifiers: [.command, .option])
                Button("Send Backward") { AppDelegate.shared?.active?.sendBackward() }
                    .keyboardShortcut("[", modifiers: .command)
                Button("Send to Back") { AppDelegate.shared?.active?.sendToBack() }
                    .keyboardShortcut("[", modifiers: [.command, .option])
                Divider()
                Menu("Align") {
                    Button("Left") { AppDelegate.shared?.active?.align(.left, "Left") }
                    Button("Horizontal Centres") { AppDelegate.shared?.active?.align(.horizontalCentre, "Centre") }
                    Button("Right") { AppDelegate.shared?.active?.align(.right, "Right") }
                    Divider()
                    Button("Top") { AppDelegate.shared?.active?.align(.top, "Top") }
                    Button("Vertical Middles") { AppDelegate.shared?.active?.align(.verticalMiddle, "Middle") }
                    Button("Bottom") { AppDelegate.shared?.active?.align(.bottom, "Bottom") }
                }
                Menu("Distribute") {
                    Button("Horizontally") { AppDelegate.shared?.active?.distribute(.horizontal, "Horizontally") }
                    Button("Vertically") { AppDelegate.shared?.active?.distribute(.vertical, "Vertically") }
                }
                Divider()
                Button("Group") { AppDelegate.shared?.active?.groupSelection() }
                    .keyboardShortcut("g", modifiers: .command)
                Button("Ungroup") { AppDelegate.shared?.active?.ungroupSelection() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Divider()
                Button("Hide/Show Layer") { AppDelegate.shared?.active?.toggleLockOrHide(hide: true) }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
            }
            CommandMenu("Tools") {
                Button("Ask…") { NotificationCenter.default.post(name: .showCommandBar, object: nil) }
                    .keyboardShortcut("k", modifiers: .command)
                Divider()
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
                Divider()
                Menu("Export Selected") {
                    ForEach(DocumentStore.ExportFormat.allCases) { f in
                        Menu(f.title) {
                            ForEach([1, 2, 3], id: \.self) { s in
                                Button("\(s)x") {
                                    AppDelegate.shared?.active?.exportSelected(format: f, scale: CGFloat(s))
                                }
                            }
                        }
                    }
                }
                Menu("Export Artboards") {
                    ForEach(DocumentStore.ExportFormat.allCases) { f in
                        Menu(f.title) {
                            ForEach([1, 2, 3], id: \.self) { s in
                                Button("\(s)x") {
                                    AppDelegate.shared?.active?.exportArtboards(format: f, scale: CGFloat(s))
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

extension Notification.Name {
    static let showCommandBar = Notification.Name("accomplice.showCommandBar")
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

    /// Opens a document in a fresh window (which macOS turns into a tab), leaving
    /// whatever is already open alone.
    func openInNewWindow(_ url: URL) {
        pendingURLs.append(url)
        if let item = NSApp.mainMenu?.items.first(where: { $0.title == "File" })?
            .submenu?.items.first(where: { $0.title == "New" }) {
            NSApp.sendAction(item.action!, to: item.target, from: item)
        }
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
