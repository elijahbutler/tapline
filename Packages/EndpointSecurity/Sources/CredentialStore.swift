import Foundation

public struct CredentialReference: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID

    public init(id: UUID = UUID()) {
        self.id = id
    }
}

public protocol CredentialStore: Sendable {
    func set(_ value: Data, for reference: CredentialReference) async throws
    func value(for reference: CredentialReference) async throws -> Data?
    func delete(_ reference: CredentialReference) async throws
}

public extension CredentialStore {
    func set(_ value: String, for reference: CredentialReference) async throws {
        guard let data = value.data(using: .utf8) else {
            throw CredentialStoreError.invalidUTF8
        }
        try await set(data, for: reference)
    }

    func string(for reference: CredentialReference) async throws -> String? {
        guard let data = try await value(for: reference) else { return nil }
        guard let value = String(data: data, encoding: .utf8) else {
            throw CredentialStoreError.invalidUTF8
        }
        return value
    }
}

public enum CredentialStoreError: Error, Equatable, Sendable {
    case invalidUTF8
    case unexpectedStatus(Int32)
}

