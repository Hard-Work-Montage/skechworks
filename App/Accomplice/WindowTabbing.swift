import AppKit
import SwiftUI

/// Makes every document window join one tab group.
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

    func makeNSView(context: Context) -> NSView {
        let probe = NSView(frame: .zero)
        // The view has no window until it's in the hierarchy, so configure on the next
        // turn of the run loop.
        DispatchQueue.main.async { configure(probe.window) }
        return probe
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.tabbingMode = .preferred
        window.tabbingIdentifier = Self.identifier

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
