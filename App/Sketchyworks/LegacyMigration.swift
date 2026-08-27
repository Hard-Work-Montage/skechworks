import Foundation

/// Carries an Accomplice install across to Sketchyworks.
///
/// The rename changed the bundle identifier, and with it where macOS keeps
/// the app's defaults, and the folder name under Application Support that
/// holds recovery snapshots and chat history. Without this a first launch
/// after updating would look like a fresh install: default icon, chat gone,
/// unsaved work not offered back. Runs once, before anything reads either.
enum LegacyMigration {

    static let legacyBundleID = "com.accomplice.Accomplice"
    static let marker = "migratedFromAccomplice"

    static func run() {
        migrateDefaults()
        migrateApplicationSupport()
    }

    private static func migrateDefaults() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: marker) == nil else { return }
        defaults.set(true, forKey: marker)
        guard let old = defaults.persistentDomain(forName: legacyBundleID) else { return }
        for (key, value) in old where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }

    private static func migrateApplicationSupport() {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let old = support.appendingPathComponent("Accomplice", isDirectory: true)
        let new = support.appendingPathComponent("Sketchyworks", isDirectory: true)
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        try? fm.moveItem(at: old, to: new)
    }
}
