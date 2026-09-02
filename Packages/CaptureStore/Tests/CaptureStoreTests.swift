import CaptureCore
import DeliveryKit
import XCTest
@testable import CaptureStore

final class CaptureStoreTests: XCTestCase {
    func testEventIsPersistedBeforeDeliveryAndDeduplicated() async throws {
        let fixture = try makeFixture()
        let store = try CaptureStore(databaseURL: fixture.databaseURL)
        let destination = try await store.saveDestination(fixture.destination)

        let firstJobs = try await store.enqueue(fixture.event, destinationIDs: [destination.id])
        let secondJobs = try await store.enqueue(fixture.event, destinationIDs: [destination.id])
        let items = try await store.queueItems()

        XCTAssertEqual(firstJobs.map(\.id), secondJobs.map(\.id))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.event, fixture.event)
        XCTAssertEqual(items.first?.deliveries.count, 1)
    }

    func testDeliveryStateSurvivesStoreReopen() async throws {
        let fixture = try makeFixture()
        var store: CaptureStore? = try CaptureStore(databaseURL: fixture.databaseURL)
        try await store?.saveDestination(fixture.destination)
        let job = try await store?.enqueue(fixture.event, destinationIDs: [fixture.destination.id]).first
        let workerID = UUID()
        let envelope = try await store?.lease(jobID: job!.id, owner: workerID)
        XCTAssertEqual(envelope?.job.attemptCount, 1)
        try await store?.record(.delivered(statusCode: 202), for: job!.id)

        store = nil
        let reopened = try CaptureStore(databaseURL: fixture.databaseURL)
        let item = try await reopened.queueItems().first

        XCTAssertEqual(item?.deliveries.first?.state, .delivered)
        XCTAssertEqual(item?.deliveries.first?.lastHTTPStatus, 202)
    }

    func testDeleteEventCascadesDeliveryJobs() async throws {
        let fixture = try makeFixture()
        let store = try CaptureStore(databaseURL: fixture.databaseURL)
        try await store.saveDestination(fixture.destination)
        try await store.enqueue(fixture.event, destinationIDs: [fixture.destination.id])

        try await store.deleteEvent(id: fixture.event.id)

        let items = try await store.queueItems()
        let readyJobs = try await store.readyJobIDs()
        XCTAssertTrue(items.isEmpty)
        XCTAssertTrue(readyJobs.isEmpty)
    }

    func testExportDoesNotContainCredentialValues() async throws {
        let fixture = try makeFixture()
        let store = try CaptureStore(databaseURL: fixture.databaseURL)
        try await store.saveDestination(fixture.destination)
        try await store.enqueue(fixture.event, destinationIDs: [fixture.destination.id])

        let snapshot = try await store.exportSnapshot()
        let data = try JSONEncoder().encode(snapshot)
        let text = String(decoding: data, as: UTF8.self)

        XCTAssertFalse(text.contains("private-token"))
        XCTAssertEqual(snapshot.events.count, 1)
    }

    private func makeFixture() throws -> StoreFixture {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "tapline-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }

        let destination = Destination(
            name: "Local receiver",
            endpoint: Endpoint(scheme: "http", host: "127.0.0.1", port: 8080),
            tlsRequirement: .allowHTTPForLocalHost,
            networkPolicy: .localNetworkOnly
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
        return StoreFixture(
            databaseURL: directory.appending(path: "tapline.sqlite"),
            destination: destination,
            event: event
        )
    }
}

private struct StoreFixture {
    let databaseURL: URL
    let destination: Destination
    let event: CaptureEvent
}
