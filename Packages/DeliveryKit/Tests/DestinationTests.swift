import CaptureCore
import EndpointSecurity
import XCTest
@testable import DeliveryKit

final class DestinationTests: XCTestCase {
    func testLocalHTTPRequiresExplicitLocalPolicy() throws {
        let endpoint = Endpoint(scheme: "http", host: "192.168.1.20", port: 8080, path: "/capture")
        XCTAssertThrowsError(
            try endpoint.url(tlsRequirement: .requireHTTPS, networkPolicy: .localNetworkOnly)
        )

        let url = try endpoint.url(
            tlsRequirement: .allowHTTPForLocalHost,
            networkPolicy: .localNetworkOnly
        )
        XCTAssertEqual(url.absoluteString, "http://192.168.1.20:8080/capture")
    }

    func testRemotePlainHTTPIsRejected() {
        let endpoint = Endpoint(scheme: "http", host: "example.com", path: "/capture")
        XCTAssertThrowsError(
            try endpoint.url(
                tlsRequirement: .allowHTTPForLocalHost,
                networkPolicy: .anyNetwork
            )
        ) { error in
            XCTAssertEqual(error as? DestinationValidationError, .insecureRemoteEndpoint)
        }
    }

    func testHostnameBeginningWithIPv6PrefixIsNotTreatedAsLocal() {
        XCTAssertFalse(Endpoint.isLocalHost("fcevil.com"))
        XCTAssertTrue(Endpoint.isLocalHost("fd12:3456::1"))
        XCTAssertFalse(Endpoint.isLocalHost("010.0.0.1"))
    }

    func testReservedHeadersAreRejected() {
        let destination = Destination(
            name: "Home",
            endpoint: Endpoint(scheme: "https", host: "example.com"),
            headers: [HeaderTemplate(name: "Authorization", value: "secret")],
            networkPolicy: .anyNetwork
        )

        XCTAssertThrowsError(try destination.validate()) { error in
            XCTAssertEqual(error as? DestinationValidationError, .reservedHeader("Authorization"))
        }
    }

    func testRequestUsesKeychainReferenceAndStableIdempotencyKey() async throws {
        let credentials = InMemoryCredentialStore()
        let reference = CredentialReference()
        try await credentials.set("token-value", for: reference)
        let destination = Destination(
            name: "Receiver",
            endpoint: Endpoint(scheme: "https", host: "example.com"),
            headers: [HeaderTemplate(name: "X-Event", value: "{{event.type}}")],
            authentication: .bearer(token: reference),
            networkPolicy: .anyNetwork
        )
        let event = CaptureEvent.deliveryTest(
            destinationID: destination.id,
            source: EventSource(
                kind: .iPhone,
                installationID: UUID(),
                appVersion: "0.1.0",
                adapter: "iphone"
            )
        )

        let request = try await RequestFactory(credentialStore: credentials)
            .makeRequest(event: event, destination: destination)

        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-value")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), event.id.uuidString.lowercased())
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Event"), EventType.deliveryTest.rawValue)
        XCTAssertNotNil(request.httpBody)
    }

    func testAPIKeyValueComesFromCredentialStore() async throws {
        let credentials = InMemoryCredentialStore()
        let reference = CredentialReference()
        try await credentials.set("key-value", for: reference)
        let destination = Destination(
            name: "Receiver",
            endpoint: Endpoint(scheme: "https", host: "example.com"),
            authentication: .apiKey(header: "X-API-Key", value: reference),
            networkPolicy: .anyNetwork
        )
        let event = CaptureEvent.deliveryTest(
            destinationID: destination.id,
            source: EventSource(
                kind: .iPhone,
                installationID: UUID(),
                appVersion: "0.1.0",
                adapter: "iphone"
            )
        )

        let request = try await RequestFactory(credentialStore: credentials)
            .makeRequest(event: event, destination: destination)

        XCTAssertEqual(request.value(forHTTPHeaderField: "X-API-Key"), "key-value")
    }
}
