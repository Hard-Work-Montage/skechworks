import AccompliceCore
import AppKit
import SwiftUI

// The layer list, as an NSOutlineView.
//
// It was a SwiftUI List with .onDrag, and dragging a row worked perhaps one time in
// five: no insertion line, nothing moved. That's a known macOS problem rather than
// something we were holding wrong — onDrag competes with the click handling on a List
// row, and the usual advice is either a dedicated drag handle or .onMove. Neither
// helps here: onMove can only reorder within one list, and this list has to drop a
// layer INTO a group.
//
// NSOutlineView is the control that hierarchy-with-dragging is made of. AppKit runs a
// real dragging session, so the drag starts every time; it draws the insertion line
// and the drop-on highlight itself; and it distinguishes "between two rows" from "onto
// that group" natively, which is the distinction the whole feature rests on.

/// An outline view that handles the delete key.
///
/// The SwiftUI list had .onDeleteCommand; NSOutlineView passes the key along the
/// responder chain instead, where nothing was listening — so delete worked with the
/// canvas focused and did nothing with the list focused, which is exactly backwards
/// from where you just clicked.
final class DeletableOutlineView: NSOutlineView {
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // 51 is delete, 117 is forward delete.
        if event.keyCode == 51 || event.keyCode == 117, !selectedRowIndexes.isEmpty {
            onDelete?()
            return
        }
        // Arrows nudge the selected layers, exactly as they do with the canvas
        // focused. The outline's own arrow behavior (walking rows) loses to this
        // deliberately: you just picked a layer, so arrows should MOVE it.
        if !selectedRowIndexes.isEmpty {
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            switch event.keyCode {
            case 123: AppDelegate.shared?.active?.nudge(dx: -step, dy: 0); return
            case 124: AppDelegate.shared?.active?.nudge(dx: step, dy: 0); return
            case 125: AppDelegate.shared?.active?.nudge(dx: 0, dy: step); return
            case 126: AppDelegate.shared?.active?.nudge(dx: 0, dy: -step); return
            default: break
            }
        }
        super.keyDown(with: event)
    }
}

/// A node the outline view can hold on to.
///
/// NSOutlineView identifies rows by object, so these have to be stable across
/// rebuilds — a fresh object per reload would collapse every group on every edit.
final class LayerItem: NSObject {
    let id: String
    var name: String
    var symbol: String
    var isVisible: Bool
    var isLocked: Bool
    var isContainer: Bool
    var children: [LayerItem]

    init(_ node: LayerNode) {
        id = node.id
        name = node.name
        symbol = node.systemImage
        isVisible = node.isVisible
        isLocked = node.isLocked
        children = (node.children ?? []).map(LayerItem.init)
        isContainer = node.children != nil
    }

    /// Copies new content onto the existing objects where the ids still match, so
    /// expanded groups stay expanded and the selection stays put.
    func merge(_ other: LayerItem) {
        name = other.name
        symbol = other.symbol
        isVisible = other.isVisible
        isLocked = other.isLocked
        isContainer = other.isContainer
        var byID = [String: LayerItem](uniqueKeysWithValues: children.map { ($0.id, $0) })
        children = other.children.map { incoming in
            if let existing = byID.removeValue(forKey: incoming.id) {
                existing.merge(incoming)
                return existing
            }
            return incoming
        }
    }
}

struct LayerOutline: NSViewRepresentable {
    let nodes: [LayerNode]
    let revision: Int
    @Binding var selection: Set<String>
    let store: DocumentStore

