import SketchyworksCore
import AppKit
import SwiftUI

// The page list, on an NSTableView for the same reason the layer list is on an
// NSOutlineView: SwiftUI's .onDrag competes with click handling on a macOS list row,
// so dragging works perhaps one time in five. AppKit runs a real dragging session and
// draws the insertion line itself.
//
// A table rather than an outline because pages are flat, and unlike layers they are
// NOT reversed — a page list reads top to bottom in the order the document stores.
/// A table that handles the delete key, so a selected page can be removed from the
/// keyboard the way a selected layer can.
final class DeletableTableView: NSTableView {
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117, selectedRow >= 0 {
            onDelete?()
            return
        }
        super.keyDown(with: event)
    }
}

struct PageListView: NSViewRepresentable {
    let pages: [DocumentSource.PageRef]
    let selected: Int
    let store: DocumentStore
    let onRename: (Int) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let table = DeletableTableView()
        table.onDelete = { [store] in
            // Guarded in the store: a document has to keep at least one page.
            store.deletePage(at: store.pageIndex)
        }
        table.headerView = nil
        table.rowSizeStyle = .small
        table.style = .sourceList
        table.backgroundColor = .clear
        table.rowHeight = 22
        table.focusRingType = .none
        table.allowsMultipleSelection = false

        let column = NSTableColumn(identifier: .init("page"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked)
        table.menu = context.coordinator.makeMenu()
        table.registerForDraggedTypes([Coordinator.pageType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        // The panel behind provides the colour; a list drawing its own leaves a
        // stripe of a different shade down the middle of the sidebar.
        scroll.drawsBackground = false
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let table = c.table else { return }
        if c.shown.map(\.name) != pages.map(\.name) || c.shown.count != pages.count {
            c.shown = pages
            table.reloadData()
        }
        if table.selectedRow != selected, pages.indices.contains(selected) {
            c.applying = true
            table.selectRowIndexes([selected], byExtendingSelection: false)
            c.applying = false
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let pageType = NSPasteboard.PasteboardType("com.sketchyworks.page")

        var parent: PageListView
        weak var table: NSTableView?
        var shown: [DocumentSource.PageRef] = []
        var applying = false

        init(_ parent: PageListView) { self.parent = parent }

        func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

        func tableView(_ t: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            guard shown.indices.contains(row) else { return nil }
            let page = shown[row]
            let id = NSUserInterfaceItemIdentifier("pageRow")
            let cell = (t.makeView(withIdentifier: id, owner: self) as? NSTableCellView)
                ?? Self.makeCell(id)
            cell.textField?.stringValue = page.name
            cell.setAccessibilityIdentifier("page-\(page.name)")
            cell.textField?.setAccessibilityIdentifier("page-\(page.name)")
            return cell
        }

        private static func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = id
            let name = NSTextField(labelWithString: "")
            name.translatesAutoresizingMaskIntoConstraints = false
            name.lineBreakMode = .byTruncatingTail
            name.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            cell.addSubview(name)
            cell.textField = name
            // The whole row is the name now. It used to end in a layer count,
            // which is a number you can't do anything with sitting where a long
            // page name wants to be.
            NSLayoutConstraint.activate([
                name.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                name.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                name.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table, !applying, table.selectedRow >= 0 else { return }
            parent.store.pageIndex = table.selectedRow
            parent.store.selection = []
        }

        // MARK: - Dragging

        func tableView(_ t: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            let entry = NSPasteboardItem()
            entry.setString(String(row), forType: Self.pageType)
            return entry
        }

        func tableView(_ t: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                       proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
            // Between rows only: dropping a page ONTO another page means nothing.
            guard op == .above else { return [] }
            return .move
        }

        func tableView(_ t: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                       dropOperation op: NSTableView.DropOperation) -> Bool {
            guard let text = info.draggingPasteboard.pasteboardItems?
                    .compactMap({ $0.string(forType: Self.pageType) }).first,
                  let from = Int(text) else { return false }
            // The drop row is where it goes BEFORE the removal, so dropping below the
            // page's own position lands one row too far.
            let to = row > from ? row - 1 : row
            return parent.store.movePage(from: from, to: to)
        }

        // MARK: - Menu and double-click

        @objc func doubleClicked() {
            guard let table, table.clickedRow >= 0 else { return }
            parent.onRename(table.clickedRow)
        }

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.delegate = self
            return menu
        }
    }
}

extension PageListView.Coordinator: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let table, table.clickedRow >= 0 else { return }
        let row = table.clickedRow
        parent.store.pageIndex = row

        func add(_ title: String, enabled: Bool = true, _ action: @escaping () -> Void) {
            let entry = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
            entry.target = self
            entry.isEnabled = enabled
            entry.representedObject = LayerOutline.Coordinator.Action(action)
            menu.addItem(entry)
        }
        add("Rename…") { self.parent.onRename(row) }
        add("Duplicate") { self.parent.store.duplicatePage() }
        menu.addItem(.separator())
        add("Delete", enabled: shown.count > 1) { self.parent.store.deletePage(at: row) }
    }

    @objc func run(_ sender: NSMenuItem) {
        (sender.representedObject as? LayerOutline.Coordinator.Action)?.run()
    }
}
