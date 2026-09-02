import SwiftUI

struct CaptureView: View {
    @EnvironmentObject private var model: WatchCaptureModel

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                status
                recordControl
                Button {
                    Task { await model.captureButtonEvent() }
                } label: {
                    Label("Save event", systemImage: "bolt.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(model.controlsDisabled || model.isRecording)

                Text(queueSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
        }
    }

    private var status: some View {
        VStack(spacing: 3) {
            if model.isRecording {
                Text(format(model.elapsed))
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.red)
            }
            Text(model.state.message)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(statusColor)
                .lineLimit(3)
        }
        .frame(minHeight: 36)
        .accessibilityElement(children: .combine)
    }

    private var recordControl: some View {
        Button {
            Task { await model.handleRecordControl() }
        } label: {
            ZStack {
                Circle()
                    .fill(model.isRecording ? Color.red : Color.red.opacity(0.22))
                    .frame(width: 92, height: 92)
                if model.isRecording {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.white)
                        .frame(width: 30, height: 30)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.red)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(model.controlsDisabled)
        .accessibilityLabel(model.isRecording ? "Stop recording" : "Start recording")
        .accessibilityHint("Recordings stop automatically after 60 seconds")
        .handGestureShortcut(.primaryAction)
    }

    private var statusColor: Color {
        switch model.state {
        case .failed:
            .orange
        case .interrupted:
            .yellow
        case .recording:
            .red
        default:
            .secondary
        }
    }

    private var queueSummary: String {
        let captured = "\(model.queuedCount) saved"
        return model.failedCount == 0 ? captured : "\(captured), \(model.failedCount) failed"
    }

    private func format(_ duration: TimeInterval) -> String {
        let tenths = Int((duration * 10).rounded(.down))
        return String(format: "%d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
    }
}
