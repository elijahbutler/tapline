import XCTest
@testable import EndpointSecurity

final class CredentialStoreTests: XCTestCase {
    func testInMemoryStoreSetsReadsAndDeletesCredentials() async throws {
        let store = InMemoryCredentialStore()
        let reference = CredentialReference()

        try await store.set("private-value", for: reference)
        let stored = try await store.string(for: reference)
        XCTAssertEqual(stored, "private-value")

        await store.delete(reference)
        let deleted = try await store.string(for: reference)
        XCTAssertNil(deleted)
    }
}
