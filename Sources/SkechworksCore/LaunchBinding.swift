import Darwin
import Foundation

// Makes a .sw.png open in Skechworks on double-click without stealing every PNG
// on the machine.
//
// LaunchServices resolves a file's type from the LAST extension component only. Our
// UTI declares the compound tag `.sw.png` and LaunchServices does record it —
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
//
// The one way it bites: a bound file that ALSO carries com.apple.quarantine.
// Gatekeeper treats "quarantined document with a per-file handler" as something to
// assess, tries to verify the PNG as if it were code, and shows "Apple could not
// verify ... is free of malware" naming the document — with a Move to Trash button.
// A notarized, stapled app in /Applications does not prevent this (seen 2026-09-05
// on macOS 26 with 0.1.59): syspolicyd only ever looks at the document. Preview
// stamps quarantine on any file it touches, so a .sw.png someone glanced at in
// Preview is challenged on its next double-click. Hence `releaseQuarantine`: a
// file we bind, or successfully open as our own format, gets the flag taken off.

public enum LaunchBinding {

    public static let defaultBundleID = "com.skechworks.Skechworks"
    static let attribute = "com.apple.LaunchServices.OpenWith"

    /// Binds this one file to Skechworks. Naming only the bundle identifier — not a
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
            } && releaseQuarantine(url)
        }
    }

    /// Takes com.apple.quarantine off a file. Only meaningful for a bound file —
    /// an unbound PNG is never challenged — so this is a no-op for anything else.
    /// Returns true when the file ends up unflagged, whether or not it was flagged.
    @discardableResult
    public static func releaseQuarantine(_ url: URL) -> Bool {
        guard isClaimed(url) else { return true }
        return url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return removexattr(path, "com.apple.quarantine", 0) == 0 || errno == ENOATTR
        }
    }

    /// Removes the binding, restoring the system default (Preview for a .sw.png).
    /// Worth having: if the app is ever signed ad-hoc or otherwise can't be verified,
    /// Gatekeeper challenges documents bound to it and names the *document* in the
    /// warning. Being able to undo this in one command matters.
    @discardableResult
    public static func unclaim(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return removexattr(path, attribute, 0) == 0 || errno == ENOATTR
        }
    }

    public static func isClaimed(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return getxattr(path, attribute, nil, 0, 0, 0) > 0
        }
    }
}
