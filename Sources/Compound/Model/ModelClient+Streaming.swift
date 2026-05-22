import Foundation
import FoundationModels

// The same liar, watched in real time. This is the streaming counterpart to
// ModelClient.respond. Apple's LanguageModelSession exposes a partial-response
// stream that yields the cumulative output as it is generated; we adapt that
// into an AsyncThrowingStream<String> whose elements are the delta chunks (the
// suffix added since the previous yield) rather than the rolling whole, which
// is what most UIs want for token-level updates. The full output is captured
// on completion and traced exactly as the non-streaming path does — the stream
// is a courtesy, the record is not.

extension ModelClient {
    /// Default upper bound on buffered streamed chunks before back-pressure
    /// drops the oldest entry. Streams generally cap at a few hundred chunks;
    /// 1024 leaves comfortable headroom without retaining the entire turn.
    public static let defaultStreamBufferLimit: Int = 1024

    /// Streams a response to `prompt` with ``defaultStreamBufferLimit``.
    public func stream(
        to prompt: String,
        options: GenerationOptions = GenerationOptions()
    ) async -> ModelStreamResult {
        await stream(to: prompt, options: options, bufferLimit: Self.defaultStreamBufferLimit)
    }

    /// Streams a response to `prompt`. Chunks are deltas (the suffix added
    /// since the previous yield), not the rolling whole. The full output
    /// is captured on completion and traced exactly as
    /// ``respond(to:options:)`` would.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to stream.
    ///   - options: Generation options.
    ///   - bufferLimit: Per-stream buffer limit; clamped to at least 1.
    public func stream(
        to prompt: String,
        options: GenerationOptions = GenerationOptions(),
        bufferLimit: Int
    ) async -> ModelStreamResult {
        let turn = bumpTurn()
        let runCtx = runContext
        await runCtx.tracer.record(
            .modelInvocationStarted(runID: runCtx.runID, turn: turn, promptBytes: prompt.utf8.count)
        )
        await runCtx.progress.report(.turnStarted(turn: turn))

        let started = ContinuousClock.now
        let upstream = session.streamResponse(to: prompt, options: options)

        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(max(1, bufferLimit))
        )
        let finalTask = Task<String, Error> { [runCtx] in
            var accumulated = ""
            do {
                for try await partial in upstream {
                    try Task.checkCancellation()
                    let next = Self.partialContent(partial)
                    if next.count > accumulated.count {
                        let delta = String(next.dropFirst(accumulated.count))
                        accumulated = next
                        await runCtx.progress.report(.modelStreamChunk(turn: turn, content: delta))
                        continuation.yield(delta)
                    }
                }
                let elapsed = ContinuousClock.now - started
                await runCtx.tracer.record(
                    .modelInvocationCompleted(
                        runID: runCtx.runID,
                        turn: turn,
                        outputBytes: accumulated.utf8.count,
                        elapsed: elapsed
                    )
                )
                await runCtx.progress.report(.modelTurnCompleted(turn: turn, content: accumulated))
                continuation.finish()
                return accumulated
            } catch {
                await runCtx.tracer.record(
                    .modelInvocationFailed(
                        runID: runCtx.runID,
                        turn: turn,
                        reason: String(describing: error)
                    )
                )
                continuation.finish(throwing: CompoundError.underlying(error))
                throw CompoundError.underlying(error)
            }
        }

        continuation.onTermination = { _ in
            finalTask.cancel()
        }

        return ModelStreamResult(stream: stream, final: finalTask)
    }

    // Each Apple SDK build returns either a Response<String>-like value with
    // a `content` property or a bare String. Pull the cumulative text out
    // generically so the call site doesn't depend on the exact shape.
    private static func partialContent<T>(_ value: T) -> String {
        if let s = value as? String { return s }
        let mirror = Mirror(reflecting: value)
        for child in mirror.children {
            if child.label == "content", let s = child.value as? String { return s }
        }
        return String(describing: value)
    }
}
