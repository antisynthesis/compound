import Foundation
import FoundationModels

/// Successful result of ``StreamingControlLoop/run(prompt:modelClient:runContext:)``.
public struct StreamingLoopOutcome: Sendable {
    /// Final accumulated output that passed every chain member.
    public let final: String
    /// Resource accounting at run completion.
    public let usage: BudgetUsage
    /// Identifier from the originating ``RunContext``.
    public let runID: UUID
}

/// Streaming variant of ``ControlLoop``. The propose-and-check cycle is
/// unchanged, but model output is exposed token-by-token to the caller
/// while the loop is running. Verification still happens on the complete
/// output once a turn finishes — correctness is preserved by gating on
/// the final aggregate, not on partial chunks.
public struct StreamingControlLoop: Sendable {
    /// Per-run resource caps.
    public let budget: Budget
    /// Cheapest-first verifier chain applied to every completed turn.
    public let outputVerifier: VerifierChain<String>
    /// Generation options passed to the model.
    public let generationOptions: GenerationOptions
    /// Buffer cap for the run's ``ProgressEvent`` stream.
    public let eventBufferLimit: Int

    /// Default upper bound on buffered ``ProgressEvent``s before back-pressure
    /// drops the oldest entry.
    public static let defaultEventBufferLimit: Int = 256

    /// Creates a streaming control loop.
    public init(
        budget: Budget = .default,
        outputVerifier: VerifierChain<String> = .empty(),
        generationOptions: GenerationOptions = GenerationOptions(),
        eventBufferLimit: Int = StreamingControlLoop.defaultEventBufferLimit
    ) {
        self.budget = budget
        self.outputVerifier = outputVerifier
        self.generationOptions = generationOptions
        self.eventBufferLimit = max(1, eventBufferLimit)
    }

    /// Handle returned by ``StreamingControlLoop/run(prompt:modelClient:runContext:)``.
    /// ``stream`` yields every ``ProgressEvent`` from the run; ``outcome``
    /// resolves to the final result. Cancelling either cancels the other.
    public struct Run: Sendable {
        /// Per-event progress stream.
        public let stream: AsyncThrowingStream<ProgressEvent, Error>
        /// Eventual run outcome.
        public let outcome: Task<StreamingLoopOutcome, Error>
    }

