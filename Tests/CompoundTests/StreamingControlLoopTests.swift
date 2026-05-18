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
        await #expect(throws: CompoundError.self) {
            _ = try await run.outcome.value
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
}
