import AppKit
import SwiftUI

/// Up and down step a numeric field by 1, or 10 with shift.
///
/// It has to be an event monitor. `.onKeyPress(keys: [.upArrow, .downArrow])`
/// reads correctly and never fires on a focused text field, because the field
/// swallows the arrows to move its own caret before SwiftUI consults the
/// modifier — the colour fields carried that dead code for weeks.
///
/// The modifier owns its focus, so a caller only says what a step means.
private struct ArrowStepping: ViewModifier {
    let apply: (CGFloat) -> Void

    @FocusState private var focused: Bool
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .onChange(of: focused) { _, isFocused in isFocused ? start() : stop() }
            .onDisappear { stop() }
    }

    private func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            // NSEvent isn't Sendable, so only the verdict crosses back.
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard focused, event.keyCode == 125 || event.keyCode == 126,
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty
                else { return false }
                let size: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
                apply(event.keyCode == 126 ? size : -size)
                return true
            }
            return handled ? nil : event
        }
    }

    private func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }
}

extension View {
    /// Steps this field with the arrow keys: 1, or 10 with shift. Every numeric
    /// field in the app behaves this way.
    func stepsWithArrows(_ apply: @escaping (CGFloat) -> Void) -> some View {
        modifier(ArrowStepping(apply: apply))
    }
}
