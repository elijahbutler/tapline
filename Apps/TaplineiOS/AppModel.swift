import CaptureCore
import CaptureStore
import Combine
import DeliveryKit
import EndpointSecurity
import Foundation
import UIKit

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var destinations: [Destination] = []
    @Published private(set) var queueItems: [QueueItem] = []
    @Published private(set) var isWorking = false
    @Published var alertMessage: String?
    @Published private(set) var exportURL: URL?

    private let store: CaptureStore?
    private let credentials: KeychainCredentialStore
    private let client: URLSessionHTTPClient
    private let workerID = UUID()
    private let source: EventSource
    private var started = false

    init() {
        credentials = KeychainCredentialStore()
        client = URLSessionHTTPClient()

        let identity = InstallationIdentity.loadOrCreate()
        source = EventSource(
            kind: .iPhone,
            installationID: identity.id,
            model: UIDevice.current.model,
            osVersion: UIDevice.current.systemVersion,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            adapter: "iphone"
        )

        do {
            let url = try CaptureStore.applicationDatabaseURL()
            store = try CaptureStore(databaseURL: url)
        } catch {
            store = nil
            alertMessage = "Tapline could not open its local database. \(error.localizedDescription)"
        }
    }

    func start() async {
        guard !started else { return }
        started = true
        await refresh()
        while !Task.isCancelled {
            await processReadyJobs()
            try? await Task.sleep(for: .seconds(30))
        }
    }

    @discardableResult
    func save(_ draft: DestinationDraft) async -> Bool {
        guard let store else { return false }
        isWorking = true
        defer { isWorking = false }

        do {
            let plan = try await authentication(for: draft)
            let destination: Destination
            do {
                destination = try draft.destination(authentication: plan.authentication)
                try await store.saveDestination(destination)
            } catch {
                if let reference = plan.createdReference {
                    try? await credentials.delete(reference)
                }
                throw error
            }

            let retained = Set(plan.authentication.credentialReferences)
            for reference in draft.existingAuthentication.credentialReferences where !retained.contains(reference) {
                try await credentials.delete(reference)
            }

            await refresh()
            return true
        } catch {
            alertMessage = error.localizedDescription
            return false
        }
    }

    func deleteDestination(_ destination: Destination) async {
        guard let store else { return }
        do {
            try await store.deleteDestination(id: destination.id)
            for reference in destination.authentication.credentialReferences {
                try await credentials.delete(reference)
            }
            await refresh()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func testDestination(_ destination: Destination) async {
        guard let store else { return }
        isWorking = true
        defer { isWorking = false }

        do {
            let event = CaptureEvent.deliveryTest(destinationID: destination.id, source: source)
            let jobs = try await store.enqueue(event, destinationIDs: [destination.id])
            await refresh()
            if let job = jobs.first {
                await deliver(jobID: job.id)
            }
            await refresh()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func retry(_ job: DeliveryJob) async {
        guard let store else { return }
        do {
            try await store.requeue(jobID: job.id)
            await deliver(jobID: job.id)
            await refresh()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func processReadyJobs() async {
        guard let store else { return }
        do {
            let ids = try await store.readyJobIDs()
            for id in ids {
                await deliver(jobID: id)
            }
            await refresh()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func deleteEvent(_ id: UUID) async {
        guard let store else { return }
        do {
            try await store.deleteEvent(id: id)
            await refresh()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func deleteAllEvents() async {
        guard let store else { return }
        do {
            try await store.deleteAllEvents()
            exportURL = nil
            await refresh()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func prepareExport() async {
        guard let store else { return }
        do {
            let snapshot = try await store.exportSnapshot()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            let directory = FileManager.default.temporaryDirectory
                .appending(path: "Tapline Exports", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appending(path: "tapline-export.json", directoryHint: .notDirectory)
            try data.write(to: url, options: .atomic)
            exportURL = url
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func eventJSON(_ event: CaptureEvent) -> String {
        guard let data = try? EventCodec.encode(event, prettyPrinted: true) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private func refresh() async {
        guard let store else { return }
        do {
            async let loadedDestinations = store.destinations()
            async let loadedItems = store.queueItems()
            destinations = try await loadedDestinations
            queueItems = try await loadedItems
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func authentication(for draft: DestinationDraft) async throws -> AuthenticationPlan {
        switch draft.authenticationKind {
        case .none:
            return AuthenticationPlan(authentication: .none, createdReference: nil)
        case .bearer:
            let reference: CredentialReference
            let createdReference: CredentialReference?
            if case let .bearer(existing) = draft.existingAuthentication {
                reference = existing
                createdReference = nil
            } else {
                reference = CredentialReference()
                createdReference = reference
            }
            try await storeSecret(draft.secret, reference: reference, existing: draft.existingAuthentication)
            return AuthenticationPlan(
                authentication: .bearer(token: reference),
                createdReference: createdReference
            )
        case .basic:
            guard !draft.username.isEmpty else {
                throw DestinationFormError.missingUsername
            }
            let reference: CredentialReference
            let createdReference: CredentialReference?
            if case let .basic(_, existing) = draft.existingAuthentication {
                reference = existing
                createdReference = nil
            } else {
                reference = CredentialReference()
                createdReference = reference
            }
            try await storeSecret(draft.secret, reference: reference, existing: draft.existingAuthentication)
            return AuthenticationPlan(
                authentication: .basic(username: draft.username, password: reference),
                createdReference: createdReference
            )
        case .apiKey:
            guard !draft.username.isEmpty else {
                throw DestinationFormError.missingHeaderName
            }
            let reference: CredentialReference
            let createdReference: CredentialReference?
            if case let .apiKey(_, existing) = draft.existingAuthentication {
                reference = existing
                createdReference = nil
            } else {
                reference = CredentialReference()
                createdReference = reference
            }
            try await storeSecret(draft.secret, reference: reference, existing: draft.existingAuthentication)
            return AuthenticationPlan(
                authentication: .apiKey(header: draft.username, value: reference),
                createdReference: createdReference
            )
        }
    }

    private func storeSecret(
        _ secret: String,
        reference: CredentialReference,
        existing: DestinationAuthentication
    ) async throws {
        if !secret.isEmpty {
            try await credentials.set(secret, for: reference)
            return
        }
        let existingReferences = Set(existing.credentialReferences)
        guard existingReferences.contains(reference), try await credentials.value(for: reference) != nil else {
            throw DestinationFormError.missingSecret
        }
    }

    private func deliver(jobID: UUID) async {
        guard let store else { return }

        do {
            guard let envelope = try await store.lease(jobID: jobID, owner: workerID) else { return }
            do {
                let factory = RequestFactory(credentialStore: credentials)
                let request = try await factory.makeRequest(
                    event: envelope.event,
                    destination: envelope.destination
                )
                let response = try await client.send(
                    request,
                    networkPolicy: envelope.destination.networkPolicy
                )
                let disposition = RetryClassifier().classify(
                    response: response,
                    attempt: envelope.job.attemptCount,
                    policy: envelope.destination.retryPolicy
                )
                try await store.record(disposition, for: jobID)
            } catch {
                let disposition = RetryClassifier().classify(
                    error: error,
                    attempt: envelope.job.attemptCount,
                    policy: envelope.destination.retryPolicy
                )
                try await store.record(disposition, for: jobID)
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }
}

private struct AuthenticationPlan {
    let authentication: DestinationAuthentication
    let createdReference: CredentialReference?
}

enum DestinationFormError: Error, LocalizedError {
    case missingUsername
    case missingHeaderName
    case missingSecret

    var errorDescription: String? {
        switch self {
        case .missingUsername: "Enter a username."
        case .missingHeaderName: "Enter an API key header name."
        case .missingSecret: "Enter a credential."
        }
    }
}
