import Foundation

/// Carries an install from the app's earlier names across to Skechworks.
///
/// Each rename changed the bundle identifier, and with it where macOS keeps
/// the app's defaults, and the folder name under Application Support that
/// holds recovery snapshots and chat history. Without this a first launch
/// after updating would look like a fresh install: default icon, chat gone,
/// unsaved work not offered back. Runs once per old name, before anything
/// reads either.
enum LegacyMigration {

    /// Newest first. An install that skipped a name still finds its data.
    static let legacyNames: [(bundleID: String, folder: String, marker: String)] = [
        ("com.sketchyworks.Sketchyworks", "Sketchyworks", "migratedFromSketchyworks"),
        ("com.accomplice.Accomplice", "Accomplice", "migratedFromAccomplice"),
    ]
    static let folder = "Skechworks"

    static func run() {
        for legacy in legacyNames {
            migrateDefaults(from: legacy.bundleID, marker: legacy.marker)
            migrateApplicationSupport(from: legacy.folder)
        }
    }

    private static func migrateDefaults(from legacyBundleID: String, marker: String) {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: marker) == nil else { return }
        defaults.set(true, forKey: marker)
        guard let old = defaults.persistentDomain(forName: legacyBundleID) else { return }
        for (key, value) in old where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }

    private static func migrateApplicationSupport(from legacyFolder: String) {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let old = support.appendingPathComponent(legacyFolder, isDirectory: true)
        let new = support.appendingPathComponent(folder, isDirectory: true)
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        try? fm.moveItem(at: old, to: new)
    }
}
