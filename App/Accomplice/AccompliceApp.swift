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
                if store.source == nil && store.url == nil {
                    if TestFixture.requested {
                        store.adopt(TestFixture.document(), images: [:])
                    } else {
                        store.newDocument()
                    }
                }
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
                    .shortcut("new")
                Button("Open…") { AppDelegate.shared?.active?.openPanel() }
                    .shortcut("open")
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
                    .shortcut("undo")
                Button("Redo") { AppDelegate.shared?.active?.redo() }
                    .shortcut("redo")
            }
            CommandGroup(replacing: .pasteboard) {
                Button("Cut") { AppDelegate.shared?.active?.cutSelection() }
                    .shortcut("cut")
                Button("Copy") { AppDelegate.shared?.active?.copySelection() }
                    .shortcut("copy")
                Button("Paste") { AppDelegate.shared?.active?.paste() }
                    .shortcut("paste")
                Button("Duplicate") { AppDelegate.shared?.active?.duplicateSelection() }
                    .shortcut("duplicate")
                Divider()
                Button("Delete") { AppDelegate.shared?.active?.deleteSelection() }
                Button("Select All") { AppDelegate.shared?.active?.selectAll() }
                    .shortcut("selectAll")
            }
            // Sketch's zoom shortcuts, since that's the muscle memory coming in.
            CommandGroup(before: .sidebar) {
                Button("Zoom In") { AppDelegate.shared?.active?.zoom(.zoomIn) }
                    .shortcut("zoomIn")
                Button("Zoom Out") { AppDelegate.shared?.active?.zoom(.zoomOut) }
                    .shortcut("zoomOut")
                Button("Actual Size") { AppDelegate.shared?.active?.zoom(.actualSize) }
                    .shortcut("actualSize")
                Button("Zoom to Fit") { AppDelegate.shared?.active?.zoom(.fit) }
                    .shortcut("zoomFit")
                Button("Zoom to Selection") { AppDelegate.shared?.active?.zoom(.toSelection) }
                    .shortcut("zoomSelection")
                Divider()
            }
            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") { ShortcutsWindow.show() }
                    .keyboardShortcut("/", modifiers: [.command, .shift])
            }
            CommandGroup(after: .newItem) {
                Divider()
                Button("New Page") { AppDelegate.shared?.active?.addPage() }
                    .shortcut("newPage")
                Button("Duplicate Page") { AppDelegate.shared?.active?.duplicatePage() }
            }
            CommandMenu("Path") {
                Button("Union") { AppDelegate.shared?.active?.combineSelection(.union) }
                    .shortcut("union")
                Button("Subtract") { AppDelegate.shared?.active?.combineSelection(.subtract) }
                    .shortcut("subtract")
                Button("Intersect") { AppDelegate.shared?.active?.combineSelection(.intersect) }
                    .shortcut("intersect")
                Button("Difference") { AppDelegate.shared?.active?.combineSelection(.difference) }
                    .shortcut("difference")
                Divider()
                Button("Flatten") { AppDelegate.shared?.active?.flattenSelection() }
                    .shortcut("flatten")
                Divider()
                // Three named strengths rather than a tolerance box: the useful
                // question is "how much do I mind it moving", not a number in points.
                Button("Simplify — Light") { AppDelegate.shared?.active?.simplifySelection(detail: 0.8) }
                Button("Simplify — Medium") { AppDelegate.shared?.active?.simplifySelection(detail: 0.5) }
                Button("Simplify — Strong") { AppDelegate.shared?.active?.simplifySelection(detail: 0.25) }
            }
            CommandMenu("Arrange") {
                Button("Bring Forward") { AppDelegate.shared?.active?.bringForward() }
                    .shortcut("bringForward")
                Button("Bring to Front") { AppDelegate.shared?.active?.bringToFront() }
                    .shortcut("bringToFront")
                Button("Send Backward") { AppDelegate.shared?.active?.sendBackward() }
                    .shortcut("sendBackward")
                Button("Send to Back") { AppDelegate.shared?.active?.sendToBack() }
                    .shortcut("sendToBack")
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
                    .shortcut("group")
                Button("Ungroup") { AppDelegate.shared?.active?.ungroupSelection() }
                    .shortcut("ungroup")
                Divider()
                Button("Use as Mask") { AppDelegate.shared?.active?.toggleMask() }
                    .shortcut("mask")
                Button("Ignore Mask") { AppDelegate.shared?.active?.toggleIgnoreMask() }
                    .shortcut("ignoreMask")
                Divider()
                Button("Hide/Show Layer") { AppDelegate.shared?.active?.toggleLockOrHide(hide: true) }
                    .shortcut("hide")
            }
            CommandMenu("Tools") {
                Button("Ask…") { NotificationCenter.default.post(name: .showCommandBar, object: nil) }
                    .shortcut("ask")
                Divider()
                Button("Select") { AppDelegate.shared?.active?.tool = .select }
                    .shortcut("select")
                Button("Vector") { AppDelegate.shared?.active?.tool = .pen }
                    .shortcut("vector")
                Button("Erase") { AppDelegate.shared?.active?.tool = .erase }
                    .shortcut("erase")
            }
            CommandGroup(replacing: .saveItem) {
                // Close lives in this placement too, not in .newItem — replacing the
                // group to add the export items quietly deleted it, so ⌘W had no menu
                // item to fire and the window delegate's save prompt could never run.
                Button("Close") { NSApp.keyWindow?.performClose(nil) }
                    .shortcut("close")
                Button("Close All") {
                    // Each still goes through performClose, so an edited tab gets its
                    // prompt rather than being discarded silently.
                    for w in NSApp.windows where w.isVisible && w.canBecomeMain {
                        w.performClose(nil)
                    }
                }
                .shortcut("closeAll")
                Divider()
                Button("Save") { AppDelegate.shared?.active?.save() }
                    .shortcut("save")
                Button("Save As…") { AppDelegate.shared?.active?.saveAs() }
                    .shortcut("saveAs")
                Divider()
                Button("Export Page as SVG…") { AppDelegate.shared?.active?.exportCurrentPage() }
                    .shortcut("exportPage")
                Button("Export All Pages as SVG…") { AppDelegate.shared?.active?.exportAllPages() }
                    .shortcut("exportAll")
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
        newDocumentWindow()
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
        ClickModifiers.start()
        if UserDefaults.standard.object(forKey: "mcp.enabled") as? Bool ?? true {
            MCPServer.shared.start()
        }
        // Quit with every tab closed and macOS restores exactly that: an app running
        // with no window and no obvious way to get one back. Open a document if the
        // restore left us with nothing.
        DispatchQueue.main.async { [weak self] in self?.openWindowIfNoneRestored() }
    }

    private func openWindowIfNoneRestored() {
        let hasDocument = NSApp.windows.contains {
            $0.tabbingIdentifier == WindowTabbing.identifier && $0.isVisible
        }
        guard !hasDocument else { return }
        newDocumentWindow()
    }

    /// Clicking the Dock icon with no windows open should give you one back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newDocumentWindow() }
        return true
    }

    /// Drives the File ▸ New menu item, which is the only thing that can ask SwiftUI
    /// for another WindowGroup window from here.
    func newDocumentWindow() {
        guard let item = NSApp.mainMenu?.items.first(where: { $0.title == "File" })?
            .submenu?.items.first(where: { $0.title == "New" }), let action = item.action else { return }
        NSApp.sendAction(action, to: item.target, from: item)
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