    func makeNSView(context: Context) -> NSScrollView {
        let outline = DeletableOutlineView()
        outline.onDelete = { [store] in store.deleteSelection() }
        outline.headerView = nil
        outline.rowSizeStyle = .small
        outline.indentationPerLevel = 14
        outline.allowsMultipleSelection = true
        outline.style = .sourceList
        outline.backgroundColor = .clear
        outline.usesAutomaticRowHeights = false
        outline.rowHeight = 22
        outline.focusRingType = .none

        let column = NSTableColumn(identifier: .init("layer"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column

        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.doubleClicked)
        outline.menu = context.coordinator.makeMenu()

        // One drag type: our own layer ids. Registering for it is what turns rows into
        // drag sources and the view into a drop target.
        outline.registerForDraggedTypes([Coordinator.layerType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        // The panel behind provides the colour; a list drawing its own leaves a
        // stripe of a different shade down the middle of the sidebar.
        scroll.drawsBackground = false
        context.coordinator.outline = outline
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let outline = c.outline else { return }

        if c.revision != revision || c.roots.isEmpty {
            c.revision = revision
            c.rebuild(nodes)
            outline.reloadData()
            c.restoreExpansion()
        }
        c.applySelection(selection)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {
        static let layerType = NSPasteboard.PasteboardType("com.accomplice.layer")

        var parent: LayerOutline
        weak var outline: NSOutlineView?
        var roots: [LayerItem] = []
        var revision = -1
        /// Ids of open groups, kept across reloads so editing doesn't collapse the tree.
        private var expanded: Set<String> = []
        private var applyingSelection = false

        init(_ parent: LayerOutline) { self.parent = parent }

        // MARK: - Tree

        /// Children as shown: reversed, because the model stores layers bottom-first
        /// and the list puts the front-most layer at the top.
        private func shown(_ item: LayerItem?) -> [LayerItem] {
            (item?.children ?? roots).reversed()
        }

        func rebuild(_ nodes: [LayerNode]) {
            let incoming = nodes.map(LayerItem.init)
            var byID = [String: LayerItem](uniqueKeysWithValues: roots.map { ($0.id, $0) })
            roots = incoming.map { fresh in
                if let existing = byID.removeValue(forKey: fresh.id) {
                    existing.merge(fresh)
                    return existing
                }
                return fresh
            }
        }

        func restoreExpansion() {
            guard let outline else { return }
            // Under test every group is open, so a test never has to click its way
            // down the tree before it can test anything.
            let openEverything = TestFixture.requested
            func walk(_ items: [LayerItem]) {
                for i in items {
                    if openEverything || expanded.contains(i.id) { outline.expandItem(i) }
                    walk(i.children)
                }
            }
            walk(roots)
        }

        // MARK: - Data source

        func outlineView(_ v: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            shown(item as? LayerItem).count
        }

        func outlineView(_ v: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            shown(item as? LayerItem)[index]
        }

        func outlineView(_ v: NSOutlineView, isItemExpandable item: Any) -> Bool {
            // Containers, empty or not — the way Finder gives an empty folder a triangle.
            // It's also the affordance that says something can be dropped in there.
            (item as? LayerItem)?.isContainer ?? false
        }

        // MARK: - Rows

        func outlineView(_ v: NSOutlineView, viewFor column: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? LayerItem else { return nil }
            let id = NSUserInterfaceItemIdentifier("row")
            let cell = (v.makeView(withIdentifier: id, owner: self) as? NSTableCellView)
                ?? Self.makeCell(id)
            cell.imageView?.image = NSImage(systemSymbolName: node.isLocked ? "lock.fill" : node.symbol,
                                            accessibilityDescription: nil)
            cell.textField?.stringValue = node.name
            // An empty container reads dimmer than a full one — the triangle stays
            // (it's the drop affordance), but the grey says there's nothing inside.
            let emptyContainer = node.isContainer && node.children.isEmpty
            cell.textField?.textColor = !node.isVisible ? .tertiaryLabelColor
                : emptyContainer ? .secondaryLabelColor : .labelColor
            cell.imageView?.contentTintColor = node.isVisible && !emptyContainer
                ? .secondaryLabelColor : .tertiaryLabelColor
            // On the text field as well: that's the element the accessibility tree
            // actually exposes for a table cell, and a UI test querying the row finds
            // nothing without it.
            cell.setAccessibilityIdentifier("layer-\(node.name)")
            cell.textField?.setAccessibilityIdentifier("layer-\(node.name)")
            return cell
        }

        private static func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = id
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            text.lineBreakMode = .byTruncatingTail
            text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            cell.addSubview(image)
            cell.addSubview(text)
            cell.imageView = image
            cell.textField = text
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 14),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        // MARK: - Selection

        /// The selection this coordinator last opened the tree for. Reveal only on a
        /// CHANGE: without this, every view update would re-expand a group the user
        /// just collapsed while something inside it stays selected.
        private var lastRevealed: Set<String> = []

        func applySelection(_ ids: Set<String>) {
            guard let outline, !applyingSelection else { return }
            // A layer picked on the canvas can live inside a collapsed artboard or
            // group — then it has no row to highlight and the list just looks
            // unresponsive. Open the way down to it first, the way Sketch does.
            if ids != lastRevealed {
                lastRevealed = ids
                revealAncestors(of: ids)
            }
            var rows = IndexSet()
            for row in 0..<outline.numberOfRows {
                if let item = outline.item(atRow: row) as? LayerItem, ids.contains(item.id) {
                    rows.insert(row)
                }
            }
            guard rows != outline.selectedRowIndexes else { return }
            applyingSelection = true
            outline.selectRowIndexes(rows, byExtendingSelection: false)
            if let first = rows.first { outline.scrollRowToVisible(first) }
            applyingSelection = false
        }

        private func revealAncestors(of ids: Set<String>) {
            guard let outline, !ids.isEmpty else { return }
            func walk(_ items: [LayerItem], _ trail: [LayerItem]) {
                for i in items {
                    if ids.contains(i.id) {
                        // Outermost first: a child can't expand until its parent has.
                        for a in trail { outline.expandItem(a) }
                    }
                    walk(i.children, trail + [i])
                }
            }
            walk(roots, [])
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard let outline, !applyingSelection else { return }
            let ids = outline.selectedRowIndexes.compactMap {
                (outline.item(atRow: $0) as? LayerItem)?.id
            }
            applyingSelection = true
            parent.selection = Set(ids)
            applyingSelection = false
        }

        func outlineViewItemDidExpand(_ n: Notification) {
            if let item = n.userInfo?["NSObject"] as? LayerItem { expanded.insert(item.id) }
        }

        func outlineViewItemDidCollapse(_ n: Notification) {
            if let item = n.userInfo?["NSObject"] as? LayerItem { expanded.remove(item.id) }
        }

        // MARK: - Dragging

        func outlineView(_ v: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let node = item as? LayerItem else { return nil }
            let entry = NSPasteboardItem()
            entry.setString(node.id, forType: Self.layerType)
            return entry
        }

        func outlineView(_ v: NSOutlineView, validateDrop info: NSDraggingInfo,
                         proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            let moving = dragged(from: info)
            guard !moving.isEmpty, let page = parent.store.page else { return [] }
            // Into itself or its own subtree would detach that branch from the document.
            if let target = item as? LayerItem {
                for id in moving where page.isInside(target.id, id) { return [] }
                // Only a container can take a layer dropped ONTO it.
                if index == NSOutlineViewDropOnItemIndex, !target.isContainer { return [] }
            }
            return .move
        }

        func outlineView(_ v: NSOutlineView, acceptDrop info: NSDraggingInfo,
                         item: Any?, childIndex index: Int) -> Bool {
            let moving = dragged(from: info)
            guard !moving.isEmpty else { return false }
            let parentItem = item as? LayerItem
            let siblings = (parentItem?.children ?? roots).count

            // AppKit counts from the top of the list; the model counts from the
            // bottom. Dropping ONTO a group means the top of its contents.
            let modelIndex = index == NSOutlineViewDropOnItemIndex
                ? siblings
                : LayerOrder.modelIndex(displayIndex: index, childCount: siblings)
            return parent.store.moveLayers(moving, into: parentItem?.id, at: modelIndex)
        }

        private func dragged(from info: NSDraggingInfo) -> [String] {
            info.draggingPasteboard.pasteboardItems?
                .compactMap { $0.string(forType: Self.layerType) } ?? []
        }

        // MARK: - Menu and double-click

        @objc func doubleClicked() {
            guard let outline, outline.clickedRow >= 0,
                  let item = outline.item(atRow: outline.clickedRow) as? LayerItem else { return }
            beginRename(item)
        }

        // MARK: - Inline rename

        /// Type, Enter, done — right in the row, the way Finder renames a file.
        /// A modal for a two-word name was ceremony.
        private var renamingID: String?
        private var nameBeforeEdit = ""

        func beginRename(_ item: LayerItem) {
            guard let outline else { return }
            let row = outline.row(forItem: item)
            guard row >= 0,
                  let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView,
                  let tf = cell.textField else { return }
            renamingID = item.id
            nameBeforeEdit = tf.stringValue
            tf.isEditable = true
            tf.delegate = self
            outline.window?.makeFirstResponder(tf)
            tf.selectText(nil)
        }

        func controlTextDidEndEditing(_ n: Notification) {
            guard let tf = n.object as? NSTextField else { return }
            tf.isEditable = false
            guard let id = renamingID else { return }
            renamingID = nil
            let name = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, name != nameBeforeEdit {
                parent.store.rename(id, to: name)
            } else {
                tf.stringValue = nameBeforeEdit    // empty or unchanged: put it back
            }
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy sel: Selector) -> Bool {
            guard sel == #selector(NSResponder.cancelOperation(_:)),
                  let tf = control as? NSTextField else { return false }
            // Escape: the edit never happened.
            renamingID = nil
            tf.stringValue = nameBeforeEdit
            tf.isEditable = false
            control.window?.makeFirstResponder(outline)
            return true
        }

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.delegate = self
            return menu
        }
    }
}

extension LayerOutline.Coordinator: NSMenuDelegate {
    /// Built fresh each time so the mask and visibility items read correctly for
    /// whatever was right-clicked.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let outline, outline.clickedRow >= 0,
              let item = outline.item(atRow: outline.clickedRow) as? LayerItem,
              let layer = parent.store.page?.layer(item.id) else { return }
        // Right-clicking something that isn't selected acts on it, not on the hidden
        // selection — that's how you delete the wrong layer.
        if !parent.store.selection.contains(item.id) { parent.selection = [item.id] }

        func add(_ title: String, _ action: @escaping () -> Void) {
            let entry = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = Action(action)
            menu.addItem(entry)
        }
        add("Rename…") { [weak self] in self?.beginRename(item) }
        add(item.isLocked ? "Unlock" : "Lock") { self.parent.store.toggleLock() }
        menu.addItem(.separator())
        add("Cut") { self.parent.store.cutSelection() }
        add("Copy") { self.parent.store.copySelection() }
        add("Paste") { self.parent.store.paste() }
        add("Duplicate") { self.parent.store.duplicateSelection() }
        menu.addItem(.separator())
        add("Group") { self.parent.store.groupSelection() }
        if item.isContainer { add("Ungroup") { self.parent.store.ungroupSelection() } }
        menu.addItem(.separator())
        add("Bring to Front") { self.parent.store.bringToFront() }
        add("Bring Forward") { self.parent.store.bringForward() }
        add("Send Backward") { self.parent.store.sendBackward() }
        add("Send to Back") { self.parent.store.sendToBack() }
        menu.addItem(.separator())
        add(layer.hasClippingMask ? "Remove Mask" : "Use as Mask") { self.parent.store.toggleMask() }
        add(layer.breaksMaskChain ? "Honour Mask" : "Ignore Mask") { self.parent.store.toggleIgnoreMask() }
        add(layer.isVisible ? "Hide Layer" : "Show Layer") {
            self.parent.store.toggleLockOrHide(hide: true)
        }
        menu.addItem(.separator())
        add("Delete") { self.parent.store.deleteSelection() }
    }

    final class Action: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }

    @objc func run(_ sender: NSMenuItem) {
        (sender.representedObject as? Action)?.run()
    }
}
