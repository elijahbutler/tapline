import CaptureCore
import CryptoKit
import Foundation

public actor WatchCaptureOutbox {
    public static let audioFilename = "audio.m4a"

    private let rootDirectory: URL
    private let fileManager: FileManager

    public init(rootDirectory: URL, fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
    }

    public static func defaultRootDirectory(fileManager: FileManager = .default) throws -> URL {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return applicationSupport.appending(path: "WatchCaptureOutbox", directoryHint: .isDirectory)
    }

    public func beginAudioCapture(
        id: UUID = UUID(),
        mediaID: UUID = UUID(),
        occurredAt: Date = .now
    ) throws -> ActiveAudioCapture {
        try prepareDirectories()
        try recoverCompletedCaptures()

        let directory = activeDirectory.appending(path: id.uuidString.lowercased(), directoryHint: .isDirectory)
        guard !fileManager.fileExists(atPath: directory.path),
              !fileManager.fileExists(atPath: pendingDirectory.appending(path: id.uuidString.lowercased()).path)
        else {
            throw WatchCaptureOutboxError.captureAlreadyExists(id)
        }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        try applyDataProtection(to: directory)

        let capture = ActiveAudioCapture(
            id: id,
            mediaID: mediaID,
            occurredAt: occurredAt,
            fileURL: directory.appending(path: Self.audioFilename)
        )
        try writeJSON(capture, to: directory.appending(path: draftFilename))
        return capture
    }

    @discardableResult
    public func commitAudioCapture(
        _ capture: ActiveAudioCapture,
        source: EventSource,
        durationMilliseconds: Int,
        sampleRateHertz: Int,
        channelCount: Int,
        interrupted: Bool = false,
        interruptionReason: String? = nil,
        capturedAt: Date = .now
    ) throws -> CaptureEvent {
        try prepareDirectories()
        try recoverCompletedCaptures()

        let directory = activeDirectory.appending(path: capture.id.uuidString.lowercased(), directoryHint: .isDirectory)
        let storedDraft: ActiveAudioCapture = try readJSON(from: directory.appending(path: draftFilename))
        guard storedDraft == capture else {
            throw WatchCaptureOutboxError.captureNotActive(capture.id)
        }
        guard fileManager.fileExists(atPath: capture.fileURL.path) else {
            throw WatchCaptureOutboxError.mediaFileMissing
        }

        let attributes = try fileManager.attributesOfItem(atPath: capture.fileURL.path)
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard byteCount > 0 else {
            throw WatchCaptureOutboxError.emptyAudioFile
        }

        let digest = SHA256.hash(data: try Data(contentsOf: capture.fileURL))
            .map { String(format: "%02x", $0) }
            .joined()

        var payload: [String: JSONValue] = [
            "trigger": .string("in_app_button"),
            "interrupted": .bool(interrupted),
            "encoding": .string("aac_lc"),
            "container": .string("m4a"),
        ]
        if let interruptionReason {
            payload["interruptionReason"] = .string(interruptionReason)
        }

        let event = CaptureEvent(
            id: capture.id,
            type: .audioCaptured,
            occurredAt: capture.occurredAt,
            capturedAt: capturedAt,
            source: source,
            payload: payload,
            media: [
                MediaReference(
                    id: capture.mediaID,
                    role: "audio",
                    mediaType: "audio/mp4",
                    byteCount: byteCount,
                    sha256: digest,
                    durationMilliseconds: max(0, durationMilliseconds),
                    sampleRateHertz: sampleRateHertz,
                    channelCount: channelCount
                ),
            ]
        )

        try writeEvent(event, to: directory)
        try fileManager.removeItem(at: directory.appending(path: draftFilename))
        try applyDataProtection(to: capture.fileURL)
        try moveCommittedDirectory(directory, eventID: event.id)
        return event
    }

    @discardableResult
    public func commitButtonEvent(
        id: UUID = UUID(),
        occurredAt: Date = .now,
        source: EventSource,
        capturedAt: Date = .now
    ) throws -> CaptureEvent {
        try prepareDirectories()
        try recoverCompletedCaptures()

        let destination = pendingDirectory.appending(path: id.uuidString.lowercased(), directoryHint: .isDirectory)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw WatchCaptureOutboxError.captureAlreadyExists(id)
        }

        let staging = stagingDirectory.appending(path: id.uuidString.lowercased(), directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: staging.path) {
            throw WatchCaptureOutboxError.captureAlreadyExists(id)
        }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        try applyDataProtection(to: staging)

        let event = CaptureEvent(
            id: id,
            type: .buttonPressed,
            occurredAt: occurredAt,
            capturedAt: capturedAt,
            source: source,
            payload: [
                "button": .string("primary"),
                "gesture": .string("press"),
            ]
        )
        do {
            try writeEvent(event, to: staging)
            try moveCommittedDirectory(staging, eventID: event.id)
            return event
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    @discardableResult
    public func recordFailure(
        id: UUID,
        occurredAt: Date,
        code: WatchCaptureFailureCode,
        message: String,
        discardActiveCapture: Bool = true
    ) throws -> WatchCaptureFailure {
        try prepareDirectories()

        let failure = WatchCaptureFailure(
            id: id,
            occurredAt: occurredAt,
            code: code,
            message: message
        )
        try writeJSON(failure, to: failureURL(for: id))

        if discardActiveCapture {
            let active = activeDirectory.appending(path: id.uuidString.lowercased(), directoryHint: .isDirectory)
            if fileManager.fileExists(atPath: active.path) {
                try fileManager.removeItem(at: active)
            }
        }
        return failure
    }

    public func snapshot() throws -> WatchOutboxSnapshot {
        try prepareDirectories()
        try recoverCompletedCaptures()

        let items = try directories(in: pendingDirectory).map { directory in
            let event = try EventCodec.decode(Data(contentsOf: directory.appending(path: eventFilename)))
            let mediaURL = event.media.isEmpty ? nil : directory.appending(path: Self.audioFilename)
            return WatchOutboxItem(event: event, directoryURL: directory, mediaFileURL: mediaURL)
        }
        .sorted { $0.event.capturedAt > $1.event.capturedAt }

        let failures = try files(in: failuresDirectory, extension: "json").map {
            try readJSON(WatchCaptureFailure.self, from: $0)
        }
        .sorted { $0.recordedAt > $1.recordedAt }

        let activeCaptures: [ActiveAudioCapture] = try directories(in: activeDirectory).compactMap { directory in
            let draftURL = directory.appending(path: draftFilename)
            guard fileManager.fileExists(atPath: draftURL.path) else { return nil }
            return try readJSON(ActiveAudioCapture.self, from: draftURL)
        }
        .sorted { $0.occurredAt > $1.occurredAt }

        return WatchOutboxSnapshot(items: items, failures: failures, activeAudioCaptures: activeCaptures)
    }

    private var activeDirectory: URL {
        rootDirectory.appending(path: "active", directoryHint: .isDirectory)
    }

    private var failuresDirectory: URL {
        rootDirectory.appending(path: "failures", directoryHint: .isDirectory)
    }

    private var pendingDirectory: URL {
        rootDirectory.appending(path: "pending", directoryHint: .isDirectory)
    }

    private var stagingDirectory: URL {
        rootDirectory.appending(path: "staging", directoryHint: .isDirectory)
    }

    private let draftFilename = "capture.json"
    private let eventFilename = "event.json"

    private func prepareDirectories() throws {
        for directory in [rootDirectory, activeDirectory, pendingDirectory, stagingDirectory, failuresDirectory] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try applyDataProtection(to: directory)
        }
    }

    private func recoverCompletedCaptures() throws {
        for directory in try directories(in: activeDirectory) {
            let eventURL = directory.appending(path: eventFilename)
            guard fileManager.fileExists(atPath: eventURL.path) else { continue }
            let event = try EventCodec.decode(Data(contentsOf: eventURL))
            let draftURL = directory.appending(path: draftFilename)
            if fileManager.fileExists(atPath: draftURL.path) {
                try fileManager.removeItem(at: draftURL)
            }
            try moveCommittedDirectory(directory, eventID: event.id)
        }
    }

    private func moveCommittedDirectory(_ source: URL, eventID: UUID) throws {
        let destination = pendingDirectory.appending(
            path: eventID.uuidString.lowercased(),
            directoryHint: .isDirectory
        )
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw WatchCaptureOutboxError.captureAlreadyExists(eventID)
        }
        try fileManager.moveItem(at: source, to: destination)
    }

    private func writeEvent(_ event: CaptureEvent, to directory: URL) throws {
        let data = try EventCodec.encode(event)
        try data.write(to: directory.appending(path: eventFilename), options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    private func readJSON<T: Decodable>(_ type: T.Type = T.self, from url: URL) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: Data(contentsOf: url))
    }

    private func directories(in directory: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    private func files(in directory: URL, extension fileExtension: String) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == fileExtension }
    }

    private func failureURL(for id: UUID) -> URL {
        failuresDirectory.appending(path: "\(id.uuidString.lowercased()).json")
    }

    private func applyDataProtection(to url: URL) throws {
        #if os(iOS) || os(watchOS)
        try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: url.path)
        #endif
    }
}
