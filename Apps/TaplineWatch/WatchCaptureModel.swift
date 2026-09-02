@preconcurrency import AVFoundation
import CaptureCore
import Foundation
import SwiftUI
import WatchCapture
import WatchKit

enum WatchCaptureUIState: Equatable {
    case loading
    case idle
    case requestingPermission
    case recording
    case saving
    case saved(String)
    case interrupted(String)
    case failed(String)

    var message: String {
        switch self {
        case .loading:
            "Loading captures"
        case .idle:
            "Ready"
        case .requestingPermission:
            "Waiting for microphone access"
        case .recording:
            "Recording"
        case .saving:
            "Saving locally"
        case let .saved(message), let .interrupted(message), let .failed(message):
            message
        }
    }
}

private struct AudioInspection: Sendable {
    let durationMilliseconds: Int
    let sampleRateHertz: Int
    let channelCount: Int
}

@MainActor
final class WatchCaptureModel: NSObject, ObservableObject {
    static let maximumDuration: TimeInterval = 60

    @Published private(set) var state: WatchCaptureUIState = .loading
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var queuedCount = 0
    @Published private(set) var failedCount = 0

    var isRecording: Bool { state == .recording }
    var controlsDisabled: Bool {
        switch state {
        case .loading, .requestingPermission, .saving:
            true
        default:
            false
        }
    }

    private let outbox: WatchCaptureOutbox?
    private let initializationError: String?
    private var recorder: AVAudioRecorder?
    private var activeCapture: ActiveAudioCapture?
    private var recordingStartedAt: Date?
    private var elapsedTask: Task<Void, Never>?
    private var interruptionTask: Task<Void, Never>?
    private var routeChangeTask: Task<Void, Never>?
    private var isFinalizing = false

    override init() {
        do {
            outbox = WatchCaptureOutbox(rootDirectory: try WatchCaptureOutbox.defaultRootDirectory())
            initializationError = nil
        } catch {
            outbox = nil
            initializationError = "Local storage is unavailable."
        }
        super.init()
    }

    deinit {
        elapsedTask?.cancel()
        interruptionTask?.cancel()
        routeChangeTask?.cancel()
    }

    func start() async {
        guard let outbox else {
            state = .failed(initializationError ?? "Local storage is unavailable.")
            return
        }

        observeAudioSession()
        do {
            let snapshot = try await outbox.snapshot()
            for capture in snapshot.activeAudioCaptures {
                await recover(capture, using: outbox)
            }
            let refreshed = try await refreshSnapshot(using: outbox)
            if case .loading = state {
                if let failure = refreshed.failures.first,
                   failure.recordedAt > (refreshed.items.first?.event.capturedAt ?? .distantPast) {
                    state = .failed(failure.message)
                } else {
                    state = .idle
                }
            }
        } catch {
            state = .failed("Tapline could not read its local capture queue.")
        }
    }

    func handleRecordControl() async {
        if isRecording {
            await finishRecording(interrupted: false, reason: nil)
        } else {
            await beginRecording()
        }
    }

    func captureButtonEvent() async {
        guard !controlsDisabled, !isRecording, let outbox else { return }
        state = .saving
        do {
            _ = try await outbox.commitButtonEvent(source: eventSource)
            _ = try? await refreshSnapshot(using: outbox)
            state = .saved("Event saved on this watch")
        } catch {
            state = .failed("The event could not be saved. Check watch storage.")
        }
    }

    func prepareForCaptureEntry() {
        guard !isRecording, !controlsDisabled else { return }
        state = .idle
    }

