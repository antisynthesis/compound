import Foundation
import Testing
@testable import Compound

@Suite("Retry")
struct RetryTests {
    @Test("retry returns immediately on success")
    func returnsImmediatelyOnSuccess() async throws {
        actor Counter { var n = 0; func bump() { n += 1 } }
        let counter = Counter()
        let result: Int = try await Retry.with(policy: .default) {
            await counter.bump()
            return 42
        }
        #expect(result == 42)
        let calls = await counter.n
        #expect(calls == 1)
    }

    @Test("retry retries transient errors and eventually succeeds")
    func retriesAndSucceeds() async throws {
        struct Transient: Error {}
        actor Counter { var n = 0; func bump() -> Int { n += 1; return n } }
        let counter = Counter()
        struct AllTransient: RetryClassifier {
            func isTransient(_: any Error) -> Bool { true }
        }
        let result: String = try await Retry.with(
            policy: RetryPolicy(maxAttempts: 5, initialDelay: .milliseconds(1)),
            classifier: AllTransient()
        ) {
            let attempt = await counter.bump()
            if attempt < 3 { throw Transient() }
            return "done"
        }
        #expect(result == "done")
        let calls = await counter.n
        #expect(calls == 3)
    }

    @Test("retry stops at maxAttempts")
    func stopsAtMaxAttempts() async throws {
        struct Boom: Error {}
        actor Counter { var n = 0; func bump() { n += 1 } }
        let counter = Counter()
        struct AllTransient: RetryClassifier {
            func isTransient(_: any Error) -> Bool { true }
        }
        do {
            _ = try await Retry.with(
                policy: RetryPolicy(maxAttempts: 2, initialDelay: .milliseconds(1)),
                classifier: AllTransient()
            ) {
                await counter.bump()
                throw Boom()
            }
            Issue.record("expected throw")
        } catch {
            let calls = await counter.n
            #expect(calls == 2)
        }
    }

    @Test("retry does not retry non-transient errors")
    func doesNotRetryNonTransient() async throws {
        struct Permanent: Error {}
        actor Counter { var n = 0; func bump() { n += 1 } }
        let counter = Counter()
        struct NoneTransient: RetryClassifier {
            func isTransient(_: any Error) -> Bool { false }
        }
        do {
            _ = try await Retry.with(
                policy: RetryPolicy(maxAttempts: 5, initialDelay: .milliseconds(1)),
                classifier: NoneTransient()
            ) {
                await counter.bump()
                throw Permanent()
            }
            Issue.record("expected throw")
        } catch {
            let calls = await counter.n
            #expect(calls == 1)
        }
    }

    @Test("DefaultRetryClassifier unwraps .underlying to find a transient URLError")
    func classifierUnwrapsUnderlying() {
        let classifier = DefaultRetryClassifier()
        let transient = URLError(.timedOut)
        #expect(classifier.isTransient(transient))
        #expect(classifier.isTransient(CompoundError.underlying(transient)))
        // Nested wrapping is unwrapped recursively.
        #expect(classifier.isTransient(CompoundError.underlying(CompoundError.underlying(transient))))
        // A terminal URLError stays terminal through the wrapper.
        #expect(!classifier.isTransient(CompoundError.underlying(URLError(.badURL))))
    }

    @Test("DefaultRetryClassifier treats .modelRateLimited as transient and terminal model errors as terminal")
    func classifierModelErrorClasses() {
        let classifier = DefaultRetryClassifier()
        #expect(classifier.isTransient(CompoundError.modelRateLimited))
        #expect(classifier.isTransient(CompoundError.underlying(CompoundError.modelRateLimited)))
        #expect(!classifier.isTransient(CompoundError.guardrailViolation(context: "blocked")))
        #expect(!classifier.isTransient(CompoundError.refusal(nil)))
        #expect(!classifier.isTransient(CompoundError.unsupportedLanguage))
        #expect(!classifier.isTransient(CompoundError.contextWindowExceeded(promptTokens: nil)))
        #expect(!classifier.isTransient(CancellationError()))
    }

    @Test("DefaultRetryClassifier splits modelUnavailable by reason")
    func classifierSplitsModelUnavailable() {
        let classifier = DefaultRetryClassifier()
        // modelNotReady is worth a retry — the model is still downloading.
        #expect(classifier.isTransient(
            CompoundError.modelUnavailable(reason: "model not ready (still downloading)")
        ))
        #expect(classifier.isTransient(
            CompoundError.modelUnavailable(reason: "model assets unavailable — fetching")
        ))
        // deviceNotEligible / Apple Intelligence disabled never resolve by retrying.
        #expect(!classifier.isTransient(
            CompoundError.modelUnavailable(reason: "device not eligible for Apple Intelligence")
        ))
        #expect(!classifier.isTransient(
            CompoundError.modelUnavailable(reason: "Apple Intelligence not enabled")
        ))
        #expect(!classifier.isTransient(
            CompoundError.modelUnavailable(reason: "unavailable (unknown reason)")
        ))
    }

    @Test("retry honors cancellation between attempts")
    func honorsCancellation() async throws {
        actor Counter { var n = 0; func bump() -> Int { n += 1; return n } }
        let counter = Counter()
        struct AllTransient: RetryClassifier {
            func isTransient(_: any Error) -> Bool { true }
        }
        struct Transient: Error {}
        let task = Task<Void, Error> {
            _ = try await Retry.with(
                policy: RetryPolicy(maxAttempts: 10, initialDelay: .milliseconds(50)),
                classifier: AllTransient()
            ) {
                _ = await counter.bump()
                throw Transient()
            }
        }
        try await Task.sleep(for: .milliseconds(10))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected throw")
        } catch is CancellationError {
            let calls = await counter.n
            #expect(calls < 10, "body should not run all attempts after cancel; got \(calls)")
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }
    }
}
