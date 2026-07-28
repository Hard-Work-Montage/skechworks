import Foundation

// Every keyboard shortcut in one list.
//
// They were spread across three files — SwiftUI menu builders, the canvas's keyDown,
// and the insert menu — with nothing checking them against each other. Two already
// collided (P was declared twice for the same action), and ⌘+ and ⌘= nearly did.
//
// This is the source of truth: the menus read their key equivalents from here, the
// canvas matches key codes against it, the cheat sheet is generated from it, and a
// test fails if two entries in overlapping contexts claim the same combination.

public struct Modifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = Modifiers(rawValue: 1 << 0)
    public static let shift = Modifiers(rawValue: 1 << 1)
    public static let option = Modifiers(rawValue: 1 << 2)
    public static let control = Modifiers(rawValue: 1 << 3)

    /// ⌃⌥⇧⌘ order, as macOS writes them.
    public var symbols: String {
        var s = ""
        if contains(.control) { s += "⌃" }
        if contains(.option) { s += "⌥" }
        if contains(.shift) { s += "⇧" }
        if contains(.command) { s += "⌘" }
        return s
    }
}

public struct Shortcut: Sendable, Identifiable, Hashable {
    /// Where the key is live. `app` is a menu item and works everywhere; `canvas`
    /// needs the canvas focused; `points` also needs a path open for editing.
    public enum Context: String, Sendable, CaseIterable {
        case app, canvas, points

        /// Two contexts can collide when one is active at the same time as the other.
        public func overlaps(_ other: Context) -> Bool {
            if self == other { return true }
            if self == .app || other == .app { return true }
            return true      // canvas and points are both live while editing a path
        }
    }

    public let id: String
    public let title: String
    /// What you press, as written on the key: "z", "+", "⌫", "→".
    public let key: String
    public let modifiers: Modifiers
    public let context: Context
    /// macOS virtual key codes this matches, for shortcuts the canvas handles itself.
    public let keyCodes: [UInt16]
    public let group: String

    public init(id: String, title: String, key: String, modifiers: Modifiers = [],
                context: Context = .app, keyCodes: [UInt16] = [], group: String) {
        self.id = id
        self.title = title
        self.key = key
        self.modifiers = modifiers
        self.context = context
        self.keyCodes = keyCodes
        self.group = group
    }

    public var display: String { modifiers.symbols + key.uppercased() }
}

public enum Shortcuts {

