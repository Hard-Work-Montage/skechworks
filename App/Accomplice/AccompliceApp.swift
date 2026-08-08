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
                // Before the views read their @AppStorage, not after.
                TestFixture.resetLayoutPreferences()
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
                            AppDelegate.shared?.openSomewhere(url)
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
            // Replacing the pasteboard group takes these shortcuts away from text
            // fields too — the menu fires before the field ever sees the key. So
            // each action asks first: is someone typing? A focused field gets the
            // text behaviour; otherwise the canvas gets the layer behaviour.
            CommandGroup(replacing: .pasteboard) {
                Button("Cut") {
                    if !Self.fieldEditorHandled(#selector(NSText.cut(_:))) {
                        AppDelegate.shared?.active?.cutSelection()
                    }
                }
                .shortcut("cut")
                Button("Copy") {
                    if !Self.fieldEditorHandled(#selector(NSText.copy(_:))) {
                        AppDelegate.shared?.active?.copySelection()
                    }
                }
                .shortcut("copy")
                Button("Paste") {
                    if !Self.fieldEditorHandled(#selector(NSText.paste(_:))) {
                        AppDelegate.shared?.active?.paste()
                    }
                }
                .shortcut("paste")
                Button("Paste at Selection") { AppDelegate.shared?.active?.pasteAtSelection() }
                    .shortcut("pasteAtSelection")
                Button("Duplicate") { AppDelegate.shared?.active?.duplicateSelection() }
                    .shortcut("duplicate")
                Divider()
                Button("Delete") { AppDelegate.shared?.active?.deleteSelection() }
                Button("Select All") {
                    if !Self.fieldEditorHandled(#selector(NSText.selectAll(_:))) {
                        AppDelegate.shared?.active?.selectAll()
                    }
                }
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
                Button("Convert to Outlines") { AppDelegate.shared?.active?.convertToOutlines() }
                    .keyboardShortcut("o", modifiers: [.command, .option])
                Button("Flatten") { AppDelegate.shared?.active?.flattenSelection() }
                    .shortcut("flatten")
                Divider()
                // Three named strengths rather than a tolerance box: the useful
                // question is "how much do I mind it moving", not a number in points.
                Menu("Simplify") {
                    Button("Light") { AppDelegate.shared?.active?.simplifySelection(detail: 0.8) }
                    Button("Medium") { AppDelegate.shared?.active?.simplifySelection(detail: 0.5) }
                    Button("Strong") { AppDelegate.shared?.active?.simplifySelection(detail: 0.25) }
                }
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
                    Button("Horizontal Centers") { AppDelegate.shared?.active?.align(.horizontalCentre, "Center") }
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
                Button("Flip Horizontal") { AppDelegate.shared?.active?.flipSelection(horizontal: true) }
                Button("Flip Vertical") { AppDelegate.shared?.active?.flipSelection(horizontal: false) }
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
                Button("Lock/Unlock Layer") { AppDelegate.shared?.active?.toggleLock() }
                    .shortcut("lock")
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
                Divider()
                // The two that call a model, set apart the way Adam asked.
                Section("AI Tools") {
                    Button("Remove") { AppDelegate.shared?.active?.beginRemove() }
                    Button("Vectorize Image") { AppDelegate.shared?.active?.vectorizeSelection() }
                    Button("AI Draw") { AppDelegate.shared?.active?.aiDrawSelection() }
                }
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

extension AccompliceApp {
    /// Performs a text-editing selector on the focused field editor, if someone
    /// is typing. False means nothing was focused and the layer action should run.
    @MainActor
    static func fieldEditorHandled(_ selector: Selector) -> Bool {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return false }
        editor.perform(selector, with: nil)
        return true
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

    /// The document the user is looking at. Resolved through the key window — with
    /// two tabs open, "whichever store registered last" was the hidden tab as often
    /// as not, and ⌘V pasted into a document you couldn't see.
    var active: DocumentStore? {
        if let key = NSApp.keyWindow ?? NSApp.mainWindow,
           let match = stores.last(where: { $0.window === key }) {
            return match
        }
        return stores.last
    }

    /// Whether any window has registered yet. Launch accounting needs to know if
    /// the initial SwiftUI window is still on its way: it always comes, so it can
    /// carry one pending document — asking for a window for that document too is
    /// exactly how the spare untitled tab got minted.
    private var anyWindowRegistered = false

    func register(_ s: DocumentStore) {
        stores.removeAll { $0 === s }
        stores.append(s)
        anyWindowRegistered = true
        flushPending()
    }

    func unregister(_ s: DocumentStore) {
        stores.removeAll { $0 === s }
        recordSession()
    }

    /// Opens a document in a fresh window (which macOS turns into a tab), leaving
    /// whatever is already open alone.
    func openInNewWindow(_ url: URL) {
        pendingURLs.append(url)
        // Through the queue rather than straight to a new window, so this gets
        // the same two checks Finder opens get: a file already open comes
        // forward instead of opening twice, and an empty tab elsewhere is used
        // before another one is minted.
        flushPending()
    }

    /// Puts a document on screen without taking one off. The window in front
    /// takes it only if it is a blank slate; otherwise the file gets its own
    /// tab. Every menu that opens something goes through here.
    func openSomewhere(_ url: URL) {
        if let store = active, store.isVacant {
            store.open(url)
        } else {
            openInNewWindow(url)
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
        ClickModifiers.start()
        TypingWins.start()
        if UserDefaults.standard.object(forKey: "mcp.enabled") as? Bool ?? true {
            MCPServer.shared.start()
        }
        // Quit with every tab closed and macOS restores exactly that: an app running
        // with no window and no obvious way to get one back. Open a document if the
        // restore left us with nothing.
        //
        // Window accounting happens HERE, once, after every source of launch work
        // (Finder opens, recoveries, session restore) has queued up. One window per
        // job, minus the windows that already exist empty and the initial SwiftUI
        // window if it hasn't shown up yet — it always does, and double-counting it
        // is what used to leave a spare untitled tab behind.
        // A UI test launches into the fixture and nothing else: restoring the real
        // session would drop the last-open document on top of it (which is exactly
        // how the fixture "failed to load"), and a test's autosaves must never land
        // in the real recovery folder where they could hijack the next launch.
        if TestFixture.requested {
            DocumentStore.recoveryDirOverride = FileManager.default.temporaryDirectory
                .appendingPathComponent("AccompliceUITestRecovery", isDirectory: true)
            sessionRestoreComplete = true
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let restored = self.restoreRecoveredDocuments()
            self.reopenLastSession(skipping: restored)
            let jobs = self.pendingURLs.count + self.pendingRecoveries.count
            let empties = self.stores.filter { $0.url == nil && !$0.isDirty }.count
            let inevitable = self.anyWindowRegistered ? 0 : 1
            let needed = max(0, jobs - empties - inevitable)
            for _ in 0..<needed { self.newDocumentWindow() }
            self.flushPending()
            DispatchQueue.main.async { self.openWindowIfNoneRestored() }
        }
    }

    /// Unsaved work from the last run — a quit without saving, a crash, a kill —
    /// comes back as dirty documents, one window each. Returns the original file
    /// paths those recoveries carry, so session reopen doesn't double them.
    private var pendingRecoveries: [DocumentStore.Recovery] = []
    @discardableResult
    private func restoreRecoveredDocuments() -> Set<String> {
        let found = DocumentStore.pendingRecoveries()
        guard !found.isEmpty else { return [] }
        // Two hard-won rules, from the night three stale snapshots of one document
        // hijacked a launch and hid a save that was already on disk:
        //
        // 1. A snapshot no newer than its original's last save is SUPERSEDED — the
        //    save won. Restoring it replaced good on-disk work with a stale copy.
        // 2. Several snapshots of the same original (duplicate tabs) collapse to
        //    the newest one; restoring all three made three windows of one file.
        let fm = FileManager.default
        func mtime(_ u: URL?) -> Date {
            (u.flatMap { try? fm.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date })
                ?? .distantPast
        }
        var newestByOriginal: [String: DocumentStore.Recovery] = [:]
        var untitled: [DocumentStore.Recovery] = []
        for r in found {
            guard let key = r.original?.path else { untitled.append(r); continue }
            if mtime(r.original) >= mtime(r.snapshot) {
                DocumentStore.discardRecovery(r)
                continue
            }
            if let prev = newestByOriginal[key] {
                if mtime(r.snapshot) > mtime(prev.snapshot) {
                    DocumentStore.discardRecovery(prev)
                    newestByOriginal[key] = r
                } else {
                    DocumentStore.discardRecovery(r)
                }
            } else {
                newestByOriginal[key] = r
            }
        }
        let kept = untitled + Array(newestByOriginal.values)
        pendingRecoveries.append(contentsOf: kept)
        // Windows are requested by the launch accounting in
        // applicationDidFinishLaunching, which sees every job at once. Only KEPT
        // recoveries suppress the session reopen — a superseded snapshot must not
        // stop the real file from opening.
        return Set(kept.compactMap { $0.original?.path })
    }

    // MARK: - Session restore

    /// Which files were open, refreshed as documents open, close and save, and
    /// snapshotted again at quit. Launch reopens them, so quitting with three
    /// files up brings the same three back.
    private static let sessionKey = "session.openDocuments"
    private var sessionRestoreComplete = false

    private var terminating = false

    func recordSession() {
        // Never clobber the list mid-launch, and never during quit — windows
        // unregister one by one on the way out, and each rewrite emptied the
        // list before termination could snapshot it.
        guard sessionRestoreComplete, !terminating else { return }
        writeSession()
    }

    private func writeSession() {
        // A test run must not rewrite what the person had open.
        guard !TestFixture.requested else { return }
        UserDefaults.standard.set(stores.compactMap { $0.url?.path }, forKey: Self.sessionKey)
    }

    /// Quit begins: freeze the list and snapshot it while every window is
    /// still standing.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        terminating = true
        writeSession()
        // The recovery net writes on a background queue; quitting killed whatever
        // was still queued, and the throttle meant the last edits might not even
        // be queued yet. Snapshot every dirty document NOW and wait for the disk.
        for s in stores where s.isDirty { s.autosaveNow() }
        // Conversations are written a moment after they settle, so a quit can
        // land inside that moment. Every document flushes its own now.
        for s in stores { s.chat.keep() }
        DocumentStore.flushRecoveryQueueForTesting()
        return .terminateNow
    }

    private func reopenLastSession(skipping restored: Set<String>) {
        let paths = UserDefaults.standard.stringArray(forKey: Self.sessionKey) ?? []
        for path in paths where !restored.contains(path) {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            // A document that arrived by double-click is in the session list too —
            // reopening it here is how one file became two tabs.
            guard !pendingURLs.contains(where: { $0.path == path }),
                  !stores.contains(where: { $0.url?.path == path }) else { continue }
            pendingURLs.append(URL(fileURLWithPath: path))
        }
        sessionRestoreComplete = true
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

    /// Hands queued work to empty windows only. A window showing a document keeps
    /// it — pending files never overwrite the tab you're looking at.
    /// A window has been asked for and hasn't appeared yet, so the next thing
    /// that can't be placed waits for it rather than asking again.
    private var awaitingWindow = false

    private func flushPending() {
        while !pendingURLs.isEmpty {
            let next = pendingURLs[0]
            // Already open: focus that window instead of minting a duplicate tab.
            // Duplicate tabs of one file are how three competing recovery
            // snapshots of the same document came to exist.
            if let existing = stores.last(where: { $0.url == next }) {
                pendingURLs.removeFirst()
                existing.window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                continue
            }
            guard let empty = stores.last(where: \.isVacant) else {
                // Nothing to load into. Ask for a window and come back when it
                // registers, rather than leaving the file queued forever — a
                // document that never appears is indistinguishable from the app
                // ignoring you, which is exactly what it looked like.
                if !awaitingWindow {
                    awaitingWindow = true
                    newDocumentWindow()
                }
                return
            }
            awaitingWindow = false
            empty.open(pendingURLs.removeFirst())
            // Opening a file from Finder should put you in front of it. Without
            // this the document loaded into a tab behind whatever you were
            // looking at, and nothing appeared to happen.
            empty.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        // One recovery per fresh window: only an untitled, untouched window takes
        // one — never a document mid-edit.
        while !pendingRecoveries.isEmpty,
              let empty = stores.last(where: \.isVacant) {
            empty.restoreFromRecovery(pendingRecoveries.removeFirst())
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}
