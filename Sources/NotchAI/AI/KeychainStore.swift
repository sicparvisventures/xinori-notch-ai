import Foundation
import Security

/// API keys live in the Keychain, never in UserDefaults or on disk in plain text.
enum KeychainStore {
    private static let service = "com.xinori.notchai"

    static func apiKey(for provider: ProviderID) -> String? {
        var query = baseQuery(for: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        return key
    }

    @discardableResult
    static func setAPIKey(_ key: String, for provider: ProviderID) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return removeAPIKey(for: provider) }

        let query = baseQuery(for: provider)
        let attributes = [kSecValueData as String: Data(trimmed.utf8)]

        // Update in place if it already exists; SecItemAdd would fail with
        // errSecDuplicateItem.
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }

        var insert = query
        insert[kSecValueData as String] = Data(trimmed.utf8)
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func removeAPIKey(for provider: ProviderID) -> Bool {
        SecItemDelete(baseQuery(for: provider) as CFDictionary) == errSecSuccess
    }

    static func hasAPIKey(for provider: ProviderID) -> Bool {
        apiKey(for: provider) != nil
    }

    private static func baseQuery(for provider: ProviderID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]
    }
}
