import SwiftUI

@main
struct TaplineWatchApp: App {
    @StateObject private var model = WatchCaptureModel()

    var body: some Scene {
        WindowGroup {
            CaptureView()
                .environmentObject(model)
                .task {
                    await model.start()
                }
                .onOpenURL { url in
                    guard url.scheme == "tapline", url.host == "capture" else { return }
                    model.prepareForCaptureEntry()
                }
        }
    }
}
