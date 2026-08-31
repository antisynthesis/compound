import Foundation
import FoundationModels
import Testing
@testable import Compound

// FakeStreamingModel yields a fixed sequence of chunks across one or more
// turns. The final task resolves to the concatenated chunk content.
struct FakeStreamingModel: ModelStreaming {
    let chunksPerTurn: [[String]]
    let perChunkDelay: Duration

    init(chunks: [String], perChunkDelay: Duration = .milliseconds(0)) {
        self.chunksPerTurn = [chunks]
        self.perChunkDelay = perChunkDelay
    }

    init(turns: [[String]], perChunkDelay: Duration = .milliseconds(0)) {
        self.chunksPerTurn = turns
        self.perChunkDelay = perChunkDelay
    }

    func stream(to prompt: String, options _: GenerationOptions) async -> ModelStreamResult {
        let chunks = chunksPerTurn.first ?? []
        let (stream, cont) = AsyncThrowingStream<String, Error>.makeStream()
        let final = Task<String, Error> {
            var acc = ""
            for chunk in chunks {
                if perChunkDelay > .zero {
                    try await Task.sleep(for: perChunkDelay)
                }
                try Task.checkCancellation()
                cont.yield(chunk)
                acc += chunk
            }
            cont.finish()
            return acc
        }
        return ModelStreamResult(stream: stream, final: final)
    }
}

// FakeThrowingStreamingModel throws after `throwAfter` chunks on the third or
// configured chunk.
struct FakeThrowingStreamingModel: ModelStreaming {
    struct E: Error {}
    let chunks: [String]
    let throwAfter: Int

    func stream(to _: String, options _: GenerationOptions) async -> ModelStreamResult {
        let (stream, cont) = AsyncThrowingStream<String, Error>.makeStream()
        let count = throwAfter
        let all = chunks
        let final = Task<String, Error> {
            var acc = ""
            for (i, chunk) in all.enumerated() {
                if i >= count {
                    let err = E()
                    cont.finish(throwing: err)
                    throw err
                }
                cont.yield(chunk)
                acc += chunk
            }
            cont.finish()
            return acc
        }
        return ModelStreamResult(stream: stream, final: final)
    }
}

// Streams a fixed-size payload chunk-by-chunk so the loop sees token-budget
// pressure mid-stream.
struct LargePayloadStreamingModel: ModelStreaming {
    let totalChunks: Int
    let chunkSize: Int

    func stream(to _: String, options _: GenerationOptions) async -> ModelStreamResult {
        let (stream, cont) = AsyncThrowingStream<String, Error>.makeStream()
        let n = totalChunks
        let size = chunkSize
        let final = Task<String, Error> {
            var acc = ""
            for _ in 0..<n {
                try Task.checkCancellation()
                let chunk = String(repeating: "x", count: size)
                cont.yield(chunk)
                acc += chunk
            }
            cont.finish()
            return acc
        }
        return ModelStreamResult(stream: stream, final: final)
    }
}

// Yields a different turn's chunks on each stream() call so repair paths can
// be exercised; the last turn repeats once the script is exhausted.
struct MultiTurnStreamingModel: ModelStreaming {
    let turns: [[String]]
    private let counter = TurnIndexCounter()

    func stream(to _: String, options _: GenerationOptions) async -> ModelStreamResult {
        let idx = await counter.next()
        let chunks = turns[min(idx, turns.count - 1)]
        let (stream, cont) = AsyncThrowingStream<String, Error>.makeStream()
        let final = Task<String, Error> {
            var acc = ""
            for chunk in chunks {
                cont.yield(chunk)
                acc += chunk
            }
            cont.finish()
            return acc
        }
        return ModelStreamResult(stream: stream, final: final)
    }
}

actor TurnIndexCounter {
    private var i = 0
    func next() -> Int {
        defer { i += 1 }
        return i
    }
}

// Yields its chunks immediately, then stalls (cancellably) forever without
// finishing the stream or resolving the final task.
struct StallingStreamingModel: ModelStreaming {
    let chunks: [String]

    func stream(to _: String, options _: GenerationOptions) async -> ModelStreamResult {
        let (stream, cont) = AsyncThrowingStream<String, Error>.makeStream()
        let all = chunks
        let final = Task<String, Error> {
            var acc = ""
            for chunk in all {
                cont.yield(chunk)
                acc += chunk
            }
            try await Task.sleep(for: .seconds(60))
            cont.finish()
            return acc
        }
        return ModelStreamResult(stream: stream, final: final)
    }
}

