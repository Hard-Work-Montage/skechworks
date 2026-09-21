import Foundation
import os
import Security

/// Where API keys and access tokens live.
///
/// The Keychain rather than UserDefaults, which is where the OpenRouter key used to
/// sit: a plist in the user's Library, readable by anything running as them, backed
/// up and synced in the clear. A key that can spend money doesn't belong there.
///
/// Reads are not cached. A key is fetched per request, which costs microseconds and
/// means "Disconnect" takes effect immediately rather than at the next launch.
enum Credentials {

    enum Slot: String {
        case openRouterKey = "openrouter.key"
        case skechworksToken = "skechworks.token"
    }

    private static let service = "com.skechworks.Skechworks"

    /// Where the same items lived under the app's earlier names, newest first.
    /// A rename must not sign anyone out, so a miss under the current name
    /// reads the old ones and carries the first hit across.
    private static let legacyServices: [(service: String, token: String)] = [
        ("com.sketchyworks.Sketchyworks", "sketchyworks.token"),
        ("com.accomplice.Accomplice", "accomplice.token"),
    ]

    /// Old-name items get looked at ONCE per launch. Their permission lists
    /// name the old apps, so every read of one makes macOS ask for the login
    /// keychain password — and probing them on every lookup asked over and
    /// over while you worked. A value found there is copied forward and the
    /// old items deleted, so the question can never come back.
    // Only ever touched from the main thread — every caller is UI or a
    // MainActor task — but the compiler can't see that from here.
    nonisolated(unsafe) private static var probedLegacy: Set<String> = []

    /// Values the keychain refused, kept for this launch only. The keychain
    /// checks a caller against the app file on disk, so an app that was updated
    /// while it was open is turned away until it is reopened. Holding the token
    /// in memory lets that session sign in and work; the next launch has a
    /// keychain again and asks once more.
    nonisolated(unsafe) private static var sessionOnly: [String: String] = [:]

    static func get(_ slot: Slot) -> String? {
        if let s = sessionOnly[slot.rawValue] { return s }
        if let s = read(service: service, account: slot.rawValue) { return s }
        guard !probedLegacy.contains(slot.rawValue) else { return nil }
        probedLegacy.insert(slot.rawValue)
        for legacy in legacyServices {
            let account = slot == .skechworksToken ? legacy.token : slot.rawValue
            if let old = read(service: legacy.service, account: account) {
                if set(slot, old) {
                    for l in legacyServices {
                        let a = slot == .skechworksToken ? l.token : slot.rawValue
                        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                                       kSecAttrService as String: l.service,
                                       kSecAttrAccount as String: a] as CFDictionary)
                    }
                }
                return old
            }
        }
        return nil
    }

    private static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let s = String(data: data, encoding: .utf8),
              !s.isEmpty else { return nil }
        return s
    }

    private static let log = Logger(subsystem: "com.skechworks.Skechworks", category: "credentials")

    /// True when the value is in the keychain. False means the keychain refused
    /// and the value lives in this launch's memory instead, so `get` still
    /// returns it and the caller is signed in either way. Ignoring SecItemAdd's
    /// status turned a failed store into a sign-in that silently bounced back to
    /// the sign-in button — the server said 200, the app forgot the token.
    @discardableResult
    static func set(_ slot: Slot, _ value: String?) -> Bool {
        sessionOnly[slot.rawValue] = nil
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: slot.rawValue,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        // Available without the machine being unlocked by anyone else, and never
        // synced to another device — a key pulled here belongs to this install.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        var status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            // The accessibility attribute belongs to the data-protection keychain,
            // and whether a given signing context may use that varies. A plain
            // login-keychain item beats losing the sign-in.
            add.removeValue(forKey: kSecAttrAccessible as String)
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess {
            log.error("keychain add for \(slot.rawValue, privacy: .public) failed: \(status); keeping it for this launch only")
            sessionOnly[slot.rawValue] = value
            return false
        }
        if read(service: service, account: slot.rawValue) == nil {
            log.error("keychain read-back for \(slot.rawValue, privacy: .public) failed; keeping it for this launch only")
            sessionOnly[slot.rawValue] = value
            return false
        }
        return true
    }

    static func has(_ slot: Slot) -> Bool { get(slot) != nil }

    /// Moves the key that used to live in UserDefaults into the Keychain, and removes
    /// the plaintext copy. Anyone who typed a key into an older build had it sitting
    /// readable on disk; leaving it there while quietly reading from the Keychain
    /// would be the worst of both.
    static func migrateLegacyDefaults() {
        let key = "ai.openRouterKey"
        guard let old = UserDefaults.standard.string(forKey: key), !old.isEmpty else { return }
        if get(.openRouterKey) == nil { set(.openRouterKey, old) }
        UserDefaults.standard.removeObject(forKey: key)
    }
}
