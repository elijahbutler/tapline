import Foundation

public struct HTTPResponse: Sendable, Equatable {
    public let statusCode: Int
    public let headers: [String: String]
    public let bodyPreview: String

    public init(statusCode: Int, headers: [String: String], bodyPreview: String) {
        self.statusCode = statusCode
        self.headers = headers
        self.bodyPreview = bodyPreview
    }
}

public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest, networkPolicy: NetworkPolicy) async throws -> HTTPResponse
}

public struct URLSessionHTTPClient: HTTPClient {
    public init() {}

    public func send(_ request: URLRequest, networkPolicy: NetworkPolicy) async throws -> HTTPResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.allowsCellularAccess = networkPolicy == .anyNetwork
        configuration.allowsExpensiveNetworkAccess = networkPolicy == .anyNetwork
        configuration.allowsConstrainedNetworkAccess = true

        let delegate = RejectingRedirectDelegate()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw HTTPClientError.invalidResponse
        }

        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, item in
            guard let key = item.key as? String else { return }
            result[key.lowercased()] = String(describing: item.value)
        }
        let previewData = data.prefix(512)
        let preview = String(data: previewData, encoding: .utf8) ?? "<\(data.count) bytes>"

        return HTTPResponse(statusCode: response.statusCode, headers: headers, bodyPreview: preview)
    }
}

private final class RejectingRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

public enum HTTPClientError: Error, Equatable, Sendable {
    case invalidResponse
}
