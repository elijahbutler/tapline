import CaptureCore
import DeliveryKit
import SwiftUI

struct DestinationListView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editingDraft: DestinationDraft?

    var body: some View {
        NavigationStack {
            Group {
                if model.destinations.isEmpty {
                    ContentUnavailableView {
                        Label("No destinations", systemImage: "network.slash")
                    } description: {
                        Text("Add a local server or HTTPS endpoint. Tapline sends nothing until you test or queue an event.")
                    } actions: {
                        Button("Add destination") {
                            editingDraft = DestinationDraft()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(model.destinations) { destination in
                            DestinationRow(destination: destination) {
                                editingDraft = DestinationDraft(destination: destination)
                            }
                        }
                        .onDelete { offsets in
                            let selected = offsets.map { model.destinations[$0] }
                            Task {
                                for destination in selected {
                                    await model.deleteDestination(destination)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Destinations")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add destination", systemImage: "plus") {
                        editingDraft = DestinationDraft()
                    }
                }
            }
            .sheet(item: $editingDraft) { draft in
                DestinationEditorView(initialDraft: draft)
            }
        }
    }
}

private struct DestinationRow: View {
    @EnvironmentObject private var model: AppModel
    let destination: Destination
    let edit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(destination.name)
                        .font(.headline)
                    Text(endpointDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if !destination.enabled {
                    Text("Paused")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Edit", action: edit)
                    .buttonStyle(.bordered)
                Button("Send test") {
                    Task { await model.testDestination(destination) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isWorking)
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
    }

    private var endpointDescription: String {
        let port = destination.endpoint.port.map { ":\($0)" } ?? ""
        return "\(destination.endpoint.scheme)://\(destination.endpoint.host)\(port)\(destination.endpoint.path)"
    }
}

private struct DestinationEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: DestinationDraft

    init(initialDraft: DestinationDraft) {
        _draft = State(initialValue: initialDraft)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Destination") {
                    TextField("Name", text: $draft.name)
                    Toggle("Enabled", isOn: $draft.enabled)
                }

                Section("Endpoint") {
                    Picker("Scheme", selection: $draft.scheme) {
                        Text("HTTPS").tag("https")
                        Text("HTTP").tag("http")
                    }
                    TextField("Hostname or IP address", text: $draft.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port, optional", text: $draft.port)
                        .keyboardType(.numberPad)
                    TextField("Path", text: $draft.path)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("Method", selection: $draft.method) {
                        ForEach(HTTPMethod.allCases, id: \.self) { method in
                            Text(method.rawValue).tag(method)
                        }
                    }
                }

                Section("Network") {
                    Picker("Allowed network", selection: $draft.networkPolicy) {
                        Text("Local network only").tag(NetworkPolicy.localNetworkOnly)
                        Text("Wi-Fi only").tag(NetworkPolicy.wifiOnly)
                        Text("Any network").tag(NetworkPolicy.anyNetwork)
                    }
                    Picker("Transport security", selection: $draft.tlsRequirement) {
                        Text("Require HTTPS").tag(TLSRequirement.requireHTTPS)
                        Text("Allow local HTTP").tag(TLSRequirement.allowHTTPForLocalHost)
                    }
                    Text("Plain HTTP is rejected unless the host is a private IP address, localhost, or a .local name.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Authentication") {
                    Picker("Type", selection: $draft.authenticationKind) {
                        ForEach(AuthenticationKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    if draft.authenticationKind == .basic || draft.authenticationKind == .apiKey {
                        TextField(
                            draft.authenticationKind == .basic ? "Username" : "Header name",
                            text: $draft.username
                        )
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    if draft.authenticationKind != .none {
                        SecureField("Credential", text: $draft.secret)
                        if !draft.existingAuthentication.credentialReferences.isEmpty {
                            Text("Leave this blank to keep the stored credential.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Headers") {
                    TextEditor(text: $draft.headersText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 90)
                    Text("Use one Name: value header per line. Templates may contain {{event.id}} or {{event.type}}.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Header values are stored in the event database and included in exports. Use the Authentication section for secrets.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Event filters") {
                    Text("No selection sends every event type.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(EventType.allCases, id: \.self) { type in
                        Toggle(
                            type.rawValue,
                            isOn: Binding(
                                get: { draft.includedTypes.contains(type) },
                                set: { enabled in
                                    if enabled {
                                        draft.includedTypes.insert(type)
                                    } else {
                                        draft.includedTypes.remove(type)
                                    }
                                }
                            )
                        )
                    }
                }

                Section("Retry policy") {
                    Stepper("Maximum attempts: \(draft.maximumAttempts)", value: $draft.maximumAttempts, in: 1 ... 50)
                    Stepper(
                        "Initial delay: \(Int(draft.initialDelaySeconds)) seconds",
                        value: $draft.initialDelaySeconds,
                        in: 1 ... 300,
                        step: 1
                    )
                    Stepper(
                        "Maximum delay: \(Int(draft.maximumDelaySeconds)) seconds",
                        value: $draft.maximumDelaySeconds,
                        in: max(1, draft.initialDelaySeconds) ... 86_400,
                        step: 30
                    )
                }
            }
            .navigationTitle(draft.name.isEmpty ? "New destination" : draft.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            if await model.save(draft) {
                                dismiss()
                            }
                        }
                    }
                    .disabled(model.isWorking)
                }
            }
        }
    }
}
