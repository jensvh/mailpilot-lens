import Foundation
import Security

/// What pairing gave this phone (its id, its key, where to connect, the speech
/// server's key) lives in the Keychain, on this device only.
enum Keychain {
    private static func query(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "io.github.jensvh.mailpilot.lens",
         kSecAttrAccount as String: name]
    }

    static func read(_ name: String) -> String? {
        var q = query(name)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ name: String, _ value: String) {
        delete(name)
        var q = query(name)
        q[kSecValueData as String] = Data(value.utf8)
        // Readable while the phone is locked (after its first unlock): a walk
        // happens with the phone in a pocket.
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete(_ name: String) {
        SecItemDelete(query(name) as CFDictionary)
    }
}
