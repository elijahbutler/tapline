import Foundation

public enum DeliveryDisposition: Equatable, Sendable {
    case delivered(statusCode: Int)
    case retry(at: Date, reason: String)
    case pausedAuthentication(statusCode: Int?)
    case permanentFailure(statusCode: Int, reason: String)
}

public struct RetryClassifier: Sendable {
    public init() {}

    public func classify(
        response: HTTPResponse,
        attempt: Int,
        policy: RetryPolicy,
        now: Date = Date(),
        jitterUnit: Double = Double.random(in: 0 ... 1)
    ) -> DeliveryDisposition {
        switch response.statusCode {
        case 200 ... 299:
            return .delivered(statusCode: response.statusCode)
        case 401, 403:
            return .pausedAuthentication(statusCode: response.statusCode)
        case 408, 429, 500 ... 599:
            return retryDisposition(
                statusCode: response.statusCode,
                retryAfter: response.headers["retry-after"],
                attempt: attempt,
                policy: policy,
                now: now,
                jitterUnit: jitterUnit
            )
        default:
            return .permanentFailure(
                statusCode: response.statusCode,
                reason: "HTTP \(response.statusCode)"
            )
        }
    }

    public func classify(
        error: Error,
        attempt: Int,
        policy: RetryPolicy,
        now: Date = Date(),
        jitterUnit: Double = Double.random(in: 0 ... 1)
    ) -> DeliveryDisposition {
        if error is RequestFactoryError {
            return .pausedAuthentication(statusCode: nil)
        }
        guard attempt < policy.maximumAttempts else {
            return .permanentFailure(statusCode: 0, reason: String(describing: error))
        }
        return .retry(
            at: now.addingTimeInterval(backoff(attempt: attempt, policy: policy, jitterUnit: jitterUnit)),
            reason: String(describing: error)
        )
    }

    private func retryDisposition(
        statusCode: Int,
        retryAfter: String?,
        attempt: Int,
        policy: RetryPolicy,
        now: Date,
        jitterUnit: Double
    ) -> DeliveryDisposition {
        guard attempt < policy.maximumAttempts else {
            return .permanentFailure(statusCode: statusCode, reason: "Retry limit reached")
        }

        let maximumRetryDate = now.addingTimeInterval(policy.maximumDelaySeconds)
        let requestedRetryDate = retryAfter.flatMap { parseRetryAfter($0, now: now) }
        let retryDate = requestedRetryDate
            .map { min(max($0, now), maximumRetryDate) }
            ?? now.addingTimeInterval(backoff(attempt: attempt, policy: policy, jitterUnit: jitterUnit))
        return .retry(at: retryDate, reason: "HTTP \(statusCode)")
    }

    private func backoff(attempt: Int, policy: RetryPolicy, jitterUnit: Double) -> TimeInterval {
        let exponent = min(max(attempt - 1, 0), 30)
        let ceiling = min(
            policy.maximumDelaySeconds,
            policy.initialDelaySeconds * pow(2, Double(exponent))
        )
        return ceiling * min(max(jitterUnit, 0), 1)
    }

    private func parseRetryAfter(_ value: String, now: Date) -> Date? {
        if let seconds = TimeInterval(value.trimmingCharacters(in: .whitespacesAndNewlines)), seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter.date(from: value)
    }
}
