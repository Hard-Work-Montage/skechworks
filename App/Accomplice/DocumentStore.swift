import AccompliceCore
import AppKit
import Foundation

/// Holds the open document. Deliberately not an NSDocument yet — this is a viewer, and
/// there is nothing to save. The moment editing lands this should become one, because
/// NSDocument is where autosave and version browsing come from for free, and those are
/// the mitigation for a stripped .acmplc.png.
@MainActor
final class DocumentStore: ObservableObject {

    @Published var document: Document?
    @Published var images: [String: Data] = [:]
    @Published var url: URL?
    @Published var pageIndex = 0
    @Published var selectedLayerID: String?
    @Published var status: String = "Open an .acmplc.png or a .sketch file"
    @Published var isLoading = false
    @Published var fontWarnings: [(String, String)] = []

    var page: Page? {
        guard let d = document, d.pages.indices.contains(pageIndex) else { return nil }
        return d.pages[pageIndex]
    }

    func open(_ url: URL) {
        isLoading = true
        status = "Opening \(url.lastPathComponent)…"
        MissingFonts.reset()

        Task.detached(priority: .userInitiated) {
            var result: (Document, [String: Data])?
            var failure: String?

            // .acmplc.png first — it's the native format. A .sketch will fail this and
            // fall through, which is also how a PNG whose payload was stripped behaves,
            // so the message has to distinguish them.
            do {
                result = try AcmplcFile.read(url: url)
            } catch {
                if url.pathExtension.lowercased() == "sketch" {
                    var reader = SketchReader()
                    do {
                        let doc = try reader.read(url: url)
                        result = (doc, reader.images)
                    } catch {
                        failure = "\(error)"
                    }
                } else {
                    failure = "\(error)"
                }
            }

            let warnings = MissingFonts.all
            await MainActor.run { [result, failure] in
                self.isLoading = false
                self.fontWarnings = warnings
                guard let (doc, imgs) = result else {
                    self.status = failure ?? "Could not open \(url.lastPathComponent)"
                    NSSound.beep()
                    return
                }
                self.document = doc
                self.images = imgs
                self.url = url
                self.pageIndex = 0
                self.selectedLayerID = nil
                self.status = "\(doc.pages.count) page\(doc.pages.count == 1 ? "" : "s")"
                    + (doc.sourceApp.map { " · from \($0)" } ?? "")
            }
        }
    }

    func openPanel() {
        let p = NSOpenPanel()
        p.allowedContentTypes = []
        p.allowsOtherFileTypes = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = false
        p.message = "Open an Accomplice document (.acmplc.png) or a Sketch file"
        if p.runModal() == .OK, let u = p.url { open(u) }
    }

    // MARK: - Export

    func exportCurrentPage() {
        guard let page, let doc = document else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = slug(page.name) + ".svg"
        panel.message = "Export “\(page.name)” as SVG"
        guard panel.runModal() == .OK, let out = panel.url else { return }
        let svg = SVGWriter(images: images).svg(page: page)
        do {
            try Data(svg.utf8).write(to: out)
            status = "Exported \(out.lastPathComponent)"
        } catch {
            status = "Export failed: \(error.localizedDescription)"
        }
        _ = doc
    }

    func exportAllPages() {
        guard let doc = document else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Export all \(doc.pages.count) pages as SVG"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let w = SVGWriter(images: images)
        var n = 0
        for (i, p) in doc.pages.enumerated() {
            let f = dir.appendingPathComponent(String(format: "%03d-%@.svg", i, slug(p.name)))
            if (try? Data(w.svg(page: p).utf8).write(to: f)) != nil { n += 1 }
        }
        status = "Exported \(n) SVG\(n == 1 ? "" : "s")"
    }

    private func slug(_ s: String) -> String {
        let base = String(s.lowercased().map { ($0.isLetter || $0.isNumber) ? $0 : "-" })
            .split(separator: "-").joined(separator: "-")
        return base.isEmpty ? "page" : base
    }
}

// MARK: - Layer tree for display

struct LayerNode: Identifiable {
    let id: String
    let name: String
    let kindLabel: String
    let systemImage: String
    let isVisible: Bool
    let children: [LayerNode]?

    init(_ l: Layer) {
        id = l.id
        isVisible = l.isVisible
        switch l.kind {
        case .group(let k):
            kindLabel = "Group"; systemImage = "folder"
            children = k.isEmpty ? nil : k.map(LayerNode.init)
        case .shapeGroup(let k, _):
            kindLabel = "Combined"; systemImage = "square.on.circle"
            children = k.isEmpty ? nil : k.map(LayerNode.init)
        case .path:
            kindLabel = "Path"; systemImage = "scribble"; children = nil
        case .text(let t):
            kindLabel = t.string.replacingOccurrences(of: "\n", with: " ")
            systemImage = "textformat"; children = nil
        case .bitmap:
            kindLabel = "Image"; systemImage = "photo"; children = nil
        }
        name = l.name.isEmpty ? kindLabel : l.name
    }
}