    private func beginRecording() async {
        guard !controlsDisabled, let outbox else {
            state = .failed(initializationError ?? "Local storage is unavailable.")
            return
        }

        let eventID = UUID()
        let occurredAt = Date.now
        state = .requestingPermission

        guard await AVAudioApplication.requestRecordPermission() else {
            do {
                try await outbox.recordFailure(
                    id: eventID,
                    occurredAt: occurredAt,
                    code: .microphonePermissionDenied,
                    message: "Microphone access is off. Enable it in Settings to record."
                )
                try await refreshSnapshot(using: outbox)
            } catch {
                state = .failed("Microphone access is off, and the failed capture could not be saved.")
                return
            }
            state = .failed("Microphone access is off. Enable it in Settings to record.")
            return
        }

        do {
            let capture = try await outbox.beginAudioCapture(id: eventID, occurredAt: occurredAt)
            activeCapture = capture

            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)

            let recorder = try AVAudioRecorder(url: capture.fileURL, settings: Self.recordingSettings)
            recorder.delegate = self
            guard recorder.prepareToRecord(), recorder.record(forDuration: Self.maximumDuration) else {
                throw WatchRecorderError.couldNotStart
            }

            self.recorder = recorder
            recordingStartedAt = .now
            elapsed = 0
            state = .recording
            startElapsedUpdates()
        } catch {
            recorder?.stop()
            recorder = nil
            try? AVAudioSession.sharedInstance().setActive(false)
            if let capture = activeCapture {
                _ = try? await outbox.recordFailure(
                    id: capture.id,
                    occurredAt: capture.occurredAt,
                    code: .recorderStartFailed,
                    message: "Recording could not start. Try again in a quiet app state."
                )
            } else {
                _ = try? await outbox.recordFailure(
                    id: eventID,
                    occurredAt: occurredAt,
                    code: .storageUnavailable,
                    message: "Recording could not start because local storage is unavailable."
                )
            }
            activeCapture = nil
            _ = try? await refreshSnapshot(using: outbox)
            state = .failed("Recording could not start. Check microphone access and watch storage.")
        }
    }

    private func finishRecording(interrupted: Bool, reason: String?) async {
        guard !isFinalizing, let recorder, let capture = activeCapture, let outbox else { return }
        isFinalizing = true
        defer { isFinalizing = false }
        elapsedTask?.cancel()
        elapsedTask = nil

        let recorderDuration = recorder.currentTime
        recorder.delegate = nil
        recorder.stop()
        self.recorder = nil
        recordingStartedAt = nil
        state = .saving
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        let inspection: AudioInspection
        do {
            inspection = try Self.inspectAudio(at: capture.fileURL, fallbackDuration: recorderDuration)
        } catch AudioInspectionError.invalidRecording {
            _ = try? await outbox.recordFailure(
                id: capture.id,
                occurredAt: capture.occurredAt,
                code: interrupted ? .recordingInterrupted : .invalidRecording,
                message: interrupted
                    ? "Audio changed before a playable clip could be saved."
                    : "The recording closed but did not produce a playable clip."
            )
            activeCapture = nil
            elapsed = 0
            _ = try? await refreshSnapshot(using: outbox)
            state = .failed(
                interrupted
                    ? "Audio changed before a playable clip could be saved."
                    : "The recording could not be saved as playable audio."
            )
            return
        } catch {
            activeCapture = nil
            elapsed = 0
            state = .failed("Recording is saved locally and will retry when Tapline opens again.")
            return
        }

        do {
            _ = try await outbox.commitAudioCapture(
                capture,
                source: eventSource,
                durationMilliseconds: inspection.durationMilliseconds,
                sampleRateHertz: inspection.sampleRateHertz,
                channelCount: inspection.channelCount,
                interrupted: interrupted,
                interruptionReason: reason
            )
        } catch {
            activeCapture = nil
            elapsed = 0
            _ = try? await refreshSnapshot(using: outbox)
            state = .failed("Recording is saved locally and will retry when Tapline opens again.")
            return
        }

        activeCapture = nil
        elapsed = 0
        _ = try? await refreshSnapshot(using: outbox)
        if interrupted {
            state = .interrupted("Audio changed. The finished part was saved.")
        } else {
            state = .saved("Recording saved on this watch")
        }
    }

    private func recover(_ capture: ActiveAudioCapture, using outbox: WatchCaptureOutbox) async {
        let inspection: AudioInspection
        do {
            inspection = try Self.inspectAudio(at: capture.fileURL, fallbackDuration: 0)
        } catch AudioInspectionError.invalidRecording {
            _ = try? await outbox.recordFailure(
                id: capture.id,
                occurredAt: capture.occurredAt,
                code: .recordingInterrupted,
                message: "Tapline closed before the recording became playable."
            )
            state = .failed("A previous recording ended before it became playable.")
            return
        } catch {
            state = .failed("A previous recording is saved locally and will retry.")
            return
        }

        do {
            _ = try await outbox.commitAudioCapture(
                capture,
                source: eventSource,
                durationMilliseconds: inspection.durationMilliseconds,
                sampleRateHertz: inspection.sampleRateHertz,
                channelCount: inspection.channelCount,
                interrupted: true,
                interruptionReason: "app_ended_before_finalize"
            )
            state = .interrupted("An interrupted recording was recovered.")
        } catch {
            state = .failed("A previous recording is saved locally and will retry.")
        }
    }

    @discardableResult
    private func refreshSnapshot(using outbox: WatchCaptureOutbox) async throws -> WatchOutboxSnapshot {
        let snapshot = try await outbox.snapshot()
        queuedCount = snapshot.items.count
        failedCount = snapshot.failures.count
        return snapshot
    }

    private func startElapsedUpdates() {
        elapsedTask?.cancel()
        elapsedTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let startedAt = self.recordingStartedAt else { return }
                self.elapsed = min(Self.maximumDuration, Date.now.timeIntervalSince(startedAt))
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func observeAudioSession() {
        guard interruptionTask == nil, routeChangeTask == nil else { return }

        interruptionTask = Task { @MainActor [weak self] in
            let interruptionTypes = NotificationCenter.default
                .notifications(named: AVAudioSession.interruptionNotification)
                .compactMap { notification in
                    notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                }
            for await rawValue in interruptionTypes {
                guard AVAudioSession.InterruptionType(rawValue: rawValue) == .began,
                      self?.isRecording == true
                else { continue }
                await self?.finishRecording(
                    interrupted: true,
                    reason: "audio_session_interruption"
                )
            }
        }

        routeChangeTask = Task { @MainActor [weak self] in
            let routeChangeReasons = NotificationCenter.default
                .notifications(named: AVAudioSession.routeChangeNotification)
                .compactMap { notification in
                    notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                }
            for await rawValue in routeChangeReasons {
                guard let reason = AVAudioSession.RouteChangeReason(rawValue: rawValue),
                      reason != .categoryChange,
                      self?.isRecording == true
                else { continue }
                await self?.finishRecording(
                    interrupted: true,
                    reason: "audio_route_changed_\(rawValue)"
                )
            }
        }
    }

    private var eventSource: EventSource {
        EventSource(
            kind: .appleWatch,
            installationID: InstallationIdentity.loadOrCreate().id,
            model: WKInterfaceDevice.current().localizedModel,
            osVersion: WKInterfaceDevice.current().systemVersion,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            adapter: "watch_app"
        )
    }

    private static let recordingSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 24_000,
        AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
    ]

    private static func inspectAudio(at url: URL, fallbackDuration: TimeInterval) throws -> AudioInspection {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain, error.code == NSFileNoSuchFileError {
                throw AudioInspectionError.invalidRecording
            }
            throw error
        }
        guard (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0 else {
            throw AudioInspectionError.invalidRecording
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            guard isStructurallyInvalidAudio(error) else { throw error }
            throw AudioInspectionError.invalidRecording
        }
        let format = file.processingFormat
        let measuredDuration = format.sampleRate > 0
            ? Double(file.length) / format.sampleRate
            : fallbackDuration
        let duration = max(measuredDuration, fallbackDuration)
        guard duration > 0, format.channelCount > 0 else {
            throw AudioInspectionError.invalidRecording
        }

        return AudioInspection(
            durationMilliseconds: Int((duration * 1_000).rounded()),
            sampleRateHertz: Int(format.sampleRate.rounded()),
            channelCount: Int(format.channelCount)
        )
    }

    private static func isStructurallyInvalidAudio(_ error: Error) -> Bool {
        let error = error as NSError
        guard error.domain == NSOSStatusErrorDomain else { return false }
        let invalidAudioCodes: Set<Int> = [
            0x7479703F, // typ?
            0x666D743F, // fmt?
            0x63686B3F, // chk?
            0x70636B3F, // pck?
            0x6474613F, // dta?
        ]
        return invalidAudioCodes.contains(error.code)
    }
}

private enum WatchRecorderError: Error {
    case couldNotStart
}

private enum AudioInspectionError: Error {
    case invalidRecording
}

extension WatchCaptureModel: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, !self.isFinalizing else { return }
            await self.finishRecording(
                interrupted: !flag,
                reason: flag ? nil : "recorder_stopped_unsuccessfully"
            )
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, !self.isFinalizing else { return }
            await self.finishRecording(
                interrupted: true,
                reason: "audio_encoder_error"
            )
        }
    }
}
