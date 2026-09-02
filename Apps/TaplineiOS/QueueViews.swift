import CaptureCore
import CaptureStore
import SwiftUI

struct QueueView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            Group {
                if model.queueItems.isEmpty {
                    ContentUnavailableView {
                        Label("Queue is empty", systemImage: "tray")
                    } description: {
                        Text("Destination tests and later watch captures appear here before delivery.")
                    }
                } else {
                    List {
                        ForEach(model.queueItems) { item in
                            NavigationLink {
                                EventDetailView(item: item)
                            } label: {
                                QueueRow(item: item)
                            }
                            .swipeActions(edge: .trailing) {
                                Button("Delete", role: .destructive) {
                                    Task { await model.deleteEvent(item.id) }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Queue")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Retry ready", systemImage: "arrow.clockwise") {
                        Task { await model.processReadyJobs() }
                    }
                }
            }
        }
    }
}

private struct QueueRow: View {
    let item: QueueItem

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(item.event.type.rawValue)
                    .font(.headline)
                Spacer()
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(summaryColor)
            }
            Text(item.event.occurredAt, format: .dateTime.month().day().hour().minute().second())
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(item.event.id.uuidString.lowercased())
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 3)
    }

    private var summary: String {
        if item.deliveries.isEmpty { return "Stored locally" }
        if item.deliveries.allSatisfy({ $0.state == .delivered }) { return "Delivered" }
        if item.deliveries.contains(where: { $0.state == .failedPermanent || $0.state == .pausedAuthentication }) {
            return "Needs attention"
        }
        return "Queued"
    }

    private var summaryColor: Color {
        switch summary {
        case "Delivered": .green
        case "Needs attention": .orange
        default: .secondary
        }
    }
}

private struct EventDetailView: View {
    @EnvironmentObject private var model: AppModel
    let item: QueueItem

    var body: some View {
        List {
            Section("Event") {
                LabeledContent("Type", value: item.event.type.rawValue)
                LabeledContent("Captured", value: item.event.capturedAt.formatted())
                LabeledContent("Source", value: item.event.source.kind.rawValue)
                LabeledContent("ID") {
                    Text(item.event.id.uuidString.lowercased())
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }

            Section("Deliveries") {
                if item.deliveries.isEmpty {
                    Text("This event is stored locally and has no destination jobs.")
                        .foregroundStyle(.secondary)
                }
                ForEach(item.deliveries) { job in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(job.state.title)
                            Spacer()
                            Text("Attempt \(job.attemptCount)")
                                .foregroundStyle(.secondary)
                        }
                        if let status = job.lastHTTPStatus {
                            Text("HTTP \(status)")
                                .font(.caption)
                        }
                        if let code = job.lastErrorCode {
                            Text(code)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        if job.state != .delivered && job.state != .attempting {
                            Button("Retry now") {
                                Task { await model.retry(job) }
                            }
                            .font(.caption)
                        }
                    }
                }
            }

            Section("Stored JSON") {
                Text(model.eventJSON(item.event))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
        .navigationTitle(item.event.type.rawValue)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private extension DeliveryState {
    var title: String {
        switch self {
        case .queued: "Queued"
        case .attempting: "Attempting"
        case .retryWait: "Waiting to retry"
        case .delivered: "Delivered"
        case .pausedAuthentication: "Authentication required"
        case .failedPermanent: "Failed"
        }
    }
}

