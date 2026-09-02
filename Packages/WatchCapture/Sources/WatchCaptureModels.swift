import CaptureCore
import Foundation

public struct ActiveAudioCapture: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let mediaID: UUID
    public let occurredAt: Date
    public let fileURL: URL

    public init(id: UUID, mediaID: UUID, occurredAt: Date, fileURL: URL) {
        self.id = id
        self.mediaID = mediaID
        self.occurredAt = occurredAt
        self.fileURL = fileURL
    }
}

public enum WatchCaptureFailureCode: String, Codable, Equatable, Sendable {
    case microphonePermissionDenied = "microphone_permission_denied"
    case recorderStartFailed = "recorder_start_failed"
    case recordingInterrupted = "recording_interrupted"
    case invalidRecording = "invalid_recording"
    case storageUnavailable = "storage_unavailable"
}

public struct WatchCaptureFailure: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let occurredAt: Date
    public let recordedAt: Date
    public let code: WatchCaptureFailureCode
    public let message: String

    public init(
        id: UUID,
        occurredAt: Date,
        recordedAt: Date = .now,
        code: WatchCaptureFailureCode,
        message: String
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.recordedAt = recordedAt
        self.code = code
        self.message = message
    }
}

public struct WatchOutboxItem: Equatable, Sendable, Identifiable {
    public var id: UUID { event.id }
    public let event: CaptureEvent
    public let directoryURL: URL
    public let mediaFileURL: URL?

    public init(event: CaptureEvent, directoryURL: URL, mediaFileURL: URL?) {
        self.event = event
        self.directoryURL = directoryURL
        self.mediaFileURL = mediaFileURL
    }
}

public struct WatchOutboxSnapshot: Equatable, Sendable {
    public let items: [WatchOutboxItem]
    public let failures: [WatchCaptureFailure]
    public let activeAudioCaptures: [ActiveAudioCapture]

    public init(
        items: [WatchOutboxItem],
        failures: [WatchCaptureFailure],
        activeAudioCaptures: [ActiveAudioCapture]
    ) {
        self.items = items
        self.failures = failures
        self.activeAudioCaptures = activeAudioCaptures
    }
}

public enum WatchCaptureOutboxError: Error, Equatable, Sendable {
    case captureAlreadyExists(UUID)
    case captureNotActive(UUID)
    case emptyAudioFile
    case mediaFileMissing
}
