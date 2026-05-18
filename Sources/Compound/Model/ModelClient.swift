import Foundation
import FoundationModels

// The stochastic core. ModelClient is the only place in the framework that
// talks to Apple's on-device LanguageModelSession. Its responsibilities are
// deliberately narrow: check availability, format the request, run the call,
// time it, trace it. The compound system's reliability does not come from
// here — it comes from the verifier and tool layers wrapping this call.

/// Non-streaming model surface. Extracted so tests and alternative backends
/// can inject a fake in place of the concrete ``ModelClient`` actor.
public protocol ModelResponding: Sendable {
    /// Sends `prompt` and returns the full response as a string.
    func respond(to prompt: String, options: GenerationOptions) async throws -> String
    /// Sends `prompt` and decodes a `Generable` value of type `T`.
    func respondGenerating<T: Generable & Sendable>(
        _ type: T.Type,
        to prompt: String,
        options: GenerationOptions
    ) async throws -> T
}

/// Result of a streaming model call.
///
/// ``stream`` yields delta chunks (the suffix added since the previous
/// yield, not the rolling whole) and ``final`` resolves to the full
/// accumulated output once generation finishes. Cancelling the stream
/// cancels ``final`` and vice versa.
public struct ModelStreamResult: Sendable {
    /// Delta-chunk stream.
    public let stream: AsyncThrowingStream<String, Error>
    /// Resolves to the full accumulated output when generation finishes.
    public let final: Task<String, Error>

    /// Creates a streaming result.
    public init(stream: AsyncThrowingStream<String, Error>, final: Task<String, Error>) {
        self.stream = stream
        self.final = final
    }
}

/// Streaming model surface. Lets the control loop hold a protocol
/// existential rather than the concrete ``ModelClient`` actor.
public protocol ModelStreaming: Sendable {
    /// Begins streaming a response to `prompt`. The returned
    /// ``ModelStreamResult`` exposes both per-chunk and final-output APIs.
    func stream(to prompt: String, options: GenerationOptions) async -> ModelStreamResult
}

/// Actor-backed adapter over Apple's on-device `LanguageModelSession`.
///
/// `ModelClient` is the only place in the framework that talks to the
/// stochastic core. Its responsibilities are deliberately narrow: check
/// availability, format the request, run the call, time it, trace it.
/// System-level reliability is supplied by the verifier and tool layers
/// wrapping this call rather than by the model itself.
///
/// # Example
/// ```swift
/// let client = try ModelClient(
///     instructions: "You are a helpful assistant.",
///     tools: [calculator],
///     runContext: ctx
/// )
/// let answer = try await client.respond(to: "2 + 2?")
/// ```
public actor ModelClient: ModelResponding, ModelStreaming {
    /// Shared context for tracing and progress reporting.
    public let runContext: RunContext
    internal let session: LanguageModelSession
    private var turnCounter: Int = 0

    /// Creates a client over the supplied on-device model.
    ///
    /// - Parameters:
    ///   - instructions: System instructions for the underlying session.
    ///   - tools: Tools exposed to the model.
    ///   - runContext: Shared context (run ID, tracer, progress).
    ///   - model: The on-device model. Defaults to ``SystemLanguageModel/default``.
    /// - Throws: ``CompoundError/modelUnavailable(reason:)`` if the model
    ///   reports an unavailable state.
    public init(
        instructions: String,
        tools: [any Tool] = [],
        runContext: RunContext,
        model: SystemLanguageModel = .default
    ) throws {
        switch model.availability {
        case .available:
            break
        case .unavailable(let reason):
            throw CompoundError.modelUnavailable(reason: Self.label(reason))
        }
        self.runContext = runContext
        self.session = LanguageModelSession(
            model: model,
            tools: tools,
            instructions: instructions
        )
    }

    /// Sends `prompt` and returns the model's response as a string,
    /// emitting paired ``TraceEvent/modelInvocationStarted(runID:turn:promptBytes:)``
    /// and ``TraceEvent/modelInvocationCompleted(runID:turn:outputBytes:elapsed:)``
    /// events.
    ///
    /// - Throws: ``CompoundError/underlying(_:)`` wrapping the session error.
    public func respond(
        to prompt: String,
        options: GenerationOptions = GenerationOptions()
    ) async throws -> String {
        turnCounter += 1
        let turn = turnCounter
        let promptBytes = prompt.utf8.count
        await runContext.tracer.record(
            .modelInvocationStarted(runID: runContext.runID, turn: turn, promptBytes: promptBytes)
        )

        let started = ContinuousClock.now
        do {
            let response = try await session.respond(to: prompt, options: options)
            let elapsed = ContinuousClock.now - started
            await runContext.tracer.record(
                .modelInvocationCompleted(
                    runID: runContext.runID,
                    turn: turn,
                    outputBytes: response.content.utf8.count,
                    elapsed: elapsed
                )
            )
            return response.content
        } catch {
            await runContext.tracer.record(
                .modelInvocationFailed(
                    runID: runContext.runID,
                    turn: turn,
                    reason: String(describing: error)
                )
            )
            throw CompoundError.underlying(error)
        }
    }

    /// Sends `prompt` and decodes a structured `Generable` value of
    /// type `T`. Same trace and error contract as ``respond(to:options:)``.
    public func respondGenerating<T: Generable & Sendable>(
        _ type: T.Type,
        to prompt: String,
        options: GenerationOptions = GenerationOptions()
    ) async throws -> T {
        turnCounter += 1
        let turn = turnCounter
        let promptBytes = prompt.utf8.count
        await runContext.tracer.record(
            .modelInvocationStarted(runID: runContext.runID, turn: turn, promptBytes: promptBytes)
        )

        let started = ContinuousClock.now
        do {
            let response = try await session.respond(to: prompt, generating: type, options: options)
            let elapsed = ContinuousClock.now - started
            let outputBytes = response.rawContent.debugDescription.utf8.count
            await runContext.tracer.record(
                .modelInvocationCompleted(
                    runID: runContext.runID,
                    turn: turn,
                    outputBytes: outputBytes,
                    elapsed: elapsed
                )
            )
            return response.content
        } catch {
            await runContext.tracer.record(
                .modelInvocationFailed(
                    runID: runContext.runID,
                    turn: turn,
                    reason: String(describing: error)
                )
            )
            throw CompoundError.underlying(error)
        }
    }

    /// Snapshot of the underlying session's conversation transcript.
    public func currentTranscript() -> Transcript {
        session.transcript
    }

    /// Number of model invocations issued by this client so far.
    public var turnCount: Int { turnCounter }

    internal func bumpTurn() -> Int {
        turnCounter += 1
        return turnCounter
    }

    private static func label(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible: return "device not eligible for Apple Intelligence"
        case .appleIntelligenceNotEnabled: return "Apple Intelligence not enabled"
        case .modelNotReady: return "model not ready (still downloading)"
        @unknown default: return "unavailable (unknown reason)"
        }
    }
}
