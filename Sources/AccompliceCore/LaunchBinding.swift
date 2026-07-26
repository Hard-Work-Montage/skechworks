import Darwin
import Foundation

// Makes a .acmplc.png open in Accomplice on double-click without stealing every PNG
// on the machine.
//
// LaunchServices resolves a file's type from the LAST extension component only. Our
// UTI declares the compound tag `.acmplc.png` and LaunchServices does record it —
// but `public.png` is an Apple system type claiming "png", and a third-party type
// can't outrank it. Verified by reading `lsregister -dump`, not by guessing.
//
// The lever that does work is the per-file binding Finder writes when you use
// Get Info > Open With on a single file: an extended attribute naming the handler.
// Stamping it ourselves at write time gets the same result for every document we
// create, while every other PNG on the system still belongs to Preview.
//
// This is a pure enhancement. Extended attributes don't survive every transfer —
// zip, email, and most upload/download round trips drop them. When that happens the
// file simply opens in Preview again, which is exactly what it did before. Nothing
// breaks, and the artwork is still there either way.

public enum LaunchBinding {

    public static let defaultBundleID = "com.accomplice.Accomplice"
    static let attribute = "com.apple.LaunchServices.OpenWith"

    /// Binds this one file to Accomplice. Naming only the bundle identifier — not a
    /// path — keeps documents portable when the app moves or is installed elsewhere.
    @discardableResult
    public static func claim(_ url: URL, bundleID: String = defaultBundleID) -> Bool {
        let plist: [String: Any] = ["version": 0, "bundleidentifier": bundleID]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist,
                                                             format: .binary, options: 0) else { return false }
        return url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return data.withUnsafeBytes { buf -> Bool in
                setxattr(path, attribute, buf.baseAddress, data.count, 0, 0) == 0
            }
        }
    }

    public static func isClaimed(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return getxattr(path, attribute, nil, 0, 0, 0) > 0
        }
    }
}