    /// Begins a streaming run. Returns immediately with a ``Run`` whose
    /// stream and outcome track progress and completion.
    ///
    /// - Parameters:
    ///   - prompt: The user prompt.
    ///   - modelClient: Any ``ModelStreaming`` adapter.
    ///   - runContext: Shared run context.
    /// - Returns: A ``Run`` for observing progress and awaiting outcome.
    public func run(
        prompt: String,
        modelClient: any ModelStreaming,
        runContext: RunContext
    ) -> Run {
        let (eventStream, eventCont) = AsyncThrowingStream<ProgressEvent, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(eventBufferLimit)
        )
        let task = Task<StreamingLoopOutcome, Error> {
            var usage = BudgetUsage()
            let started = ContinuousClock.now

            await runContext.tracer.record(
                .runStarted(runID: runContext.runID, prompt: prompt, budget: budget, auth: runContext.auth.principal)
            )
            eventCont.yield(.runStarted(runID: runContext.runID))

            var nextPrompt = prompt
            var lastDiagnostic: Diagnostic? = nil

            while true {
                try Task.checkCancellation()
                usage.recordTurn()
                usage.recordElapsed(ContinuousClock.now - started)
                if let exhaustion = budget.remaining(usage) {
                    await runContext.tracer.record(.budgetExhausted(runID: runContext.runID, kind: exhaustion))
                    await runContext.tracer.record(.runEnded(runID: runContext.runID, success: false, usage: usage))
                    eventCont.yield(.runCompleted(success: false))
                    eventCont.finish()
                    throw CompoundError.budgetExhausted(exhaustion, usage)
                }

                eventCont.yield(.turnStarted(turn: usage.turns))

                let streamingResult = await modelClient.stream(to: nextPrompt, options: generationOptions)

                // Track running estimate so we can cancel the in-flight turn the
                // moment the output-token budget is breached mid-stream rather
                // than waiting for the full turn to complete.
                var runningTurnTokens = 0
                let priorOutputTokens = usage.outputTokens

                do {
                    for try await chunk in streamingResult.stream {
                        try Task.checkCancellation()
                        eventCont.yield(.modelStreamChunk(turn: usage.turns, content: chunk))
                        if let cap = budget.maxTotalOutputTokens {
                            runningTurnTokens += Budget.approximateTokens(chunk)
                            if priorOutputTokens + runningTurnTokens >= cap {
                                streamingResult.final.cancel()
                                break
                            }
                        }
                    }
                } catch {
                    streamingResult.final.cancel()
                    _ = try? await streamingResult.final.value
                    await runContext.tracer.record(.runEnded(runID: runContext.runID, success: false, usage: usage))
                    eventCont.finish(throwing: error)
                    throw error
                }

                let output: String
                do {
                    output = try await streamingResult.final.value
                } catch {
                    if let cap = budget.maxTotalOutputTokens,
                       priorOutputTokens + runningTurnTokens >= cap {
                        usage.recordOutputTokens(runningTurnTokens)
                        await runContext.tracer.record(.budgetExhausted(runID: runContext.runID, kind: .outputTokens))
                        await runContext.tracer.record(.runEnded(runID: runContext.runID, success: false, usage: usage))
                        eventCont.yield(.runCompleted(success: false))
                        eventCont.finish()
                        throw CompoundError.budgetExhausted(.outputTokens, usage)
                    }
                    await runContext.tracer.record(.runEnded(runID: runContext.runID, success: false, usage: usage))
                    eventCont.finish(throwing: error)
                    throw error
                }
                try Task.checkCancellation()
                usage.recordOutputTokens(Budget.approximateTokens(output))
                eventCont.yield(.modelTurnCompleted(turn: usage.turns, content: output))

                let verdict = try await runVerifiers(
                    output: output,
                    runContext: runContext,
                    eventCont: eventCont
                )
                switch verdict {
                case .pass:
                    await runContext.tracer.record(.runEnded(runID: runContext.runID, success: true, usage: usage))
                    eventCont.yield(.runCompleted(success: true))
                    eventCont.finish()
                    return StreamingLoopOutcome(final: output, usage: usage, runID: runContext.runID)

                case .repair(let diag):
                    usage.recordRepair()
                    lastDiagnostic = diag
                    await runContext.tracer.record(
                        .repairScheduled(runID: runContext.runID, attempt: usage.repairAttempts, diagnostic: diag)
                    )
                    eventCont.yield(.repairScheduled(attempt: usage.repairAttempts, diagnostic: diag))
                    usage.recordElapsed(ContinuousClock.now - started)
                    if let exhaustion = budget.remaining(usage) {
                        await runContext.tracer.record(.budgetExhausted(runID: runContext.runID, kind: exhaustion))
                        await runContext.tracer.record(.runEnded(runID: runContext.runID, success: false, usage: usage))
                        eventCont.yield(.runCompleted(success: false))
                        eventCont.finish()
                        throw CompoundError.budgetExhausted(exhaustion, usage)
                    }
                    nextPrompt = Self.repairPrompt(from: diag)
                    continue

                case .reject(let d):
                    await runContext.tracer.record(.runEnded(runID: runContext.runID, success: false, usage: usage))
                    eventCont.yield(.runCompleted(success: false))
                    eventCont.finish()
                    throw CompoundError.verifierRejected(reason: d.message, lastDiagnostic: lastDiagnostic ?? d)

                case .escalate(let d):
                    await runContext.tracer.record(.escalation(runID: runContext.runID, reason: d.message))
                    await runContext.tracer.record(.runEnded(runID: runContext.runID, success: false, usage: usage))
                    eventCont.yield(.runCompleted(success: false))
                    eventCont.finish()
                    throw CompoundError.escalationRequired(reason: d.message, lastDiagnostic: lastDiagnostic ?? d)
                }
            }
        }

        eventCont.onTermination = { _ in task.cancel() }
        return Run(stream: eventStream, outcome: task)
    }

    private func runVerifiers(
        output: String,
        runContext: RunContext,
        eventCont: AsyncThrowingStream<ProgressEvent, Error>.Continuation
    ) async throws -> Verdict {
        for member in outputVerifier.members {
            eventCont.yield(.verifierStarted(name: member.name, cost: member.cost))
            await runContext.progress.report(.verifierStarted(name: member.name, cost: member.cost))
            let started = ContinuousClock.now
            let verdict = try await member.verify(output, context: runContext)
            let elapsed = ContinuousClock.now - started
            await runContext.tracer.record(
                .verifierEvaluated(
                    runID: runContext.runID,
                    verifier: member.name,
                    cost: member.cost,
                    verdict: verdict,
                    elapsed: elapsed
                )
            )
            eventCont.yield(.verifierCompleted(name: member.name, verdict: verdict))
            await runContext.progress.report(.verifierCompleted(name: member.name, verdict: verdict))
            if !verdict.isPass {
                return verdict
            }
        }
        return .pass
    }

    private static func repairPrompt(from diagnostic: Diagnostic) -> String {
        var msg = "The previous response failed verification: \(diagnostic.message)."
        if let suggestion = diagnostic.suggestion { msg += " " + suggestion }
        msg += " Produce a corrected response."
        return msg
    }
}
