import Foundation
import Security

protocol KeychainStoring: Sendable {
    func set(_ secret: String, account: String) throws
    func get(account: String) throws -> String?
    func delete(account: String) throws
}

enum KeychainError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case malformedData
}

struct SystemKeychainStore: KeychainStoring {
    let service: String

    init(service: String = "com.dzamataev.macomprendo") { self.service = service }

    func set(_ secret: String, account: String) throws {
        guard let data = secret.data(using: .utf8) else { throw KeychainError.malformedData }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func get(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = item as? Data, let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.malformedData
        }
        return string
    }

    func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

final class InMemoryKeychainStore: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    init() {}

    func set(_ secret: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[account] = secret
    }

    func get(account: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[account]
    }

    func delete(account: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[account] = nil
    }
}
