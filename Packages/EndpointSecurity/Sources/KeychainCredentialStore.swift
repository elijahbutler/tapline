import Foundation
import Security

public final class KeychainCredentialStore: CredentialStore, @unchecked Sendable {
    private let service: String

    public init(service: String = "app.tapline.credentials") {
        self.service = service
    }

    public func set(_ value: Data, for reference: CredentialReference) async throws {
        let query = baseQuery(for: reference)
        let attributes: [CFString: Any] = [
            kSecValueData: value,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        guard updateStatus == errSecItemNotFound else {
            throw CredentialStoreError.unexpectedStatus(updateStatus)
        }

        var insertion = query
        attributes.forEach { insertion[$0] = $1 }
        let addStatus = SecItemAdd(insertion as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CredentialStoreError.unexpectedStatus(addStatus)
        }
    }

    public func value(for reference: CredentialReference) async throws -> Data? {
        var query = baseQuery(for: reference)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess, let data = result as? Data else {
            throw CredentialStoreError.unexpectedStatus(status)
        }

        return data
    }

    public func delete(_ reference: CredentialReference) async throws {
        let status = SecItemDelete(baseQuery(for: reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery(for reference: CredentialReference) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: reference.id.uuidString.lowercased(),
            kSecAttrSynchronizable: false,
        ]
    }
}