// Never yields a single chunk; stalls (cancellably) before the first token.
struct NeverYieldingStreamingModel: ModelStreaming {
    func stream(to _: String, options _: GenerationOptions) async -> ModelStreamResult {
        let (stream, cont) = AsyncThrowingStream<String, Error>.makeStream()
        let final = Task<String, Error> {
            try await Task.sleep(for: .seconds(60))
            cont.finish()
            return ""
        }
        return ModelStreamResult(stream: stream, final: final)
    }
}

// The chunk stream finishes normally but the final task never settles.
struct HungFinalStreamingModel: ModelStreaming {
    func stream(to _: String, options _: GenerationOptions) async -> ModelStreamResult {
        let (stream, cont) = AsyncThrowingStream<String, Error>.makeStream()
        cont.yield("done")
        cont.finish()
        let final = Task<String, Error> {
            try await Task.sleep(for: .seconds(60))
            return "done"
        }
        return ModelStreamResult(stream: stream, final: final)
    }
}

@Suite("StreamingControlLoop")
struct StreamingControlLoopTests {
    @Test("stream emits chunks in order and ends with runCompleted")
    func emitsChunksInOrder() async throws {
        let model = FakeStreamingModel(chunks: ["a", "b", "c"])
        let chain = VerifierChain<String>(name: "out", [
            AnyVerifier<String>(name: "p", cost: .parse) { _, _ in .pass }
        ])
        let loop = StreamingControlLoop(budget: .default, outputVerifier: chain)
        let run = loop.run(prompt: "p", modelClient: model, runContext: RunContext())
        var seenChunks: [String] = []
        var sawCompleted = false
        for try await ev in run.stream {
            switch ev {
            case .modelStreamChunk(_, let content):
                seenChunks.append(content)
            case .runCompleted(let success):
                sawCompleted = true
                #expect(success)
            default:
                break
            }
        }
        let outcome = try await run.outcome.value
        #expect(seenChunks == ["a", "b", "c"])
        #expect(sawCompleted)
        #expect(outcome.final == "abc")
    }

    @Test("bounded buffer policy drops oldest")
    func boundedBufferDropsOldest() async throws {
        // Yield many events; consume slowly. With a tight buffer, oldest are
        // dropped — what matters is that we don't crash and we do see the
        // final runCompleted event.
        let chunks = (0..<100).map { "x\($0)" }
        let model = FakeStreamingModel(chunks: chunks)
        let chain = VerifierChain<String>(name: "out", [
            AnyVerifier<String>(name: "p", cost: .parse) { _, _ in .pass }
        ])
        let loop = StreamingControlLoop(
            budget: .default,
            outputVerifier: chain,
            eventBufferLimit: 4
        )
        let run = loop.run(prompt: "p", modelClient: model, runContext: RunContext())
        var count = 0
        for try await _ in run.stream { count += 1 }
        _ = try await run.outcome.value
        // Bounded buffer must drop events under fast-producer / slow-consumer.
        // The exact count is timing-dependent (verifier and lifecycle events
        // emit alongside chunks), but it must be strictly less than the 100
        // chunks produced — otherwise no drops are happening.
        #expect(count < 100, "buffered stream should drop events under load, got \(count)")
    }

    @Test("mid-turn token-budget enforcement cancels final task")
    func midTurnTokenBudgetCancels() async throws {
        // 1000 1-byte chunks → ~250 tokens total. Cap at 10 tokens; the loop
        // should bail out long before the model would complete.
        let model = LargePayloadStreamingModel(totalChunks: 1000, chunkSize: 4)
        let chain = VerifierChain<String>(name: "out", [
            AnyVerifier<String>(name: "p", cost: .parse) { _, _ in .pass }
        ])
        let budget = Budget(
            maxTurns: 100,
            maxToolCalls: 100,
            maxRepairAttempts: 100,
            wallClock: .seconds(60),
            maxTotalOutputTokens: 10
        )
        let loop = StreamingControlLoop(budget: budget, outputVerifier: chain)
        let run = loop.run(prompt: "p", modelClient: model, runContext: RunContext())
        for try await _ in run.stream {}
        do {
            _ = try await run.outcome.value
            Issue.record("expected budgetExhausted(.outputTokens)")
        } catch CompoundError.budgetExhausted(let kind, let usage) {
            #expect(kind == .outputTokens)
            #expect(usage.outputTokens >= 10)
        }
    }

