import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmsDeletion = false

    var body: some View {
        NavigationStack {
            List {
                Section("Local-first behavior") {
                    Label("No account or Tapline server", systemImage: "person.crop.circle.badge.xmark")
                    Label("No analytics or advertising SDK", systemImage: "eye.slash")
                    Label("Credentials stay in Keychain", systemImage: "key")
                    Text("Tapline sends events only to destinations you create and enable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Export") {
                    Button("Prepare JSON export") {
                        Task { await model.prepareExport() }
                    }
                    if let exportURL = model.exportURL {
                        ShareLink(item: exportURL) {
                            Label("Share current export", systemImage: "square.and.arrow.up")
                        }
                    }
                    Text("Exports contain event data, destination settings, and delivery history. They never contain Keychain credentials.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Deletion") {
                    Button("Delete all events", role: .destructive) {
                        confirmsDeletion = true
                    }
                    Text("This removes local event and delivery records. Destination settings and credentials remain until you delete each destination.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Version") {
                    LabeledContent(
                        "App",
                        value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
                    )
                    LabeledContent("Event schema", value: "1")
                }
            }
            .navigationTitle("Data")
            .confirmationDialog(
                "Delete every local event?",
                isPresented: $confirmsDeletion,
                titleVisibility: .visible
            ) {
                Button("Delete all events", role: .destructive) {
                    Task { await model.deleteAllEvents() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This cannot be undone. Export first if you need a copy.")
            }
        }
    }
}
