import Foundation
import Security

/// Minimal Keychain wrapper (plan §5.1). Tokens stored
/// kSecAttrAccessibleWhenUnlockedThisDeviceOnly per plan feature #39.
public enum Keychain {
    public enum KeychainError: Error, Equatable, Sendable {
        case unhandled(OSStatus)
    }

    public static func set(_ data: String, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: Data(data.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            attrs.forEach { add[$0.key] = $0.value }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unhandled(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.unhandled(status)
        }
    }

    public static func get(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// In-memory fallback store with the same shape, used by unit tests on
/// platforms/contexts without a keychain (Linux `swift test`).
public struct InMemoryTokenStore: Sendable {
    private var tokens: [String: String] = [:]

    public init() {}

    public mutating func set(_ token: String, forKey key: String) { tokens[key] = token }
    public func get(_ key: String) -> String? { tokens[key] }
    public mutating func remove(_ key: String) { tokens.removeValue(forKey: key) }
}
