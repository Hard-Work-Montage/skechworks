import AppKit
import ImageIO
import SwiftUI

/// The app icon's colourway.
///
/// macOS won't let a signed bundle rewrite its own .icns, so a chosen colour is
/// applied at runtime via `NSApp.applicationIconImage` and reapplied on launch. The
/// bundled default (gradient) is what Finder shows before the app has ever run.
enum AppIconTheme: String, CaseIterable, Identifiable {
    case gradient, rainbow, blue, purple, pink, red, green, gold, camo, black, gray, white

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gradient: return "Iridescent"
        case .gray: return "Silver"
        default: return rawValue.capitalized
        }
    }

    var image: NSImage? {
        guard let url = Bundle.main.url(forResource: rawValue, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }

    /// A properly resampled thumbnail.
    ///
    /// The masters are 1024px. Handing one to SwiftUI and asking for 60pt makes it
    /// reduce by ~17x in a single step, which aliases into visible jaggies no amount
    /// of `.interpolation(.high)` fixes. ImageIO's thumbnail path does a real
    /// multi-step downsample, so edges stay smooth.
    func thumbnail(points: CGFloat) -> NSImage? {
        // Enough pixels for any attached display, so it stays crisp dragged between screens.
        let maxPixel = Int(points * 3)
        let key = "\(rawValue)@\(maxPixel)"
        if let hit = Self.thumbnailCache[key] { return hit }
        guard let url = Bundle.main.url(forResource: rawValue, withExtension: "png"),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixel,
              ] as CFDictionary) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: points, height: points))
        Self.thumbnailCache[key] = img
        return img
    }

    nonisolated(unsafe) private static var thumbnailCache: [String: NSImage] = [:]

    static let defaultsKey = "appIconTheme"

    static var current: AppIconTheme {
        get {
            AppIconTheme(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .white
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            newValue.apply()
        }
    }

    func apply() {
        guard let img = image else { return }
        NSApp.applicationIconImage = img
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            IconSettings().tabItem { Label("Icon", systemImage: "app.badge") }
            ModelSettings().tabItem { Label("Model", systemImage: "sparkles") }
            MCPSettings().tabItem { Label("Agents", systemImage: "terminal") }
        }
        .frame(width: 460, height: 400)
    }
}

/// Lets Claude Code and other MCP clients drive the open document.
struct MCPSettings: View {
    @AppStorage("mcp.enabled") private var enabled = true
    @State private var running = MCPServer.shared.running

    @State private var result: String?

    private var command: String {
        "claude mcp add --transport http --scope user skechworks \(MCPServer.shared.endpoint)"
    }

    var body: some View {
        Form {
            Toggle("Allow agents to edit the open document", isOn: $enabled)
                .onChange(of: enabled) { _, on in
                    on ? MCPServer.shared.start() : MCPServer.shared.stop()
                    running = MCPServer.shared.running
                }
            LabeledContent("Status") {
                VStack(alignment: .leading, spacing: 2) {
                    Label(running ? "Listening on \(MCPServer.shared.endpoint)" : "Off",
                          systemImage: running ? "circle.fill" : "circle")
                        .font(.caption)
                        .foregroundStyle(running ? .green : .secondary)
                    if let problem = MCPServer.shared.lastError {
                        Text(problem).font(.caption2).foregroundStyle(.orange)
                    }
                }
            }
            Section("Connect Claude Code") {
                HStack {
                    Button("Connect") { result = MCPServer.shared.connectClaudeCode() }
                        .disabled(!running)
                    Button("Copy command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        result = "Copied."
                    }
                }
                if let result {
                    Text(result).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text(command)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            Text("""
                Loopback only — nothing off this machine can reach it. Agents act on the \
                frontmost document and go through the same operations you do, so anything \
                they change is one undo away.
                """)
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding(4)
        .onAppear { running = MCPServer.shared.running }
    }
}

struct IconSettings: View {
    @AppStorage(AppIconTheme.defaultsKey) private var raw = AppIconTheme.white.rawValue

    private let columns = [GridItem(.adaptive(minimum: 64), spacing: 14)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("App Icon").font(.headline)
            Text("Applies immediately. Finder shows the built-in icon until the app has run once.")
                .font(.caption).foregroundStyle(.secondary)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(AppIconTheme.allCases) { theme in
                        Button {
                            raw = theme.rawValue
                            AppIconTheme.current = theme
                        } label: {
                            VStack(spacing: 5) {
                                if let img = theme.thumbnail(points: 60) {
                                    Image(nsImage: img)
                                        .resizable().interpolation(.high)
                                        .frame(width: 60, height: 60)
                                        .clipShape(RoundedRectangle(cornerRadius: 13))
                                } else {
                                    RoundedRectangle(cornerRadius: 13)
                                        .fill(.quaternary).frame(width: 60, height: 60)
                                }
                                Text(theme.title).font(.caption2)
                                    .foregroundStyle(raw == theme.rawValue ? .primary : .secondary)
                            }
                            .padding(4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(raw == theme.rawValue ? Color.accentColor : .clear, lineWidth: 2)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(20)
    }
}
