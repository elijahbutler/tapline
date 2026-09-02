import SwiftUI
import WidgetKit

private struct CaptureEntry: TimelineEntry {
    let date: Date
}

private struct CaptureProvider: TimelineProvider {
    func placeholder(in context: Context) -> CaptureEntry {
        CaptureEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (CaptureEntry) -> Void) {
        completion(CaptureEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CaptureEntry>) -> Void) {
        completion(Timeline(entries: [CaptureEntry(date: .now)], policy: .never))
    }
}

private struct CaptureWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Link(destination: URL(string: "tapline://capture")!) {
            switch family {
            case .accessoryInline:
                Label("Tapline capture", systemImage: "waveform")
            case .accessoryRectangular:
                HStack {
                    Image(systemName: "waveform.circle.fill")
                        .font(.title2)
                    VStack(alignment: .leading) {
                        Text("Tapline")
                            .font(.headline)
                        Text("Open capture")
                            .font(.caption)
                    }
                }
            default:
                Image(systemName: "waveform.circle.fill")
                    .font(.title)
                    .accessibilityLabel("Open Tapline capture")
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct TaplineCaptureWidget: Widget {
    let kind = "TaplineCaptureWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CaptureProvider()) { _ in
            CaptureWidgetView()
        }
        .configurationDisplayName("Tapline capture")
        .description("Open Tapline's visible capture screen.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct TaplineWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        TaplineCaptureWidget()
    }
}
