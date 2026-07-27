import AppKit
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

    static let defaultsKey = "appIconTheme"

    static var current: AppIconTheme {
        get {
            AppIconTheme(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .gradient
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
    @AppStorage(AppIconTheme.defaultsKey) private var raw = AppIconTheme.gradient.rawValue

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
                                if let img = theme.image {
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
        .frame(width: 420, height: 380)
    }
}
