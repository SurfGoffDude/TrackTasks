import Foundation
import Security

/// Generic passwords of the app. May show a system prompt and block: not for the main thread with rarely used secrets.
enum Keychain {
    static func get(service: String, account: String) -> String {
        var q = base(service, account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return "" }
        return String(decoding: d, as: UTF8.self)
    }

    /// Only the record, not its value: no access prompt.
    static func exists(service: String, account: String) -> Bool {
        SecItemCopyMatching(base(service, account) as CFDictionary, nil) == errSecSuccess
    }

    /// Пустое значение удаляет запись. Старое значение не стирается, пока новое не записано.
    static func set(service: String, account: String, _ value: String) -> Bool {
        let base = base(service, account)
        if value.isEmpty {
            let st = SecItemDelete(base as CFDictionary)
            return st == errSecSuccess || st == errSecItemNotFound
        }
        let data = [kSecValueData as String: Data(value.utf8)]
        let st = SecItemUpdate(base as CFDictionary, data as CFDictionary)
        guard st == errSecItemNotFound else { return st == errSecSuccess }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private static func base(_ service: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}