    @Test("streaming loop schedules a repair turn and the repaired output passes")
    func streamingRepairPath() async throws {
        let model = MultiTurnStreamingModel(turns: [["b", "ad"], ["go", "od"]])
        let chain = VerifierChain<String>(name: "out", [
            AnyVerifier<String>(name: "needs-good", cost: .parse) { input, _ in
                input == "good"
                    ? .pass
                    : .repair(Diagnostic(verifier: "needs-good", message: "want good"))
            }
        ])
        let loop = StreamingControlLoop(budget: .default, outputVerifier: chain)
        let run = loop.run(prompt: "p", modelClient: model, runContext: RunContext())
        var sawRepair = false
        var sawSuccess = false
        for try await ev in run.stream {
            switch ev {
            case .repairScheduled: sawRepair = true
            case .runCompleted(let success): sawSuccess = success
            default: break
            }
        }
        let outcome = try await run.outcome.value
        #expect(outcome.final == "good")
        #expect(outcome.usage.turns == 2)
        #expect(outcome.usage.repairAttempts == 1)
        #expect(sawRepair)
        #expect(sawSuccess)
    }

    @Test("streaming reject verdict carries the rejecting diagnostic")
    func streamingRejectVerdict() async throws {
        let model = FakeStreamingModel(chunks: ["nope"])
        let chain = VerifierChain<String>(name: "out", [
            AnyVerifier<String>(name: "gate", cost: .parse) { _, _ in
                .reject(Diagnostic(verifier: "gate", message: "not allowed"))
            }
        ])
        let loop = StreamingControlLoop(budget: .default, outputVerifier: chain)
        let run = loop.run(prompt: "p", modelClient: model, runContext: RunContext())
        var sawFailure = false
        for try await ev in run.stream {
            if case .runCompleted(let success) = ev { sawFailure = !success }
        }
        do {
            _ = try await run.outcome.value
            Issue.record("expected verifierRejected")
        } catch CompoundError.verifierRejected(let reason, let diag) {
            #expect(reason == "not allowed")
            #expect(diag?.message == "not allowed")
        }
        #expect(sawFailure)
    }

    @Test("terminating the event stream cancels the run")
    func streamTerminationCancelsRun() async throws {
        let chunks = (0..<200).map { "chunk\($0)" }
        let model = FakeStreamingModel(chunks: chunks, perChunkDelay: .milliseconds(5))
        let chain = VerifierChain<String>(name: "out", [
            AnyVerifier<String>(name: "p", cost: .parse) { _, _ in .pass }
        ])
        let loop = StreamingControlLoop(budget: .default, outputVerifier: chain)
        let run = loop.run(prompt: "p", modelClient: model, runContext: RunContext())
        // Consume a few events, then cancel the consumer: the stream
        // terminates, which must cancel the underlying run task.
        let consumer = Task {
            for try await _ in run.stream {}
        }
        try await Task.sleep(for: .milliseconds(30))
        consumer.cancel()
        do {
            _ = try await run.outcome.value
            Issue.record("expected the run to be cancelled when its stream terminated")
        } catch {
            // CancellationError (typical) or a wrapped cancellation — the
            // essential guarantee is that the run did not complete normally.
        }
    }

    @Test("chunk-stream error surfaces as runEnded(success:false)")
    func chunkStreamErrorPath() async throws {
        let model = FakeThrowingStreamingModel(chunks: ["a", "b", "c", "d"], throwAfter: 2)
        let chain = VerifierChain<String>(name: "out", [
            AnyVerifier<String>(name: "p", cost: .parse) { _, _ in .pass }
        ])
        let tracer = InMemoryTracer()
        let loop = StreamingControlLoop(budget: .default, outputVerifier: chain)
        let run = loop.run(prompt: "p", modelClient: model, runContext: RunContext(tracer: tracer))
        // Drain the stream — it should terminate with an error.
        var streamErrored = false
        do {
            for try await _ in run.stream {}
        } catch {
            streamErrored = true
        }
        var outcomeErrored = false
        do {
            _ = try await run.outcome.value
        } catch {
            outcomeErrored = true
        }
        #expect(streamErrored || outcomeErrored)
        let events = await tracer.snapshot()
        let hasFailedRunEnded = events.contains { ev in
            if case .runEnded(_, let success, _) = ev { return success == false }
            return false
        }
        #expect(hasFailedRunEnded)
    }

    @Test("stalled chunk producer salvages a verified partial on interChunkGap")
    func interChunkGapSalvagesVerifiedPartial() async throws {
        let model = StallingStreamingModel(chunks: ["par", "tial"])
        let chain = VerifierChain<String>(name: "out", [
            AnyVerifier<String>(name: "p", cost: .parse) { _, _ in .pass }
        ])
        let budget = Budget(wallClock: .seconds(30), interChunkGap: .milliseconds(150))
        let loop = StreamingControlLoop(budget: budget, outputVerifier: chain)
        let clock = ContinuousClock()
        let start = clock.now
        let run = loop.run(prompt: "p", modelClient: model, runContext: RunContext())
        var sawSuccess = false
        for try await ev in run.stream {
            if case .runCompleted(let success) = ev { sawSuccess = success }
        }
        let outcome = try await run.outcome.value
        #expect(outcome.final == "partial")
        #expect(outcome.usage.outputTokens >= 1)
        #expect(sawSuccess)
        // The gap deadline (150ms) must cut the stall short, never the
        // model's 60s hang.
        #expect(clock.now - start < .seconds(20))
    }

