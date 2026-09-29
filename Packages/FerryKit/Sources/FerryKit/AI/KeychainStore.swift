import Foundation
import Security

/// A failed Keychain call. Carries only the status — never the secret.
public struct KeychainError: Error, Sendable, Equatable {
    public var status: OSStatus

    public var message: String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)."
    }
}

/// One secret in the macOS Keychain as a generic-password item, readable only while the
/// Mac is unlocked and never synced to other devices. The only place Ferry
/// keeps API keys — never UserDefaults, files or logs.
///
/// Prefers the data-protection keychain, which honours the accessibility class and
/// never shows access prompts. That keychain needs a team-signed binary; ad-hoc builds
/// (and `swift test`) get `errSecMissingEntitlement`, so those fall back to the login
/// keychain.
public struct KeychainStore: Sendable {
    public static let openAIService = "io.github.fynnius.Ferry.openai"

    public let service: String
    public let account: String

    /// - Parameter service: injectable so tests use a throwaway item.
    public init(service: String = KeychainStore.openAIService, account: String = "api-key") {
        self.service = service
        self.account = account
    }

    /// Saves or replaces the secret. Surrounding whitespace (a pasted newline) is dropped.
    public func save(_ secret: String) throws {
        let value = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw KeychainError(status: errSecParam) }
        let data = Data(value.utf8)

        switch upsert(data, dataProtection: true) {
        case errSecSuccess:
            // Drop a copy an earlier ad-hoc build left in the login keychain.
            _ = SecItemDelete(query(dataProtection: false) as CFDictionary)
        case errSecMissingEntitlement:
            let status = upsert(data, dataProtection: false)
            guard status == errSecSuccess else { throw KeychainError(status: status) }
        case let status:
            throw KeychainError(status: status)
        }
    }

    /// The secret, or nil when none is saved.
    public func read() throws -> String? {
        for dataProtection in [true, false] {
            var query = query(dataProtection: dataProtection)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            switch status {
            case errSecSuccess:
                guard let data = result as? Data else { return nil }
                return String(decoding: data, as: UTF8.self)
            case errSecItemNotFound, errSecMissingEntitlement:
                continue
            default:
                throw KeychainError(status: status)
            }
        }
        return nil
    }

    /// Removes the secret from both keychains. Deleting a missing item is not an error.
    public func delete() throws {
        for dataProtection in [true, false] {
            let status = SecItemDelete(query(dataProtection: dataProtection) as CFDictionary)
            guard [errSecSuccess, errSecItemNotFound, errSecMissingEntitlement].contains(status) else {
                throw KeychainError(status: status)
            }
        }
    }

    /// Whether a secret is saved, without reading it (so no access prompt can appear).
    public var hasKey: Bool {
        [true, false].contains { dataProtection in
            SecItemCopyMatching(query(dataProtection: dataProtection) as CFDictionary, nil) == errSecSuccess
        }
    }

    private func query(dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }

    private func upsert(_ data: Data, dataProtection: Bool) -> OSStatus {
        let query = query(dataProtection: dataProtection)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        var item = query
        item.merge(attributes) { _, new in new }
        return SecItemAdd(item as CFDictionary, nil)
    }
}
