import CryptoKit
import Foundation
import os
import Security

enum KeychainKeyStoreError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case invalidKeyData
}

/// Loads or provisions the symmetric key that `HistoryStore` uses to encrypt
/// clipboard history on disk. The key is a 256-bit key stored in the login
/// Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, so it never
/// leaves the device and can't be read while the Mac is locked.
protocol KeychainKeyStoring: Sendable {
    /// Returns the existing key, or `nil` if no key has been provisioned yet.
    func loadKey() throws -> SymmetricKey?
    /// Generates a new random 256-bit key, stores it in the Keychain, and returns it.
    func generateAndStoreKey() throws -> SymmetricKey
    /// Removes the stored key. Used by tests and by the "start fresh" recovery path.
    func deleteKey() throws
}

extension KeychainKeyStoring {
    /// Convenience: load the key if it exists, otherwise provision a new one.
    func loadOrCreateKey() throws -> SymmetricKey {
        if let key = try loadKey() {
            return key
        }
        return try generateAndStoreKey()
    }
}

struct KeychainKeyStore: KeychainKeyStoring {
    static let defaultService = "com.mcclowes.clipped.history"
    static let defaultAccount = "history-encryption-key-v1"

    private let service: String
    private let account: String

    init(service: String = KeychainKeyStore.defaultService, account: String = KeychainKeyStore.defaultAccount) {
        self.service = service
        self.account = account
    }

    func loadKey() throws -> SymmetricKey? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data, data.count == 32 else {
                throw KeychainKeyStoreError.invalidKeyData
            }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainKeyStoreError.unexpectedStatus(status)
        }
    }

    func generateAndStoreKey() throws -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }

        // Delete any stale item first so an `errSecDuplicateItem` can't sneak up on us.
        try deleteKey()

        var attributes = baseQuery()
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainKeyStoreError.unexpectedStatus(status)
        }
        return key
    }

    func deleteKey() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainKeyStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// In-memory store used by tests so they don't touch the real Keychain.
final class InMemoryKeyStore: KeychainKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var key: SymmetricKey?

    init(initialKey: SymmetricKey? = nil) {
        key = initialKey
    }

    func loadKey() throws -> SymmetricKey? {
        lock.lock()
        defer { lock.unlock() }
        return key
    }

    func generateAndStoreKey() throws -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }
        let newKey = SymmetricKey(size: .bits256)
        key = newKey
        return newKey
    }

    func deleteKey() throws {
        lock.lock()
        defer { lock.unlock() }
        key = nil
    }
}
