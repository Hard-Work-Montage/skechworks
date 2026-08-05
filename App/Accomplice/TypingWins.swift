import AppKit

/// While someone is typing, plain letters are text — not shortcuts.
///
/// The canvas shortcuts are bare keys: R rectangle, O oval, T text, P pen, V
/// select, E erase. SwiftUI turns those into menu key equivalents, and AppKit
/// offers every keystroke to the menus BEFORE the responder chain — including
/// when the responder is a field editor. So renaming a layer in the sidebar
/// looked broken: the row went editable, the text highlighted, and typing did
/// nothing except quietly insert rectangles and swap tools behind the panel.
///
/// A local monitor is the only place early enough to intervene. When a field
/// editor is actively editing and no command, control or option is held, the
/// event goes straight to it and the menus never see it. Modified keys still
/// reach the menus, so ⌘S saves while you're renaming, and `fieldEditorHandled`
/// keeps ⌘C and friends doing the text thing inside a field.
@MainActor
enum TypingWins {
    private static var monitor: Any?

    static func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            // The verdict crosses the isolation boundary, not the event itself:
            // NSEvent isn't Sendable.
            let typed = MainActor.assumeIsolated { () -> Bool in
                // ⌘/⌃/⌥ combinations belong to the menus. Shift does not — it is
                // how capitals are typed.
                guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty
                else { return false }
                guard let editor = (event.window ?? NSApp.keyWindow)?.firstResponder as? NSTextView,
                      editor.isEditable else { return false }
                editor.keyDown(with: event)
                return true
            }
            return typed ? nil : event
        }
    }
}
