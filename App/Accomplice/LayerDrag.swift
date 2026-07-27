import AccompliceCore
import SwiftUI
import UniformTypeIdentifiers

/// The drag currently in flight, shared between the rows so they can draw the marker.
@MainActor
final class LayerDragState: ObservableObject {
    @Published var dragging: Set<String> = []
    @Published var spot: DropSpot?

    func clear() {
        dragging = []
        spot = nil
    }
}

/// Accepts a drop on one row, working out above/below/inside from the pointer.
struct LayerDropDelegate: DropDelegate {
    let rowID: String
    let isContainer: Bool
    let rowHeight: CGFloat
    @ObservedObject var state: LayerDragState
    let store: DocumentStore
    let expanded: Set<String>
    /// Opens a collapsed container being hovered, so you can drop inside one without
    /// having to expand it first.
    let expand: (String) -> Void

    func validateDrop(info: DropInfo) -> Bool { !state.dragging.isEmpty }

    func dropEntered(info: DropInfo) { update(info) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if state.spot?.target == rowID { state.spot = nil }
    }

    private func update(_ info: DropInfo) {
        // Dropping onto the thing you're dragging, or into its own subtree, is a
        // no-op at best; showing a marker for it would promise something false.
        guard !state.dragging.contains(rowID) else { state.spot = nil; return }
        if let page = store.page {
            for id in state.dragging where page.isInside(rowID, id) {
                state.spot = nil
                return
            }
        }
        let y = info.location.y
        let band = rowHeight / 3
        if isContainer, y > band, y < rowHeight - band {
            state.spot = .inside(rowID)
            if !expanded.contains(rowID) { expand(rowID) }
        } else {
            state.spot = y < rowHeight / 2 ? .above(rowID) : .below(rowID)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { state.clear() }
        guard let spot = state.spot, let page = store.page,
              let target = spot.resolve(in: page, expanded: expanded) else { return false }
        return store.moveLayers(Array(state.dragging), into: target.parent, at: target.index)
    }
}


/// Catches drops past the last row: move to the page itself, at the end.
///
/// Without this the only way out of a group is to find a top-level row to aim at,
/// and at the bottom of a long list there may not be one.
struct LayerRootDropDelegate: DropDelegate {
    @ObservedObject var state: LayerDragState
    let store: DocumentStore

    func validateDrop(info: DropInfo) -> Bool { !state.dragging.isEmpty }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        state.spot = nil
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { state.clear() }
        guard let page = store.page else { return false }
        return store.moveLayers(Array(state.dragging), into: nil, at: page.layers.count)
    }
}
