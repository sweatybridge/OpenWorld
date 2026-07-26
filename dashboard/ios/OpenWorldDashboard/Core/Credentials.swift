import Foundation
import Security

/// Credential persistence. Base URL in UserDefaults (not secret); bearer token
/// in the Keychain as a generic password. Both are mirrored into static vars
/// on load so the synchronous APIClient can read them without awaiting.
enum Credentials {
    private static let baseURLKey = "OpenWorld_dashboard_base_url"
    private static let service = "OpenWorld-dashboard"
    private static let account = "token"

    // Mirrored in-memory state (loaded once at launch).
    static private(set) var baseURL: String = ""
    static private(set) var token: String = ""

    static var hasBaseURL: Bool { !baseURL.isEmpty }

    // MARK: - Load

    /// Load both creds from their backing stores. Safe to call repeatedly; the
    /// first call happens at launch before the auth gate probes.
    static func load() {
        baseURL = normalizeBase(UserDefaults.standard.string(forKey: baseURLKey) ?? "")
        token = readToken() ?? ""
    }

    // MARK: - Save / clear

    static func save(baseURL rawBase: String, token tok: String) {
        let base = normalizeBase(rawBase)
        baseURL = base
        token = tok
        UserDefaults.standard.set(base, forKey: baseURLKey)
        if tok.isEmpty {
            deleteToken()
        } else {
            writeToken(tok)
        }
    }

    @discardableResult
    static func clearToken() -> Bool {
        token = ""
        return deleteToken()
    }

    // MARK: - Normalize

    /// Trim trailing slashes so `base + "/api/..."` never doubles up.
    static func normalizeBase(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    // MARK: - Keychain

    @discardableResult
    private static func writeToken(_ value: String) -> Bool {
        deleteToken()
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    private static func readToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    private static func deleteToken() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
