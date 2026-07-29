import Foundation
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
        case accompliceToken = "accomplice.token"
    }

    private static let service = "com.accomplice.Accomplice"

    static func get(_ slot: Slot) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: slot.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let s = String(data: data, encoding: .utf8),
              !s.isEmpty else { return nil }
        return s
    }

    static func set(_ slot: Slot, _ value: String?) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: slot.rawValue,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        // Available without the machine being unlocked by anyone else, and never
        // synced to another device — a key pulled here belongs to this install.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
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
