import Foundation
import Security

public enum KeychainError: Error, Equatable {
    case notFound
    case status(Int32)
    public var message: String {
        switch self {
        case .notFound: return "No saved password was found in the Keychain (\(errSecItemNotFound))."
        case .status(let code):
            let text = SecCopyErrorMessageString(code, nil) as String? ?? "Keychain error"
            return "\(text) (\(code))"
        }
    }
}

/// Generic password in the user's default (legacy file-based) Keychain. Synchronous; call off the main queue,
/// because access can show a system prompt.
public struct KeychainPasswordStore {
    public let service: String
    public init(service: String = "org.ruuvimac.homeassistant") { self.service = service }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    public func read(account: String) throws -> String {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { throw KeychainError.notFound }
        guard status == errSecSuccess, let data = result as? Data, let text = String(data: data, encoding: .utf8) else {
            throw KeychainError.status(status == errSecSuccess ? errSecDecode : status)
        }
        return text
    }
    /// Updates in place, adding only if missing, so an existing password is never deleted before the new one is stored.
    public func save(_ password: String, account: String) throws {
        let data = Data(password.utf8)
        let update = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError.status(update) }
        var add = query(account)
        add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }
    public func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }
}
