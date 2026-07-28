import AppKit

/// The modifier keys held at the most recent mouse-down.
///
/// Reading NSEvent.modifierFlags inside a SwiftUI tap handler asks what the keyboard
/// looks like NOW. That's fine until a row also has a double-tap gesture: SwiftUI then
/// delays the single tap to tell one from two, and by the time the handler runs the
/// key has been released — shift-clicking silently stops extending the selection.
///
/// NSApp.currentEvent doesn't help either; by then it isn't the click any more. A
/// monitor on mouse-down catches the flags at the only moment they're certain.
@MainActor
final class ClickModifiers {
    static let shared = ClickModifiers()

    private(set) var flags: NSEvent.ModifierFlags = []

    private init() {
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            MainActor.assumeIsolated { ClickModifiers.shared.flags = event.modifierFlags }
            return event
        }
    }

    var extendsSelection: Bool { flags.contains(.shift) || flags.contains(.command) }

    /// Called once at launch so the monitor exists before the first click.
    static func start() { _ = shared }
}
