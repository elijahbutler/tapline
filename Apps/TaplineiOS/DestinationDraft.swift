import CaptureCore
import DeliveryKit
import EndpointSecurity
import Foundation

enum AuthenticationKind: String, CaseIterable, Identifiable {
    case none
    case bearer
    case basic
    case apiKey

    var id: Self { self }

    var title: String {
        switch self {
        case .none: "None"
        case .bearer: "Bearer token"
        case .basic: "Basic authentication"
        case .apiKey: "API key header"
        }
    }
}

struct DestinationDraft: Identifiable {
    let id: UUID
    var name: String
    var enabled: Bool
    var scheme: String
    var host: String
    var port: String
    var path: String
    var method: HTTPMethod
    var headersText: String
    var authenticationKind: AuthenticationKind
    var username: String
    var secret: String
    var existingAuthentication: DestinationAuthentication
    var tlsRequirement: TLSRequirement
    var includedTypes: Set<EventType>
    var maximumAttempts: Int
    var initialDelaySeconds: Double
    var maximumDelaySeconds: Double
    var networkPolicy: NetworkPolicy

    init(destination: Destination? = nil) {
        id = destination?.id ?? UUID()
        name = destination?.name ?? ""
        enabled = destination?.enabled ?? true
        scheme = destination?.endpoint.scheme ?? "http"
        host = destination?.endpoint.host ?? ""
        port = destination?.endpoint.port.map(String.init) ?? ""
        path = destination?.endpoint.path ?? "/capture"
        method = destination?.method ?? .post
        headersText = destination?.headers.map { "\($0.name): \($0.value)" }.joined(separator: "\n") ?? ""
        existingAuthentication = destination?.authentication ?? .none
        secret = ""
        tlsRequirement = destination?.tlsRequirement ?? .allowHTTPForLocalHost
        includedTypes = destination?.filter.includedTypes ?? []
        maximumAttempts = destination?.retryPolicy.maximumAttempts ?? 10
        initialDelaySeconds = destination?.retryPolicy.initialDelaySeconds ?? 5
        maximumDelaySeconds = destination?.retryPolicy.maximumDelaySeconds ?? 3_600
        networkPolicy = destination?.networkPolicy ?? .localNetworkOnly

        switch destination?.authentication ?? .none {
        case .none:
            authenticationKind = .none
            username = ""
        case .bearer:
            authenticationKind = .bearer
            username = ""
        case let .basic(value, _):
            authenticationKind = .basic
            username = value
        case let .apiKey(header, _):
            authenticationKind = .apiKey
            username = header
        }
    }

    func destination(authentication: DestinationAuthentication) throws -> Destination {
        let parsedPort: Int?
        if port.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parsedPort = nil
        } else if let value = Int(port) {
            parsedPort = value
        } else {
            throw DestinationValidationError.invalidPort
        }

        let destination = Destination(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            enabled: enabled,
            endpoint: Endpoint(
                scheme: scheme,
                host: host,
                port: parsedPort,
                path: path
            ),
            method: method,
            headers: try parseHeaders(),
            authentication: authentication,
            tlsRequirement: tlsRequirement,
            filter: EventFilter(includedTypes: includedTypes),
            payloadTemplate: .eventJSON,
            retryPolicy: RetryPolicy(
                maximumAttempts: maximumAttempts,
                initialDelaySeconds: initialDelaySeconds,
                maximumDelaySeconds: maximumDelaySeconds
            ),
            networkPolicy: networkPolicy
        )
        try destination.validate()
        return destination
    }

    private func parseHeaders() throws -> [HeaderTemplate] {
        try headersText
            .split(whereSeparator: \.isNewline)
            .map { line in
                let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else {
                    throw DestinationValidationError.invalidHeaderName(String(line))
                }
                return HeaderTemplate(
                    name: String(parts[0]).trimmingCharacters(in: .whitespaces),
                    value: String(parts[1]).trimmingCharacters(in: .whitespaces)
                )
            }
    }
}

extension DestinationAuthentication {
    var credentialReferences: [CredentialReference] {
        switch self {
        case .none: []
        case let .bearer(reference): [reference]
        case let .basic(_, reference): [reference]
        case let .apiKey(_, reference): [reference]
        }
    }
}
