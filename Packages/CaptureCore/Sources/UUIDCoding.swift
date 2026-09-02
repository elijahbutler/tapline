import Foundation

enum UUIDCodingError: Error {
    case invalidUUID(String)
}

extension KeyedEncodingContainer {
    mutating func encode(_ value: UUID, forKey key: Key) throws {
        try encode(value.uuidString.lowercased(), forKey: key)
    }

    mutating func encodeIfPresent(_ value: UUID?, forKey key: Key) throws {
        guard let value else { return }
        try encode(value, forKey: key)
    }
}

extension KeyedDecodingContainer {
    func decodeUUID(forKey key: Key) throws -> UUID {
        let value = try decode(String.self, forKey: key)
        guard let id = UUID(uuidString: value) else {
            throw UUIDCodingError.invalidUUID(value)
        }
        return id
    }

    func decodeUUIDIfPresent(forKey key: Key) throws -> UUID? {
        guard let value = try decodeIfPresent(String.self, forKey: key) else { return nil }
        guard let id = UUID(uuidString: value) else {
            throw UUIDCodingError.invalidUUID(value)
        }
        return id
    }
}

