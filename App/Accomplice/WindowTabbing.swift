import AppKit
import SwiftUI

/// Makes every document window join one tab group, and guards closing an edited one.
///
/// SwiftUI's WindowGroup opens a separate window per document and leaves tabbing to
/// the system preference (Desktop & Dock ▸ "Prefer tabs when opening documents"),
/// which defaults to Full Screen Only — so ⌘N usually gives you a loose window. Both
/// halves are needed to fix that reliably:
///
///   - `tabbingMode = .preferred` and a shared `tabbingIdentifier` tell AppKit these
///     windows belong together, regardless of the user's preference.
///   - explicitly calling `addTabbedWindow` covers the case where the window is
///     already on screen by the time we get hold of it, which is the normal path
///     through SwiftUI.
struct WindowTabbing: NSViewRepresentable {

    static let identifier = NSWindow.TabbingIdentifier("com.accomplice.document")

    let store: DocumentStore

    func makeNSView(context: Context) -> NSView {
        let probe = NSView(frame: .zero)
        // The view has no window until it's in the hierarchy, so configure on the next
        // turn of the run loop.
        DispatchQueue.main.async { configure(probe.window, coordinator: context.coordinator) }
        return probe
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // The dot in the close button, for free.
        nsView.window?.isDocumentEdited = store.isDirty
        context.coordinator.store = store
    }

    func makeCoordinator() -> CloseGuard { CloseGuard(store: store) }

    private func configure(_ window: NSWindow?, coordinator: CloseGuard) {
        guard let window else { return }
        window.tabbingMode = .preferred
        window.tabbingIdentifier = Self.identifier
        window.isDocumentEdited = store.isDirty

        if window.delegate !== coordinator {
            coordinator.previous = window.delegate
            window.delegate = coordinator
        }

        // Already grouped with something? Leave it alone.
        if let group = window.tabGroup, group.windows.count > 1 { return }

        let host = NSApp.windows.first { other in
            other !== window
                && other.tabbingIdentifier == Self.identifier
                && other.isVisible
                && !other.isMiniaturized
        }
        guard let host else { return }   // first document window; nothing to join yet
        host.addTabbedWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
    }
}

/// Intercepts ⌘W on a document with unsaved changes.
///
/// SwiftUI already installs its own window delegate, so this one forwards everything
/// it doesn't handle rather than replacing it — otherwise the window loses behaviour
/// that has nothing to do with closing.
@MainActor
final class CloseGuard: NSObject, NSWindowDelegate {

    weak var previous: NSWindowDelegate?
    var store: DocumentStore?

    init(store: DocumentStore) {
        self.store = store
        super.init()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let store, store.isDirty else { return true }

        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes made to “\(store.displayName)”?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: sender) { response in
            MainActor.assumeIsolated {
                switch response {
                case .alertFirstButtonReturn:
                    // Only close if the bytes actually landed — an untitled document
                    // goes through Save As, and cancelling that must not lose the work.
                    store.save { saved in if saved { sender.close() } }
                case .alertSecondButtonReturn:
                    store.discardChanges()
                    sender.close()
                default:
                    break   // Cancel: stay open
                }
            }
        }
        return false   // the sheet decides
    }

    // MARK: - Pass everything else back to SwiftUI's delegate

    override func responds(to aSelector: Selector!) -> Bool {
        if aSelector == #selector(windowShouldClose(_:)) { return true }
        return super.responds(to: aSelector) || (previous?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if aSelector == #selector(windowShouldClose(_:)) { return nil }
        return previous
    }
}
