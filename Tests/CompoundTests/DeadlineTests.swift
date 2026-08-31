import Foundation
import FoundationModels
import Testing
@testable import Compound

@Suite("Deadline")
struct DeadlineTests {
    @Test("fast operation wins and returns its value")
    func fastOperationWins() async throws {
        let value = try await withDeadline(.seconds(10)) { 42 }
        #expect(value == 42)
    }

    @Test("hung operation times out with DeadlineExceededError")
    func hungOperationTimesOut() async throws {
        let clock = ContinuousClock()
        let started = clock.now
        await #expect(throws: DeadlineExceededError(duration: .milliseconds(50))) {
            try await withDeadline(.milliseconds(50)) { () -> String in
                try await Task.sleep(for: .seconds(60))
                return "never"
            }
        }
        // The call must return on the deadline, not wait out the sleep.
        #expect(clock.now - started < .seconds(30))
    }

    @Test("onTimeout can substitute a fallback value")
    func onTimeoutFallbackValue() async throws {
        let value = try await withDeadline(.milliseconds(20), onTimeout: { -1 }) { () -> Int in
            try await Task.sleep(for: .seconds(60))
            return 0
        }
        #expect(value == -1)
    }

    @Test("operation error propagates before the deadline")
    func operationErrorPropagates() async throws {
        struct Boom: Error, Equatable {}
        await #expect(throws: Boom()) {
            try await withDeadline(.seconds(10)) { () -> Int in
                throw Boom()
            }
        }
    }

    @Test("cancelling the calling task propagates into the operation")
    func externalCancellationPropagates() async throws {
        let task = Task { () -> Int in
            try await withDeadline(.seconds(60)) { () -> Int in
                try await Task.sleep(for: .seconds(60))
                return 1
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected cancellation to propagate")
        } catch is CancellationError {
            // Expected: the caller was cancelled, not timed out.
        } catch is DeadlineExceededError {
            Issue.record("cancellation surfaced as a deadline expiry")
        }
    }

    @Test("losing operation is cancelled when the deadline fires")
    func losingOperationIsCancelled() async throws {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        _ = try? await withDeadline(.milliseconds(20)) { () -> Int in
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                continuation.yield()
                continuation.finish()
                throw error
            }
            return 0
        }
        var iterator = stream.makeAsyncIterator()
        let observedCancellation: Void? = await iterator.next()
        #expect(observedCancellation != nil)
    }
}

// Hangs in respond() until cancelled. Used to prove the control loop's
// wall-clock deadline cuts off an in-flight model call instead of waiting
// for it to return.
actor HungRespondModel: ModelResponding {
    func respond(to _: String, options _: GenerationOptions) async throws -> String {
        try await Task.sleep(for: .seconds(60))
        return "never"
    }
    func respondGenerating<T: Generable & Sendable>(
        _ type: T.Type,
        to prompt: String,
        options: GenerationOptions
    ) async throws -> T {
        fatalError("unused in tests")
    }
}

@Suite("LoopDeadline")
struct LoopDeadlineTests {
    @Test("hung respond() trips the wall-clock budget at the cap")
    func hungRespondTripsWallClock() async throws {
        let model = HungRespondModel()
        let budget = Budget(maxTurns: 3, wallClock: .milliseconds(250))
        let loop = ControlLoop(budget: budget, outputVerifier: .empty())
        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await loop.run(prompt: "p", modelClient: model, runContext: RunContext())
            Issue.record("expected budgetExhausted(.wallClock)")
        } catch CompoundError.budgetExhausted(let kind, _) {
            #expect(kind == .wallClock)
        }
        // Must return at the cap (with generous scheduling slop), never
        // after the model's 60s hang.
        #expect(clock.now - start < .seconds(20))
    }
}
