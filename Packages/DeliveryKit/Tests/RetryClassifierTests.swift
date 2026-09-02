import XCTest
@testable import DeliveryKit

final class RetryClassifierTests: XCTestCase {
    private let policy = RetryPolicy(
        maximumAttempts: 3,
        initialDelaySeconds: 10,
        maximumDelaySeconds: 60
    )
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testSuccessIsDelivered() {
        let response = HTTPResponse(statusCode: 204, headers: [:], bodyPreview: "")
        XCTAssertEqual(
            RetryClassifier().classify(response: response, attempt: 1, policy: policy, now: now),
            .delivered(statusCode: 204)
        )
    }

    func testAuthenticationFailurePauses() {
        let response = HTTPResponse(statusCode: 401, headers: [:], bodyPreview: "")
        XCTAssertEqual(
            RetryClassifier().classify(response: response, attempt: 1, policy: policy, now: now),
            .pausedAuthentication(statusCode: 401)
        )
    }

    func testRetryAfterTakesPriority() {
        let response = HTTPResponse(statusCode: 429, headers: ["retry-after": "45"], bodyPreview: "")
        XCTAssertEqual(
            RetryClassifier().classify(
                response: response,
                attempt: 1,
                policy: policy,
                now: now,
                jitterUnit: 0
            ),
            .retry(at: now.addingTimeInterval(45), reason: "HTTP 429")
        )
    }

    func testRetryLimitPreservesPermanentFailureState() {
        let response = HTTPResponse(statusCode: 500, headers: [:], bodyPreview: "private response")
        XCTAssertEqual(
            RetryClassifier().classify(response: response, attempt: 3, policy: policy, now: now),
            .permanentFailure(statusCode: 500, reason: "Retry limit reached")
        )
    }

    func testMissingCredentialPausesWithoutRetrying() {
        XCTAssertEqual(
            RetryClassifier().classify(
                error: RequestFactoryError.missingCredential,
                attempt: 1,
                policy: policy,
                now: now
            ),
            .pausedAuthentication(statusCode: nil)
        )
    }
}
