import Foundation

/// Exponential-backoff retry policy with jitter. Designed for transient
/// failures around the model invocation and the network-facing edges of
/// tools (rate limits, model availability hiccups). Verifier-level repair
/// is a separate concern handled by the control loop — retries here are
/// for the underlying call, not for output correctness.
public struct RetryPolicy: Sendable, Equatable {
    /// Maximum total attempts (including the first).
    public let maxAttempts: Int
    /// Delay before the second attempt.
    public let initialDelay: Duration
    /// Multiplier applied to ``initialDelay`` each subsequent attempt.
    public let multiplier: Double
    /// Hard ceiling on the per-attempt delay before jitter is added.
    public let maxDelay: Duration
    /// Random jitter fraction in `0.0 ... 1.0`. The delay is perturbed by
    /// `±jitter * delay`.
    public let jitter: Double  // 0.0 ... 1.0 — fraction of computed delay

    /// Creates a policy. Inputs are precondition-checked.
    public init(
        maxAttempts: Int = 3,
        initialDelay: Duration = .milliseconds(200),
        multiplier: Double = 2.0,
        maxDelay: Duration = .seconds(5),
        jitter: Double = 0.25
    ) {
        precondition(maxAttempts >= 1, "maxAttempts must be at least 1")
        precondition(multiplier >= 1.0, "multiplier must be >= 1")
        precondition((0...1).contains(jitter), "jitter must be 0...1")
        self.maxAttempts = maxAttempts
        self.initialDelay = initialDelay
        self.multiplier = multiplier
        self.maxDelay = maxDelay
        self.jitter = jitter
    }

    /// No retries: the call runs once.
    public static let none = RetryPolicy(maxAttempts: 1)
    /// Sensible default for model and tool calls.
    public static let `default` = RetryPolicy()
    /// More retries with a shorter initial delay and a longer ceiling.
    public static let aggressive = RetryPolicy(maxAttempts: 5, initialDelay: .milliseconds(100), maxDelay: .seconds(10))

    /// Computes the delay before the given (1-based) attempt number.
    ///
    /// - Parameter attempt: 1-based attempt number. `delay(attempt: 1)` is
    ///   the delay *before* the second attempt, so callers typically pass
    ///   the prior attempt index.
    /// - Returns: The jittered, capped backoff duration.
    public func delay(attempt: Int) -> Duration {
        let base = pow(multiplier, Double(attempt - 1)) * initialDelay.seconds
        let capped = min(base, maxDelay.seconds)
        let j = jitter > 0 ? Double.random(in: -jitter...jitter) * capped : 0
        return .seconds(max(0, capped + j))
    }
}

/// Classifies an error as either a transient failure worth retrying or a
/// terminal failure that should surface immediately.
public protocol RetryClassifier: Sendable {
    /// Returns `true` if `error` is worth a retry.
    func isTransient(_ error: any Error) -> Bool
}

/// Default classifier. Treats common `URLError` connectivity hiccups and
/// ``CompoundError/modelUnavailable(reason:)`` as transient; everything
/// else is terminal. Callers can extend this by composing with a
/// domain-specific classifier through ``UnionRetryClassifier``.
public struct DefaultRetryClassifier: RetryClassifier {
    /// Creates an instance.
    public init() {}
    /// Returns `true` for URL/transport hiccups and model-unavailable
    /// errors.
    public func isTransient(_ error: any Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotConnectToHost, .networkConnectionLost,
                 .notConnectedToInternet, .dnsLookupFailed, .resourceUnavailable,
                 .internationalRoamingOff, .callIsActive, .dataNotAllowed:
                return true
            default:
                return false
            }
        }
        if let compoundError = error as? CompoundError, case .modelUnavailable = compoundError {
            return true
        }
        return false
    }
}

/// Composes multiple classifiers; an error is transient if any member
/// claims it.
public struct UnionRetryClassifier: RetryClassifier {
    /// Member classifiers, evaluated in order.
    public let classifiers: [any RetryClassifier]
    /// Creates a union classifier from the supplied members.
    public init(_ classifiers: [any RetryClassifier]) { self.classifiers = classifiers }
    /// Returns `true` if any member classifies `error` as transient.
    public func isTransient(_ error: any Error) -> Bool {
        classifiers.contains { $0.isTransient(error) }
    }
}

/// Namespace for retry helpers. Use ``Retry/with(policy:classifier:body:)``
/// to wrap any retryable async operation.
public enum Retry {
    /// Runs `body`, retrying transient failures up to `policy.maxAttempts`.
    /// Honors task cancellation between attempts.
    ///
    /// - Parameters:
    ///   - policy: Attempt count and backoff schedule.
    ///   - classifier: Decides whether a thrown error is transient.
    ///   - body: The work to retry.
    /// - Returns: The body's result on first success.
    /// - Throws: The last error from `body` once retries are exhausted or
    ///   the error is classified as terminal, or `CancellationError`.
    public static func with<T: Sendable>(
        policy: RetryPolicy,
        classifier: any RetryClassifier = DefaultRetryClassifier(),
        body: @Sendable () async throws -> T
    ) async throws -> T {
        var attempt = 1
        while true {
            try Task.checkCancellation()
            do {
                return try await body()
            } catch {
                if attempt >= policy.maxAttempts || !classifier.isTransient(error) {
                    throw error
                }
                let delay = policy.delay(attempt: attempt)
                try await Task.sleep(for: delay)
                attempt += 1
            }
        }
    }
}

// Duration → Double convenience. The reverse (Double → Duration) is
// already provided by the standard library as `Duration.seconds(_:)`.
internal extension Duration {
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
