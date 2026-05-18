import Foundation
import FoundationModels
import Testing
@testable import Compound

// SlowFakeModel sleeps for `delay` on every respond() call so the test has
// time to send a cancel signal.
actor SlowFakeModel: ModelResponding {
    let delay: Duration
    init(delay: Duration) { self.delay = delay }
    func respond(to _: String, options _: GenerationOptions) async throws -> String {
        try await Task.sleep(for: delay)
        return "ok"
    }
    func respondGenerating<T: Generable & Sendable>(
        _: T.Type,
        to _: String,
        options _: GenerationOptions
    ) async throws -> T {
        fatalError("unused")
    }
}

struct SlowStreamingFakeModel: ModelStreaming {
    let delay: Duration
    func stream(to _: String, options _: GenerationOptions) async -> ModelStreamResult {
        let (stream, cont) = AsyncThrowingStream<String, Error>.makeStream()
        let d = delay
        let final = Task<String, Error> {
            try await Task.sleep(for: d)
            try Task.checkCancellation()
            cont.yield("done")
            cont.finish()
            return "done"
        }
        return ModelStreamResult(stream: stream, final: final)
    }
}

@Suite("Cancellation")
struct CancellationTests {
    @Test("Task.cancel on ControlLoop.run propagates")
    func controlLoopCancelPropagates() async throws {
        let model = SlowFakeModel(delay: .seconds(5))
        let tracer = InMemoryTracer()
        let chain = VerifierChain<String>(name: "out", [
            AnyVerifier<String>(name: "p", cost: .parse) { _, _ in .pass }
        ])
        let loop = ControlLoop(budget: .default, outputVerifier: chain)
        let task = Task<LoopOutcome, Error> {
            try await loop.run(prompt: "p", modelClient: model, runContext: RunContext(tracer: tracer))
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        var thrownAsCancellation = false
        do {
            _ = try await task.value
        } catch is CancellationError {
            thrownAsCancellation = true
        } catch let e as CompoundError {
            if case .cancelled = e { thrownAsCancellation = true }
            if case .underlying(let inner) = e, inner is CancellationError {
                thrownAsCancellation = true
            }
        } catch {
            // anything else
        }
        #expect(thrownAsCancellation)
        let events = await tracer.snapshot()
        let sawFailedEnd = events.contains { ev in
            if case .runEnded(_, let success, _) = ev { return success == false }
            return false
        }
        #expect(sawFailedEnd)
    }

    @Test("streaming cancel: stream terminates, final task throws")
    func streamingCancelPropagates() async throws {
        let model = SlowStreamingFakeModel(delay: .seconds(5))
        let chain = VerifierChain<String>(name: "out", [
            AnyVerifier<String>(name: "p", cost: .parse) { _, _ in .pass }
        ])
        let loop = StreamingControlLoop(budget: .default, outputVerifier: chain)
        let run = loop.run(prompt: "p", modelClient: model, runContext: RunContext())
        try await Task.sleep(for: .milliseconds(20))
        run.outcome.cancel()
        var outcomeErrored = false
        do {
            _ = try await run.outcome.value
        } catch {
            outcomeErrored = true
        }
        #expect(outcomeErrored)
    }

    @Test("Retry honors mid-sleep cancellation")
    func retryHonorsMidSleepCancellation() async throws {
        struct Transient: Error {}
        actor Counter { var n = 0; func bump() -> Int { n += 1; return n } }
        let counter = Counter()
        struct AllTransient: RetryClassifier {
            func isTransient(_: any Error) -> Bool { true }
        }
        let task = Task<Void, Error> {
            _ = try await Retry.with(
                policy: RetryPolicy(maxAttempts: 100, initialDelay: .milliseconds(50)),
                classifier: AllTransient()
            ) {
                _ = await counter.bump()
                throw Transient()
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        var sawCancel = false
        do {
            _ = try await task.value
        } catch is CancellationError {
            sawCancel = true
        } catch {
            // some other; still considered cancellation if body stopped early
        }
        #expect(sawCancel)
        let calls = await counter.n
        #expect(calls < 100, "body should not exhaust all attempts; got \(calls)")
    }
}
