import CaptureCore
import Foundation
import XCTest
@testable import WatchCapture

final class WatchCaptureOutboxTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: "WatchCaptureTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testButtonEventIsDurableAcrossOutboxInstances() async throws {
        let eventID = UUID(uuidString: "54166df2-a5c9-4a52-87ab-a15d72f4e907")!
        let first = WatchCaptureOutbox(rootDirectory: temporaryDirectory)
        let event = try await first.commitButtonEvent(
            id: eventID,
            occurredAt: Date(timeIntervalSince1970: 100),
            source: source,
            capturedAt: Date(timeIntervalSince1970: 101)
        )

        let relaunched = WatchCaptureOutbox(rootDirectory: temporaryDirectory)
        let snapshot = try await relaunched.snapshot()

        XCTAssertEqual(snapshot.items.map(\.event), [event])
        XCTAssertTrue(snapshot.items[0].event.media.isEmpty)
        XCTAssertTrue(snapshot.failures.isEmpty)
    }

    func testAudioMetadataAndFileCommitAsOnePendingItem() async throws {
        let eventID = UUID(uuidString: "02b53d12-3d99-4f8e-9ba3-b4946ade64a8")!
        let mediaID = UUID(uuidString: "d83a9bd0-8eba-4496-bfd1-bef314dbf017")!
        let outbox = WatchCaptureOutbox(rootDirectory: temporaryDirectory)
        let capture = try await outbox.beginAudioCapture(
            id: eventID,
            mediaID: mediaID,
            occurredAt: Date(timeIntervalSince1970: 200)
        )
        try Data("playable-audio-placeholder".utf8).write(to: capture.fileURL)

        let event = try await outbox.commitAudioCapture(
            capture,
            source: source,
            durationMilliseconds: 1_250,
            sampleRateHertz: 16_000,
            channelCount: 1,
            interrupted: true,
            interruptionReason: "audio_session_interruption",
            capturedAt: Date(timeIntervalSince1970: 202)
        )

        let snapshot = try await outbox.snapshot()
        XCTAssertEqual(snapshot.items.count, 1)
        XCTAssertEqual(snapshot.items[0].event, event)
        XCTAssertEqual(snapshot.items[0].mediaFileURL?.lastPathComponent, "audio.m4a")
        XCTAssertEqual(event.id, eventID)
        XCTAssertEqual(event.media.first?.id, mediaID)
        XCTAssertEqual(event.media.first?.byteCount, 26)
        XCTAssertEqual(event.media.first?.sampleRateHertz, 16_000)
        XCTAssertEqual(event.payload["interrupted"], .bool(true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: capture.fileURL.path))
    }

    func testDeniedPermissionPersistsFailureWithoutAudioFile() async throws {
        let eventID = UUID()
        let outbox = WatchCaptureOutbox(rootDirectory: temporaryDirectory)
        try await outbox.recordFailure(
            id: eventID,
            occurredAt: Date(timeIntervalSince1970: 300),
            code: .microphonePermissionDenied,
            message: "Microphone access is off."
        )

        let snapshot = try await outbox.snapshot()
        XCTAssertEqual(snapshot.failures.map(\.id), [eventID])
        XCTAssertEqual(snapshot.failures[0].code, .microphonePermissionDenied)
        XCTAssertTrue(snapshot.items.isEmpty)
        XCTAssertTrue(snapshot.activeAudioCaptures.isEmpty)
        XCTAssertTrue(findAudioFiles(in: temporaryDirectory).isEmpty)
    }

    func testActiveCaptureSurvivesRelaunchForRecovery() async throws {
        let first = WatchCaptureOutbox(rootDirectory: temporaryDirectory)
        let capture = try await first.beginAudioCapture()
        try Data("partial-audio".utf8).write(to: capture.fileURL)

        let relaunched = WatchCaptureOutbox(rootDirectory: temporaryDirectory)
        let snapshot = try await relaunched.snapshot()

        let recovered = try XCTUnwrap(snapshot.activeAudioCaptures.first)
        XCTAssertEqual(recovered.id, capture.id)
        XCTAssertEqual(recovered.mediaID, capture.mediaID)
        XCTAssertEqual(canonicalURL(recovered.fileURL), canonicalURL(capture.fileURL))
        XCTAssertEqual(
            recovered.occurredAt.timeIntervalSince1970,
            capture.occurredAt.timeIntervalSince1970,
            accuracy: 0.001
        )
        XCTAssertEqual(try Data(contentsOf: capture.fileURL), Data("partial-audio".utf8))
    }

    func testDefaultOccurredAtCaptureCanCommit() async throws {
        let outbox = WatchCaptureOutbox(rootDirectory: temporaryDirectory)
        let capture = try await outbox.beginAudioCapture()
        try Data("audio".utf8).write(to: capture.fileURL)

        let event = try await outbox.commitAudioCapture(
            capture,
            source: source,
            durationMilliseconds: 100,
            sampleRateHertz: 16_000,
            channelCount: 1
        )

        XCTAssertEqual(event.id, capture.id)
        XCTAssertEqual(
            event.occurredAt.timeIntervalSince1970,
            capture.occurredAt.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testActiveCaptureUsesCurrentRootAfterContainerMove() async throws {
        let originalRoot = temporaryDirectory.appending(path: "original", directoryHint: .isDirectory)
        let movedRoot = temporaryDirectory.appending(path: "moved", directoryHint: .isDirectory)
        let first = WatchCaptureOutbox(rootDirectory: originalRoot)
        let capture = try await first.beginAudioCapture()
        try Data("audio".utf8).write(to: capture.fileURL)
        try FileManager.default.moveItem(at: originalRoot, to: movedRoot)

        let relaunched = WatchCaptureOutbox(rootDirectory: movedRoot)
        let snapshot = try await relaunched.snapshot()
        let recovered = try XCTUnwrap(snapshot.activeAudioCaptures.first)
        let expectedAudioURL = movedRoot.appending(
            path: "active/\(capture.id.uuidString.lowercased())/audio.m4a"
        )
        XCTAssertEqual(canonicalURL(recovered.fileURL), canonicalURL(expectedAudioURL))

        let event = try await relaunched.commitAudioCapture(
            recovered,
            source: source,
            durationMilliseconds: 100,
            sampleRateHertz: 16_000,
            channelCount: 1
        )
        XCTAssertEqual(event.id, capture.id)
    }

    func testCommittedButtonEventRecoversFromStaging() async throws {
        let outbox = WatchCaptureOutbox(rootDirectory: temporaryDirectory)
        _ = try await outbox.snapshot()
        let event = CaptureEvent(
            id: UUID(),
            type: .buttonPressed,
            occurredAt: .now,
            capturedAt: .now,
            source: source,
            payload: ["button": .string("primary"), "gesture": .string("press")]
        )
        let staging = temporaryDirectory.appending(
            path: "staging/\(event.id.uuidString.lowercased())",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try EventCodec.encode(event).write(to: staging.appending(path: "event.json"), options: .atomic)

        let relaunched = WatchCaptureOutbox(rootDirectory: temporaryDirectory)
        let snapshot = try await relaunched.snapshot()

        XCTAssertEqual(snapshot.items.map(\.event), [event])
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testCorruptPendingCaptureIsQuarantinedWithoutBlockingValidEvents() async throws {
        let outbox = WatchCaptureOutbox(rootDirectory: temporaryDirectory)
        let valid = try await outbox.commitButtonEvent(source: source)
        let corruptID = UUID()
        let corruptDirectory = temporaryDirectory.appending(
            path: "pending/\(corruptID.uuidString.lowercased())",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: corruptDirectory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: corruptDirectory.appending(path: "event.json"))

        let snapshot = try await outbox.snapshot()
        XCTAssertEqual(snapshot.items.map(\.event), [valid])
        XCTAssertEqual(snapshot.failures.first { $0.id == corruptID }?.code, .outboxRecoveryFailed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: corruptDirectory.path))

        let next = try await outbox.commitButtonEvent(source: source)
        let refreshed = try await outbox.snapshot()
        XCTAssertEqual(refreshed.items.map(\.id).sorted(), [valid.id, next.id].sorted())
    }

    func testEmptyAudioCannotBecomeCapturedEvent() async throws {
        let outbox = WatchCaptureOutbox(rootDirectory: temporaryDirectory)
        let capture = try await outbox.beginAudioCapture()
        FileManager.default.createFile(atPath: capture.fileURL.path, contents: Data())

        do {
            _ = try await outbox.commitAudioCapture(
                capture,
                source: source,
                durationMilliseconds: 0,
                sampleRateHertz: 16_000,
                channelCount: 1
            )
            XCTFail("Expected an empty audio error")
        } catch {
            XCTAssertEqual(error as? WatchCaptureOutboxError, .emptyAudioFile)
        }
    }

    private var source: EventSource {
        EventSource(
            kind: .appleWatch,
            installationID: UUID(uuidString: "282c937e-9bbc-49d0-9a96-adb95be343e4")!,
            model: "Apple Watch",
            osVersion: "11.0",
            appVersion: "0.1.0",
            adapter: "watchconnectivity"
        )
    }

    private func findAudioFiles(in directory: URL) -> [URL] {
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        return enumerator?.compactMap { $0 as? URL }.filter { $0.pathExtension == "m4a" } ?? []
    }

    private func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}
