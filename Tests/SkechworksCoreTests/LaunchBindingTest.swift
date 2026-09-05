import Darwin
import Foundation
import Testing
@testable import SkechworksCore

// A bound file with com.apple.quarantine on it is challenged by Gatekeeper on
// double-click ("could not verify ... free of malware"). Binding, or reopening,
// takes the flag off; an unbound file is left alone.
@Suite struct LaunchBindingTest {

    private func scratch() -> URL {
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent("lb-\(UUID().uuidString).sw.png")
        try! Data([0x89, 0x50, 0x4E, 0x47]).write(to: u)
        return u
    }

    private func quarantine(_ u: URL) {
        let v = "0082;00000000;Preview;"
        _ = u.withUnsafeFileSystemRepresentation { p in
            setxattr(p, "com.apple.quarantine", v, v.utf8.count, 0, 0)
        }
    }

    private func isQuarantined(_ u: URL) -> Bool {
        u.withUnsafeFileSystemRepresentation { p in
            getxattr(p, "com.apple.quarantine", nil, 0, 0, 0) >= 0
        }
    }

    @Test func claimingStripsQuarantine() throws {
        let u = scratch()
        defer { try? FileManager.default.removeItem(at: u) }
        quarantine(u)
        #expect(isQuarantined(u))
        #expect(LaunchBinding.claim(u))
        #expect(LaunchBinding.isClaimed(u))
        #expect(!isQuarantined(u))
    }

    @Test func releaseOnlyTouchesBoundFiles() throws {
        let u = scratch()
        defer { try? FileManager.default.removeItem(at: u) }
        quarantine(u)
        #expect(LaunchBinding.releaseQuarantine(u))
        #expect(isQuarantined(u), "an unbound PNG is never challenged, so its flag is not ours to remove")
        LaunchBinding.claim(u)
        quarantine(u)
        #expect(LaunchBinding.releaseQuarantine(u))
        #expect(!isQuarantined(u))
        #expect(LaunchBinding.releaseQuarantine(u), "already clean is fine")
    }
}