    public static let all: [Shortcut] = [
        // File
        .init(id: "new", title: "New", key: "N", modifiers: .command, group: "File"),
        .init(id: "open", title: "Open…", key: "O", modifiers: .command, group: "File"),
        .init(id: "close", title: "Close", key: "W", modifiers: .command, group: "File"),
        .init(id: "closeAll", title: "Close All", key: "W", modifiers: [.command, .option], group: "File"),
        .init(id: "save", title: "Save", key: "S", modifiers: .command, group: "File"),
        .init(id: "saveAs", title: "Save As…", key: "S", modifiers: [.command, .shift], group: "File"),
        .init(id: "exportPage", title: "Export Page as SVG…", key: "E", modifiers: .command, group: "File"),
        .init(id: "exportAll", title: "Export All Pages as SVG…", key: "E", modifiers: [.command, .shift], group: "File"),

        // Edit
        .init(id: "undo", title: "Undo", key: "Z", modifiers: .command, group: "Edit"),
        .init(id: "redo", title: "Redo", key: "Z", modifiers: [.command, .shift], group: "Edit"),
        .init(id: "cut", title: "Cut", key: "X", modifiers: .command, group: "Edit"),
        .init(id: "copy", title: "Copy", key: "C", modifiers: .command, group: "Edit"),
        .init(id: "paste", title: "Paste", key: "V", modifiers: .command, group: "Edit"),
        .init(id: "duplicate", title: "Duplicate", key: "D", modifiers: .command, group: "Edit"),
        .init(id: "selectAll", title: "Select All", key: "A", modifiers: .command, group: "Edit"),

        // View
        .init(id: "zoomIn", title: "Zoom In", key: "+", modifiers: .command, group: "View"),
        .init(id: "zoomOut", title: "Zoom Out", key: "-", modifiers: .command, group: "View"),
        .init(id: "actualSize", title: "Actual Size", key: "0", modifiers: .command, group: "View"),
        .init(id: "zoomFit", title: "Zoom to Fit", key: "1", modifiers: .command, group: "View"),
        .init(id: "zoomSelection", title: "Zoom to Selection", key: "2", modifiers: .command, group: "View"),

        // Insert
        .init(id: "insertArtboard", title: "Artboard", key: "A", modifiers: [.command, .shift], group: "Insert"),
        .init(id: "insertRect", title: "Rectangle", key: "R", context: .canvas, group: "Insert"),
        .init(id: "insertOval", title: "Oval", key: "O", context: .canvas, group: "Insert"),
        .init(id: "insertText", title: "Text", key: "T", context: .canvas, group: "Insert"),
        .init(id: "vector", title: "Vector", key: "P", context: .canvas, group: "Insert"),
        .init(id: "select", title: "Select", key: "V", context: .canvas, group: "Insert"),

        // Arrange
        .init(id: "bringForward", title: "Bring Forward", key: "]", modifiers: .command, group: "Arrange"),
        .init(id: "bringToFront", title: "Bring to Front", key: "]", modifiers: [.command, .option], group: "Arrange"),
        .init(id: "sendBackward", title: "Send Backward", key: "[", modifiers: .command, group: "Arrange"),
        .init(id: "sendToBack", title: "Send to Back", key: "[", modifiers: [.command, .option], group: "Arrange"),
        .init(id: "group", title: "Group", key: "G", modifiers: .command, group: "Arrange"),
        .init(id: "ungroup", title: "Ungroup", key: "G", modifiers: [.command, .shift], group: "Arrange"),
        .init(id: "mask", title: "Use as Mask", key: "M", modifiers: [.control, .command], group: "Arrange"),
        .init(id: "ignoreMask", title: "Ignore Mask", key: "I", modifiers: [.control, .command], group: "Arrange"),
        .init(id: "hide", title: "Hide/Show Layer", key: "H", modifiers: [.command, .shift], group: "Arrange"),

        // Tools
        .init(id: "ask", title: "Ask…", key: "K", modifiers: .command, group: "Tools"),

        // Canvas
        .init(id: "nudgeLeft", title: "Nudge Left", key: "←", context: .canvas,
              keyCodes: [123], group: "Canvas"),
        .init(id: "nudgeRight", title: "Nudge Right", key: "→", context: .canvas,
              keyCodes: [124], group: "Canvas"),
        .init(id: "nudgeDown", title: "Nudge Down", key: "↓", context: .canvas,
              keyCodes: [125], group: "Canvas"),
        .init(id: "nudgeUp", title: "Nudge Up", key: "↑", context: .canvas,
              keyCodes: [126], group: "Canvas"),
        .init(id: "nudgeFar", title: "Nudge by 10", key: "⇧←→↑↓", modifiers: .shift,
              context: .canvas, group: "Canvas"),
        .init(id: "deleteSelection", title: "Delete", key: "⌫", context: .canvas,
              keyCodes: [51, 117], group: "Canvas"),
        .init(id: "drillDown", title: "Select Inside a Group", key: "click",
              modifiers: [.command, .shift], context: .canvas, group: "Canvas"),

        // Vector editing
        .init(id: "finishPath", title: "Finish Path", key: "↩", context: .points,
              keyCodes: [36], group: "Editing Points"),
        .init(id: "cancel", title: "Cancel / Leave Editing", key: "⎋", context: .points,
              keyCodes: [53], group: "Editing Points"),
        .init(id: "addPoint", title: "Add Point", key: "=", context: .points,
              keyCodes: [24, 69], group: "Editing Points"),
        .init(id: "removePoint", title: "Remove Point", key: "-", context: .points,
              keyCodes: [27, 78], group: "Editing Points"),
        .init(id: "pointStraight", title: "Straight", key: "1", context: .points,
              keyCodes: [18], group: "Editing Points"),
        .init(id: "pointMirrored", title: "Mirrored", key: "2", context: .points,
              keyCodes: [19], group: "Editing Points"),
        .init(id: "pointAligned", title: "Aligned", key: "3", context: .points,
              keyCodes: [20], group: "Editing Points"),
        .init(id: "pointFree", title: "Free", key: "4", context: .points,
              keyCodes: [21], group: "Editing Points"),
        .init(id: "centrePoint", title: "Add Point Centred on the Segment", key: "⇧click",
              modifiers: .shift, context: .points, group: "Editing Points"),
    ]

    public static subscript(_ id: String) -> Shortcut {
        guard let s = all.first(where: { $0.id == id }) else {
            fatalError("no shortcut named \(id) — the registry is the source of truth")
        }
        return s
    }

    /// For the cheat sheet, in declaration order.
    public static var byGroup: [(String, [Shortcut])] {
        var order: [String] = []
        var map: [String: [Shortcut]] = [:]
        for s in all {
            if map[s.group] == nil { order.append(s.group) }
            map[s.group, default: []].append(s)
        }
        return order.map { ($0, map[$0]!) }
    }

    /// Pairs claiming the same keystroke where both could be live at once.
    ///
    /// Mouse gestures ("click") are excluded: a modifier-click and a keypress can't
    /// collide, and they're listed here only so the cheat sheet is complete.
    public static var collisions: [(Shortcut, Shortcut)] {
        var out: [(Shortcut, Shortcut)] = []
        let keys = all.filter { !$0.key.contains("click") }
        for i in keys.indices {
            for j in keys.index(after: i)..<keys.endIndex {
                let a = keys[i], b = keys[j]
                guard a.key.uppercased() == b.key.uppercased(), a.modifiers == b.modifiers,
                      a.context.overlaps(b.context) else { continue }
                out.append((a, b))
            }
        }
        return out
    }
}
