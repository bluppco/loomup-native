import Foundation
import Loomup
import Security

public enum KeychainStoreError: Error, Sendable {
    case unexpectedStatus(OSStatus)
}

/// Keychain-backed refresh-token persistence. Access tokens are intentionally
/// never written here and remain in `LoomupClient` process memory.
public struct KeychainRefreshTokenStore: RefreshTokenStore, Sendable {
    public let service: String
    public let account: String

    public init(
        service: String = "com.loomup.sdk.refresh-token",
        account: String = "default"
    ) {
        self.service = service
        self.account = account
    }

    public func loadRefreshToken() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainStoreError.unexpectedStatus(status) }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func saveRefreshToken(_ token: String?) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let token {
            let attributes: [String: Any] = [
                kSecValueData as String: Data(token.utf8),
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                var insert = query
                attributes.forEach { insert[$0.key] = $0.value }
                let insertStatus = SecItemAdd(insert as CFDictionary, nil)
                guard insertStatus == errSecSuccess else {
                    throw KeychainStoreError.unexpectedStatus(insertStatus)
                }
            } else if status != errSecSuccess {
                throw KeychainStoreError.unexpectedStatus(status)
            }
        } else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainStoreError.unexpectedStatus(status)
            }
        }
    }
}
