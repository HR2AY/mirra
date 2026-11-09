import Foundation
import Security

enum TryOnLogin {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "local.tryon.upload.https.try-on.apps.viceme.ai",
        kSecAttrAccount as String: "HTTP Basic"
    ]

    private struct Login: Codable {
        let username: String
        let password: String
    }

    static func read() -> URLCredential? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let login = try? JSONDecoder().decode(Login.self, from: data) else { return nil }
        return URLCredential(user: login.username, password: login.password, persistence: .forSession)
    }

    @discardableResult
    static func save(_ credential: URLCredential) -> Bool {
        guard let username = credential.user, let password = credential.password,
              let data = try? JSONEncoder().encode(Login(username: username, password: password)) else { return false }
        let value = [kSecValueData as String: data]
        let result = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        if result == errSecItemNotFound {
            return SecItemAdd(query.merging(value) { _, new in new } as CFDictionary, nil) == errSecSuccess
        }
        return result == errSecSuccess
    }

    static func clear() {
        SecItemDelete(query as CFDictionary)
    }
}
