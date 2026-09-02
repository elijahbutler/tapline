import CaptureCore
import EndpointSecurity
import Foundation

public enum HTTPMethod: String, Codable, CaseIterable, Hashable, Sendable {
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
}

public enum TLSRequirement: String, Codable, CaseIterable, Hashable, Sendable {
    case requireHTTPS = "require_https"
    case allowHTTPForLocalHost = "allow_http_for_local_host"
}

public enum NetworkPolicy: String, Codable, CaseIterable, Hashable, Sendable {
    case localNetworkOnly = "local_network_only"
    case wifiOnly = "wifi_only"
    case anyNetwork = "any_network"
}

public struct Endpoint: Codable, Hashable, Sendable {
    public var scheme: String
    public var host: String
    public var port: Int?
    public var path: String

    public init(scheme: String, host: String, port: Int? = nil, path: String = "/capture") {
        self.scheme = scheme
        self.host = host
        self.port = port
        self.path = path
    }

    public func url(tlsRequirement: TLSRequirement, networkPolicy: NetworkPolicy) throws -> URL {
        let normalizedScheme = scheme.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)

        guard normalizedScheme == "https" || normalizedScheme == "http" else {
            throw DestinationValidationError.unsupportedScheme
        }
        guard !normalizedHost.isEmpty else {
            throw DestinationValidationError.missingHost
        }
        if let port, !(1 ... 65_535).contains(port) {
            throw DestinationValidationError.invalidPort
        }

        let localHost = Self.isLocalHost(normalizedHost)
        if normalizedScheme == "http" {
            guard tlsRequirement == .allowHTTPForLocalHost, localHost else {
                throw DestinationValidationError.insecureRemoteEndpoint
            }
        }
        if networkPolicy == .localNetworkOnly, !localHost {
            throw DestinationValidationError.endpointIsNotLocal
        }

        var components = URLComponents()
        components.scheme = normalizedScheme
        components.host = normalizedHost
        components.port = port
        components.path = path.hasPrefix("/") ? path : "/\(path)"

        guard let url = components.url else {
            throw DestinationValidationError.invalidURL
        }
        return url
    }

    public static func isLocalHost(_ host: String) -> Bool {
        let value = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if value == "localhost" || value.hasSuffix(".local") {
            return true
        }
        if value.contains(":") {
            return value == "::1"
                || value.hasPrefix("fe80:")
                || value.hasPrefix("fc")
                || value.hasPrefix("fd")
        }

        let rawParts = value.split(separator: ".", omittingEmptySubsequences: false)
        let parts = rawParts.compactMap { Int($0) }
        guard parts.count == 4,
              parts.allSatisfy({ (0 ... 255).contains($0) }),
              zip(rawParts, parts).allSatisfy({ raw, parsed in String(parsed) == raw })
        else {
            return false
        }

        switch (parts[0], parts[1]) {
        case (10, _), (127, _), (192, 168), (169, 254):
            return true
        case (172, 16 ... 31):
            return true
        default:
            return false
        }
    }
}

public struct HeaderTemplate: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var value: String

    public init(id: UUID = UUID(), name: String, value: String) {
        self.id = id
        self.name = name
        self.value = value
    }
}

public enum DestinationAuthentication: Codable, Hashable, Sendable {
    case none
    case bearer(token: CredentialReference)
    case basic(username: String, password: CredentialReference)
    case apiKey(header: String, value: CredentialReference)
}

public struct EventFilter: Codable, Hashable, Sendable {
    public var includedTypes: Set<EventType>

    public init(includedTypes: Set<EventType> = []) {
        self.includedTypes = includedTypes
    }

    public func matches(_ event: CaptureEvent) -> Bool {
        includedTypes.isEmpty || includedTypes.contains(event.type)
    }
}

public enum PayloadTemplate: String, Codable, CaseIterable, Hashable, Sendable {
    case eventJSON = "event_json_v1"
}

public struct RetryPolicy: Codable, Hashable, Sendable {
    public var maximumAttempts: Int
    public var initialDelaySeconds: TimeInterval
    public var maximumDelaySeconds: TimeInterval

