import SwiftUI

@main
struct TaplineApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .task {
                    await model.start()
                }
                .alert(
                    "Tapline",
                    isPresented: Binding(
                        get: { model.alertMessage != nil },
                        set: { if !$0 { model.alertMessage = nil } }
                    ),
                    actions: {
                        Button("OK") { model.alertMessage = nil }
                    },
                    message: {
                        Text(model.alertMessage ?? "")
                    }
                )
        }
    }
}

private struct RootView: View {
    var body: some View {
        TabView {
            DestinationListView()
                .tabItem { Label("Destinations", systemImage: "point.3.connected.trianglepath.dotted") }

            QueueView()
                .tabItem { Label("Queue", systemImage: "tray.full") }

            SettingsView()
                .tabItem { Label("Data", systemImage: "externaldrive") }
        }
    }
}

