import Foundation

public actor InMemoryCredentialStore: CredentialStore {
    private var values: [CredentialReference: Data] = [:]

    public init() {}

    public func set(_ value: Data, for reference: CredentialReference) {
        values[reference] = value
    }

    public func value(for reference: CredentialReference) -> Data? {
        values[reference]
    }

    public func delete(_ reference: CredentialReference) {
        values.removeValue(forKey: reference)
    }
}
