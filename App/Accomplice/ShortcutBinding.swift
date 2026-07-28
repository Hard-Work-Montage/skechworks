import AccompliceCore
import AppKit
import SwiftUI

// Binds menu items to the registry, so a shortcut is declared once.
//
// The alternative is what this replaced: key equivalents typed into each menu builder
// with nothing checking them against each other, which is how P ended up declared
// twice and how ⌘+ and ⌘= nearly collided.

extension View {
    /// Applies the registered shortcut for an action id.
    func shortcut(_ id: String) -> some View {
        let s = Shortcuts[id]
        return keyboardShortcut(KeyEquivalent(Character(s.key)), modifiers: s.swiftUIModifiers)
    }
}

extension Shortcut {
    var swiftUIModifiers: SwiftUI.EventModifiers {
        var m: SwiftUI.EventModifiers = []
        if modifiers.contains(.command) { m.insert(.command) }
        if modifiers.contains(.shift) { m.insert(.shift) }
        if modifiers.contains(.option) { m.insert(.option) }
        if modifiers.contains(.control) { m.insert(.control) }
        return m
    }
}

/// The cheat sheet, generated from the registry rather than written out again.
struct ShortcutsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Shortcuts.byGroup, id: \.0) { group, items in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(group.uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary).tracking(0.6)
                        ForEach(items) { s in
                            HStack {
                                Text(s.title)
                                Spacer()
                                Text(s.display)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        }
                    }
                }
            }
            .padding(22)
        }
        .frame(width: 420, height: 560)
    }
}

/// A plain panel for the cheat sheet. A Settings tab would bury it, and it wants to
/// stay open beside the canvas while you learn the keys.
@MainActor
enum ShortcutsWindow {
    private static var window: NSWindow?

    static func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
                         styleMask: [.titled, .closable, .utilityWindow],
                         backing: .buffered, defer: false)
        w.title = "Keyboard Shortcuts"
        w.contentView = NSHostingView(rootView: ShortcutsView())
        w.center()
        w.isReleasedWhenClosed = false
        window = w
        w.makeKeyAndOrderFront(nil)
    }
}
