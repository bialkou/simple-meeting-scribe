import Foundation
import Security

/// Minimal generic-password Keychain wrapper. Same enum-with-statics shape as
/// the other stores, but backed by the Security framework instead of
/// UserDefaults — API keys don't belong in a plaintext plist.
enum KeychainHelper {
    static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String, service: String, account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        var attributes = query
        attributes[kSecValueData as String] = data
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            SecItemUpdate(query as CFDictionary,
                          [kSecValueData as String: data] as CFDictionary)
        }
    }

    static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// One API key kept as a generic password under the app's Keychain service.
private struct StoredAPIKey {
    private static let service = "com.czlonkowski.MeetX"
    let account: String

    /// Returns nil when no key is configured.
    func load() -> String? {
        guard let key = KeychainHelper.read(service: Self.service, account: account),
              !key.isEmpty else { return nil }
        return key
    }

    /// Empty (after trimming) removes the stored key.
    func save(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainHelper.delete(service: Self.service, account: account)
        } else {
            KeychainHelper.save(trimmed, service: Self.service, account: account)
        }
    }
}

/// Optional API key for a local OpenAI-compatible summarization server.
/// Most local servers leave this empty; it is kept in the Keychain when used.
enum LocalSummaryAPIKeyStore {
    private static let key = StoredAPIKey(account: "local-summary-api-key")

    static func loadAPIKey() -> String? { key.load() }
    static func saveAPIKey(_ value: String) { key.save(value) }
}