    @Test("stalled chunk producer with failing verification throws budgetExhausted(.interChunkGap)")
    func interChunkGapUnverifiedPartialThrows() async throws {
        let model = StallingStreamingModel(chunks: ["par", "tial"])
        let chain = VerifierChain<String>(name: "out", [
            AnyVerifier<String>(name: "gate", cost: .parse) { _, _ in
                .reject(Diagnostic(verifier: "gate", message: "partial not acceptable"))
            }
        ])
        let budget = Budget(wallClock: .seconds(30), interChunkGap: .milliseconds(150))
        let loop = StreamingControlLoop(budget: budget, outputVerifier: chain)
        let run = loop.run(prompt: "p", modelClient: model, runContext: RunContext())
        for try await _ in run.stream {}
        do {
            _ = try await run.outcome.value
            Issue.record("expected budgetExhausted(.interChunkGap)")
        } catch CompoundError.budgetExhausted(let kind, let usage) {
            #expect(kind == .interChunkGap)
            // The unverified partial still debits the token tally.
            #expect(usage.outputTokens >= 1)
        }
    }

    @Test("stream that never yields trips firstToken")
    func firstTokenStallThrows() async throws {
        let model = NeverYieldingStreamingModel()
        let chain = VerifierChain<String>(name: "out", [
            AnyVerifier<String>(name: "p", cost: .parse) { _, _ in .pass }
        ])
        let budget = Budget(wallClock: .seconds(30), firstToken: .milliseconds(150))
        let loop = StreamingControlLoop(budget: budget, outputVerifier: chain)
        let clock = ContinuousClock()
        let start = clock.now
        let run = loop.run(prompt: "p", modelClient: model, runContext: RunContext())
        for try await _ in run.stream {}
        do {
            _ = try await run.outcome.value
            Issue.record("expected budgetExhausted(.firstToken)")
        } catch CompoundError.budgetExhausted(let kind, let usage) {
            #expect(kind == .firstToken)
            // Nothing arrived, so there is nothing to salvage.
            #expect(usage.outputTokens == 0)
        }
        #expect(clock.now - start < .seconds(20))
    }

    @Test("mid-stream stall trips wallClock when no gap cap is set")
    func midStreamStallTripsWallClock() async throws {
        let model = StallingStreamingModel(chunks: ["par", "tial"])
        let chain = VerifierChain<String>(name: "out", [
            AnyVerifier<String>(name: "gate", cost: .parse) { _, _ in
                .reject(Diagnostic(verifier: "gate", message: "partial not acceptable"))
            }
        ])
        let budget = Budget(wallClock: .milliseconds(300))
        let loop = StreamingControlLoop(budget: budget, outputVerifier: chain)
        let clock = ContinuousClock()
        let start = clock.now
        let run = loop.run(prompt: "p", modelClient: model, runContext: RunContext())
        for try await _ in run.stream {}
        do {
            _ = try await run.outcome.value
            Issue.record("expected budgetExhausted(.wallClock)")
        } catch CompoundError.budgetExhausted(let kind, _) {
            #expect(kind == .wallClock)
        }
        #expect(clock.now - start < .seconds(20))
    }

    @Test("hung final task after a completed stream trips wallClock")
    func hungFinalTaskTripsWallClock() async throws {
        let model = HungFinalStreamingModel()
        let chain = VerifierChain<String>(name: "out", [
            AnyVerifier<String>(name: "p", cost: .parse) { _, _ in .pass }
        ])
        let budget = Budget(wallClock: .milliseconds(400))
        let loop = StreamingControlLoop(budget: budget, outputVerifier: chain)
        let clock = ContinuousClock()
        let start = clock.now
        let run = loop.run(prompt: "p", modelClient: model, runContext: RunContext())
        for try await _ in run.stream {}
        do {
            _ = try await run.outcome.value
            Issue.record("expected budgetExhausted(.wallClock)")
        } catch CompoundError.budgetExhausted(let kind, _) {
            #expect(kind == .wallClock)
        }
        #expect(clock.now - start < .seconds(20))
    }
}
