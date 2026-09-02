import XCTest
@testable import CaptureCore

final class CaptureEventTests: XCTestCase {
    func testEventRoundTripsThroughPublicCodec() throws {
        let event = CaptureEvent(
            id: UUID(uuidString: "54166df2-a5c9-4a52-87ab-a15d72f4e907")!,
            type: .buttonPressed,
            occurredAt: Date(timeIntervalSince1970: 1_725_302_483.194),
            capturedAt: Date(timeIntervalSince1970: 1_725_302_483.211),
            source: EventSource(
                kind: .appleWatch,
                installationID: UUID(uuidString: "282c937e-9bbc-49d0-9a96-adb95be343e4")!,
                model: "Apple Watch",
                osVersion: "11.0",
                appVersion: "0.1.0",
                adapter: "watchconnectivity"
            ),
            payload: ["button": .string("primary"), "gesture": .string("press")]
        )

        let data = try EventCodec.encode(event)
        let decoded = try EventCodec.decode(data)

        XCTAssertEqual(decoded, event)
        let encoded = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(encoded.contains("\"schemaVersion\":1"))
        XCTAssertTrue(encoded.contains("\"id\":\"54166df2-a5c9-4a52-87ab-a15d72f4e907\""))
        XCTAssertTrue(encoded.contains("\"installationID\":\"282c937e-9bbc-49d0-9a96-adb95be343e4\""))
    }

    func testDecoderRejectsUnknownSchemaVersion() throws {
        let event = CaptureEvent(
            schemaVersion: 2,
            type: .deliveryTest,
            occurredAt: .now,
            capturedAt: .now,
            source: EventSource(
                kind: .iPhone,
                installationID: UUID(),
                appVersion: "0.1.0",
                adapter: "iphone"
            )
        )

        let data = try EventCodec.encode(event)
        XCTAssertThrowsError(try EventCodec.decode(data)) { error in
            XCTAssertEqual(error as? EventCodecError, .unsupportedSchemaVersion(2))
        }
    }

    func testDeliveryTestUsesStableDestinationID() {
        let destinationID = UUID(uuidString: "e2e91bf4-2650-4051-8d9c-b158971386f7")!
        let event = CaptureEvent.deliveryTest(
            destinationID: destinationID,
            source: EventSource(
                kind: .iPhone,
                installationID: UUID(),
                appVersion: "0.1.0",
                adapter: "iphone"
            )
        )

        XCTAssertEqual(event.type, .deliveryTest)
        XCTAssertEqual(event.payload["destinationID"], .string(destinationID.uuidString.lowercased()))
        XCTAssertTrue(event.media.isEmpty)
    }
}
