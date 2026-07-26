import AccompliceCore
import AppKit
import SwiftUI

/// The canvas draws through `Renderer.draw(page:in:)` — the same call the exporter uses.
/// Screen and output can't disagree, which is the whole reason geometry lives in one place.
final class PageCanvas: NSView {

    var page: Page? { didSet { resize(); recompose(); needsDisplay = true } }
    var images: [String: Data] = [:] { didSet { needsDisplay = true } }
    var selectedID: String? { didSet { needsDisplay = true } }
    var onClick: ((CGPoint) -> Void)?

    /// Sketch's canvas is y-down; matching it means no coordinate flipping anywhere.
    override var isFlipped: Bool { true }

    private var bounds1: CGRect = .zero

    /// Composed once per page, not once per frame. See Renderer.draw(drawables:in:).
    private var composed: [Drawable] = []
    private var composedFor: String?

    private func recompose() {
        guard let page else { composed = []; composedFor = nil; return }
        guard composedFor != page.name || composed.isEmpty else { return }
        composed = Compose.flatten(page.layers)
        composedFor = page.name
    }

    private func resize() {
        guard let page else { bounds1 = .zero; return }
        bounds1 = page.contentBounds()
        setFrameSize(NSSize(width: max(1, bounds1.width), height: max(1, bounds1.height)))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // No page background. A Sketch-style canvas is infinite and unpainted — only
        // artboards have a colour. Filling the view white made every page look like one
        // big artboard and hid where the real ones start and stop.
        guard let page else { return }
        ctx.saveGState()
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high
        ctx.translateBy(x: -bounds1.minX, y: -bounds1.minY)
        Renderer(images: images).draw(drawables: composed, in: ctx)

        if let id = selectedID, let rect = frameOf(id, in: page.layers, base: .identity) {
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1.5 / max(0.01, currentScale))
            ctx.setLineDash(phase: 0, lengths: [4 / max(0.01, currentScale), 3 / max(0.01, currentScale)])
            ctx.stroke(rect.insetBy(dx: -1, dy: -1))
        }
        ctx.restoreGState()
    }

    private var currentScale: CGFloat {
        enclosingScrollView?.magnification ?? 1
    }

    /// Walks to the selected layer, accumulating transforms, and returns its canvas frame.
    private func frameOf(_ id: String, in layers: [Layer], base: CGAffineTransform) -> CGRect? {
        for l in layers {
            let t = Compose.transform(l).concatenating(base)
            if l.id == id {
                if let p = Compose.resolvedPath(l) { return p.transformed(by: t).boundingBoxOfPath }
                return CGRect(origin: .zero, size: l.frame.size).applying(t)
            }
            let kids: [Layer]
            switch l.kind {
            case .group(let k): kids = k
            case .shapeGroup(let k, _): kids = k
            default: kids = []
            }
            if let r = frameOf(id, in: kids, base: t) { return r }
        }
        return nil
    }

    /// Hit-tests against the cached composition rather than recomposing per click.
    func hitTest(_ point: CGPoint) -> Layer? {
        for d in composed.reversed() {
            if let p = d.path, p.contains(point) { return d.layer }
            if d.path == nil {
                let r = CGRect(origin: .zero, size: d.layer.frame.size).applying(d.transform)
                if r.contains(point) { return d.layer }
            }
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        onClick?(CGPoint(x: p.x + bounds1.minX, y: p.y + bounds1.minY))
    }
}

/// Keeps the page centred when it's smaller than the viewport. NSScrollView pins content
/// to the top-left otherwise, which reads as broken on a canvas.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposed)
        guard let doc = documentView else { return rect }
        let d = doc.frame
        if rect.width > d.width { rect.origin.x = (d.width - rect.width) / 2 }
        if rect.height > d.height { rect.origin.y = (d.height - rect.height) / 2 }
        return rect
    }
}

struct CanvasRepresentable: NSViewRepresentable {
    let page: Page?
    let images: [String: Data]
    @Binding var selectedID: String?
    let zoomToken: Int

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.contentView = CenteringClipView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.02
        scroll.maxMagnification = 40
        scroll.backgroundColor = .underPageBackgroundColor

        let canvas = PageCanvas()
        canvas.onClick = { [weak canvas] pt in
            selectedID = canvas?.hitTest(pt)?.id
        }
        scroll.documentView = canvas
        context.coordinator.canvas = canvas
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let canvas = context.coordinator.canvas else { return }
        let pageChanged = context.coordinator.lastPageName != page?.name
            || context.coordinator.lastZoomToken != zoomToken
        canvas.images = images
        canvas.page = page
        canvas.selectedID = selectedID
        canvas.onClick = { [weak canvas] pt in
            selectedID = canvas?.hitTest(pt)?.id
        }
        if pageChanged, let page {
            context.coordinator.lastPageName = page.name
            context.coordinator.lastZoomToken = zoomToken
            // Fit on arrival: these pages range from 180pt to 15,000pt wide, so a
            // fixed default zoom would be useless most of the time.
            let b = page.contentBounds()
            let vis = scroll.contentView.bounds.size
            if b.width > 0, b.height > 0, vis.width > 1, vis.height > 1 {
                // magnify(toFit:) both scales and scrolls, so the page lands centred
                // rather than jammed against the top-left.
                canvas.layoutSubtreeIfNeeded()
                scroll.magnify(toFit: canvas.bounds.insetBy(dx: -b.width * 0.04,
                                                           dy: -b.height * 0.04))
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var canvas: PageCanvas?
        var lastPageName: String?
        var lastZoomToken: Int = -1
    }
}
