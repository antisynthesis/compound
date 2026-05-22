import Foundation
import FoundationModels

/// What survives the loop. A result of ``ControlLoop/run(prompt:modelClient:runContext:)``
/// that earned its place — every member of the chain looked at it and refused
/// to object. Nothing reaches here on the model's word alone.
public struct LoopOutcome: Sendable {
    /// Final model output that passed every chain member.
    public let output: String
    /// Resource accounting at run completion.
    public let usage: BudgetUsage
    /// Identifier from the originating ``RunContext``.
    public let runID: UUID
}

/// The control loop. The model proposes; the system disposes. It asks a
/// ``ModelResponding`` for a response, refuses to trust it, gates it
/// through the supplied output ``VerifierChain``, and on failure feeds the
/// diagnostic back as a repair turn — every dimension fenced by ``Budget``.
/// This is propose→check→repair with a hard terminal state; there is no
/// unbounded agent loop here, by design.
///
/// The loop, not the model, decides what verifier runs and when to stop. A
/// model that could skip its own verification is a model you are choosing
/// to believe. We don't.
///
/// # Example
/// ```swift
/// let loop = ControlLoop(
///     budget: .default,
///     outputVerifier: VerifierChain(name: "out", [JSONVerifier().erased()])
/// )
/// let outcome = try await loop.run(
///     prompt: prompt,
///     modelClient: client,
///     runContext: ctx
/// )
/// ```
public struct ControlLoop: Sendable {
    /// Per-run resource caps.
    public let budget: Budget
    /// Cheapest-first verifier chain applied to every model output.
    public let outputVerifier: VerifierChain<String>
    /// Generation options passed to the model on each turn.
    public let generationOptions: GenerationOptions

    /// Creates a control loop.
    public init(
        budget: Budget = .default,
        outputVerifier: VerifierChain<String> = .empty(),
        generationOptions: GenerationOptions = GenerationOptions()
    ) {
        self.budget = budget
        self.outputVerifier = outputVerifier
        self.generationOptions = generationOptions
    }

    /// Runs propose→check→repair until the loop reaches a terminal state —
    /// pass, reject, escalate, or budget exhausted. There is always a wall;
    /// the loop cannot run forever. Honors task cancellation between turns
    /// and around the model call.
    ///
    /// - Parameters:
    ///   - prompt: The user prompt to start the loop with.
    ///   - modelClient: Any ``ModelResponding``-conforming actor.
    ///   - runContext: Carries trace IDs, progress reporter, and identity.
    /// - Returns: The final ``LoopOutcome`` on a passing verdict.
    /// - Throws: ``CompoundError/budgetExhausted(_:_:)`` on budget exhaustion,
    ///   ``CompoundError/verifierRejected(reason:lastDiagnostic:)`` on a
    ///   terminal verifier verdict, ``CompoundError/escalationRequired(reason:lastDiagnostic:)``
    ///   on escalation, or `CancellationError` on cancellation.
    public func run(
        prompt: String,
        modelClient: any ModelResponding,
        runContext: RunContext
    ) async throws -> LoopOutcome {
        var usage = BudgetUsage()
        let started = ContinuousClock.now

        await runContext.tracer.record(
            .runStarted(
                runID: runContext.runID,
                prompt: prompt,
                budget: budget,
                auth: runContext.auth.principal
            )
        )

        var nextPrompt = prompt
        var lastDiagnostic: Diagnostic? = nil

        while true {
            try Task.checkCancellation()
            usage.recordTurn()
            usage.recordElapsed(ContinuousClock.now - started)
            if let exhaustion = budget.remaining(usage) {
                await runContext.tracer.record(.budgetExhausted(runID: runContext.runID, kind: exhaustion))
                await runContext.tracer.record(.runEnded(runID: runContext.runID, success: false, usage: usage))
                throw CompoundError.budgetExhausted(exhaustion, usage)
            }

            await runContext.progress.report(.turnStarted(turn: usage.turns))

            let output: String
            do {
                output = try await modelClient.respond(to: nextPrompt, options: generationOptions)
            } catch {
                await runContext.tracer.record(.runEnded(runID: runContext.runID, success: false, usage: usage))
                throw error
            }
            try Task.checkCancellation()
            usage.recordOutputTokens(Budget.approximateTokens(output))

            let verdict = try await runVerifiers(output: output, runContext: runContext)
            switch verdict {
            case .pass:
                await runContext.tracer.record(.runEnded(runID: runContext.runID, success: true, usage: usage))
                return LoopOutcome(output: output, usage: usage, runID: runContext.runID)

            case .repair(let diag):
                usage.recordRepair()
                lastDiagnostic = diag
                await runContext.tracer.record(
                    .repairScheduled(runID: runContext.runID, attempt: usage.repairAttempts, diagnostic: diag)
                )
                usage.recordElapsed(ContinuousClock.now - started)
                if let exhaustion = budget.remaining(usage) {
                    await runContext.tracer.record(.budgetExhausted(runID: runContext.runID, kind: exhaustion))
                    await runContext.tracer.record(.runEnded(runID: runContext.runID, success: false, usage: usage))
                    throw CompoundError.budgetExhausted(exhaustion, usage)
                }
                nextPrompt = Self.repairPrompt(from: diag)
                continue

            case .reject(let d):
                await runContext.tracer.record(.runEnded(runID: runContext.runID, success: false, usage: usage))
                throw CompoundError.verifierRejected(reason: d.message, lastDiagnostic: lastDiagnostic ?? d)

            case .escalate(let d):
                await runContext.tracer.record(.escalation(runID: runContext.runID, reason: d.message))
                await runContext.tracer.record(.runEnded(runID: runContext.runID, success: false, usage: usage))
                throw CompoundError.escalationRequired(reason: d.message, lastDiagnostic: lastDiagnostic ?? d)
            }
        }
    }

    // Runs the chain member-by-member so each verifier gets a paired
    // verifierStarted / verifierCompleted progress event. The chain's internal
    // tracer events are still emitted (via member.verify -> chain logic is in
    // VerifierChain), so we iterate the members directly here to keep the
    // progress channel honest about which verifier produced which verdict.
    private func runVerifiers(output: String, runContext: RunContext) async throws -> Verdict {
        for member in outputVerifier.members {
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
            await runContext.progress.report(.verifierCompleted(name: member.name, verdict: verdict))
            if !verdict.isPass {
                return verdict
            }
        }
        return .pass
    }

    private static func repairPrompt(from diagnostic: Diagnostic) -> String {
        var msg = "The previous response failed verification: \(diagnostic.message)."
        if let suggestion = diagnostic.suggestion {
            msg += " " + suggestion
        }
        msg += " Produce a corrected response."
        return msg
    }
}
