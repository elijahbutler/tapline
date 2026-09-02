import CaptureCore
import EndpointSecurity
import Foundation

public struct RequestFactory: Sendable {
    private let credentialStore: any CredentialStore

    public init(credentialStore: any CredentialStore) {
        self.credentialStore = credentialStore
    }

    public func makeRequest(event: CaptureEvent, destination: Destination) async throws -> URLRequest {
        try destination.validate()
        let url = try destination.endpoint.url(
            tlsRequirement: destination.tlsRequirement,
            networkPolicy: destination.networkPolicy
        )

        var request = URLRequest(url: url)
        request.httpMethod = destination.method.rawValue
        request.httpBody = try EventCodec.encode(event)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(event.id.uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        for header in destination.headers {
            try HeaderValidator.validate(header)
            request.setValue(render(header.value, event: event), forHTTPHeaderField: header.name)
        }

        switch destination.authentication {
        case .none:
            break
        case let .bearer(reference):
            guard let token = try await credentialStore.string(for: reference), !token.isEmpty else {
                throw RequestFactoryError.missingCredential
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case let .basic(username, reference):
            guard let password = try await credentialStore.string(for: reference) else {
                throw RequestFactoryError.missingCredential
            }
            let value = Data("\(username):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(value)", forHTTPHeaderField: "Authorization")
        case let .apiKey(header, reference):
            guard let value = try await credentialStore.string(for: reference), !value.isEmpty else {
                throw RequestFactoryError.missingCredential
            }
            request.setValue(value, forHTTPHeaderField: header)
        }

        return request
    }

    private func render(_ template: String, event: CaptureEvent) -> String {
        template
            .replacingOccurrences(of: "{{event.id}}", with: event.id.uuidString.lowercased())
            .replacingOccurrences(of: "{{event.type}}", with: event.type.rawValue)
    }
}

public enum RequestFactoryError: Error, Equatable, Sendable, LocalizedError {
    case missingCredential

    public var errorDescription: String? {
        switch self {
        case .missingCredential: "The destination credential is missing."
        }
    }
}