    public init(
        maximumAttempts: Int = 10,
        initialDelaySeconds: TimeInterval = 5,
        maximumDelaySeconds: TimeInterval = 3_600
    ) {
        self.maximumAttempts = maximumAttempts
        self.initialDelaySeconds = initialDelaySeconds
        self.maximumDelaySeconds = maximumDelaySeconds
    }

    public static let standard = RetryPolicy()
}

public struct Destination: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var enabled: Bool
    public var endpoint: Endpoint
    public var method: HTTPMethod
    public var headers: [HeaderTemplate]
    public var authentication: DestinationAuthentication
    public var tlsRequirement: TLSRequirement
    public var filter: EventFilter
    public var payloadTemplate: PayloadTemplate
    public var retryPolicy: RetryPolicy
    public var networkPolicy: NetworkPolicy

    public init(
        id: UUID = UUID(),
        name: String,
        enabled: Bool = true,
        endpoint: Endpoint,
        method: HTTPMethod = .post,
        headers: [HeaderTemplate] = [],
        authentication: DestinationAuthentication = .none,
        tlsRequirement: TLSRequirement = .requireHTTPS,
        filter: EventFilter = EventFilter(),
        payloadTemplate: PayloadTemplate = .eventJSON,
        retryPolicy: RetryPolicy = .standard,
        networkPolicy: NetworkPolicy = .localNetworkOnly
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.endpoint = endpoint
        self.method = method
        self.headers = headers
        self.authentication = authentication
        self.tlsRequirement = tlsRequirement
        self.filter = filter
        self.payloadTemplate = payloadTemplate
        self.retryPolicy = retryPolicy
        self.networkPolicy = networkPolicy
    }

    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DestinationValidationError.missingName
        }
        _ = try endpoint.url(tlsRequirement: tlsRequirement, networkPolicy: networkPolicy)
        guard retryPolicy.maximumAttempts >= 1,
              retryPolicy.initialDelaySeconds >= 1,
              retryPolicy.maximumDelaySeconds >= retryPolicy.initialDelaySeconds
        else {
            throw DestinationValidationError.invalidRetryPolicy
        }
        try headers.forEach(HeaderValidator.validate)
        if case let .apiKey(header, _) = authentication {
            try HeaderValidator.validate(HeaderTemplate(name: header, value: "credential"))
        }
    }
}

public enum DestinationValidationError: Error, Equatable, Sendable, LocalizedError {
    case missingName
    case missingHost
    case unsupportedScheme
    case invalidPort
    case invalidURL
    case insecureRemoteEndpoint
    case endpointIsNotLocal
    case invalidRetryPolicy
    case invalidHeaderName(String)
    case reservedHeader(String)
    case invalidHeaderValue(String)

    public var errorDescription: String? {
        switch self {
        case .missingName: "Enter a destination name."
        case .missingHost: "Enter a hostname or IP address."
        case .unsupportedScheme: "Use HTTP or HTTPS."
        case .invalidPort: "Enter a port between 1 and 65535."
        case .invalidURL: "The endpoint URL is invalid."
        case .insecureRemoteEndpoint: "Plain HTTP is allowed only for local hosts."
        case .endpointIsNotLocal: "This destination is not a local network address."
        case .invalidRetryPolicy: "The retry settings are invalid."
        case let .invalidHeaderName(name): "The header name \"\(name)\" is invalid."
        case let .reservedHeader(name): "Tapline manages the \"\(name)\" header."
        case let .invalidHeaderValue(name): "The value for \"\(name)\" contains a line break."
        }
    }
}

enum HeaderValidator {
    private static let reserved = Set([
        "authorization",
        "connection",
        "content-length",
        "content-type",
        "cookie",
        "host",
        "idempotency-key",
        "proxy-authorization",
        "transfer-encoding",
    ])

    static func validate(_ header: HeaderTemplate) throws {
        let name = header.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokenCharacters = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        guard !name.isEmpty, name.unicodeScalars.allSatisfy(tokenCharacters.contains) else {
            throw DestinationValidationError.invalidHeaderName(header.name)
        }
        guard !reserved.contains(name.lowercased()) else {
            throw DestinationValidationError.reservedHeader(name)
        }
        guard !header.value.contains("\r"), !header.value.contains("\n") else {
            throw DestinationValidationError.invalidHeaderValue(name)
        }
    }
}
