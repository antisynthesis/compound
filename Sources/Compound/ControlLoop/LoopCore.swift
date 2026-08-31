import Foundation

/// Everything a ``RepairPromptBuilder`` gets to work with when a turn's
/// output fails verification and a repair turn has been scheduled.
public struct RepairContext: Sendable {
    /// The original task — the prompt the run started with (the first
    /// turn's prompt, not the previous repair prompt).
    public let originalTask: String
    /// The output that failed verification, truncated to the builder's
    /// byte cap (see ``RepairPromptBuilder/failedOutputByteCap``).
    public let failedOutput: String
    /// `true` when ``failedOutput`` was truncated to fit the byte cap.
    public let failedOutputTruncated: Bool
    /// Every diagnostic surfaced by the verifier chain for this turn —
    /// one entry under ``VerifierChain/Mode/shortCircuit``, up to the
    /// configured cap under ``VerifierChain/Mode/collectAll(maxDiagnostics:)``.
    public let diagnostics: [Diagnostic]
    /// 1-based repair attempt number this prompt is for.
    public let attempt: Int

    /// Creates a repair context.
    public init(
        originalTask: String,
        failedOutput: String,
        failedOutputTruncated: Bool = false,
        diagnostics: [Diagnostic],
        attempt: Int
    ) {
        self.originalTask = originalTask
        self.failedOutput = failedOutput
        self.failedOutputTruncated = failedOutputTruncated
        self.diagnostics = diagnostics
        self.attempt = attempt
    }
}

/// Strategy that turns a failed turn into the next prompt.
///
/// Intrinsic self-correction — asking a model to "try again" with no
/// concrete evidence — is not a real capability (Huang et al., ICLR 2024);
/// the pattern that works is re-asking with the concrete validation error.
/// ``default`` therefore rebuilds a self-contained prompt: the original
/// task, the failed output (byte-capped), and every diagnostic with its
/// suggestion. That is the correct choice for *stateless*
/// ``ModelResponding`` conformers, and merely redundant for stateful ones.
/// ``diagnosticOnly`` sends just the diagnostics — sufficient only when
/// the conformer is stateful and still has the task and its own failed
/// answer in the transcript (see the statefulness contract on
/// ``ModelResponding``).
public struct RepairPromptBuilder: Sendable {
    /// Byte cap applied to ``RepairContext/failedOutput`` before the
    /// builder runs. Truncation lands on a character boundary at or below
    /// the cap.
    public let failedOutputByteCap: Int
    private let body: @Sendable (RepairContext) -> String

    /// Default byte cap for the failed output echoed into the prompt.
    public static let defaultFailedOutputByteCap = 4096

    /// Creates a builder from a closure.
    public init(
        failedOutputByteCap: Int = RepairPromptBuilder.defaultFailedOutputByteCap,
        build: @escaping @Sendable (RepairContext) -> String
    ) {
        self.failedOutputByteCap = max(0, failedOutputByteCap)
        self.body = build
    }

    /// Renders the repair prompt for `context`.
    public func build(_ context: RepairContext) -> String {
        body(context)
    }

    /// Self-contained repair prompt: original task + elided failed output
    /// + every diagnostic with its suggestion. Safe for stateless and
    /// stateful ``ModelResponding`` conformers alike.
    public static let `default` = RepairPromptBuilder { context in
        var lines: [String] = []
        lines.append("Your previous response failed verification (repair attempt \(context.attempt)).")
        lines.append("")
        lines.append("Original task:")
        lines.append(context.originalTask)
        lines.append("")
        lines.append(context.failedOutputTruncated ? "Failed response (truncated):" : "Failed response:")
        lines.append(context.failedOutput)
        lines.append("")
        lines.append(context.diagnostics.count == 1 ? "Diagnostic:" : "Diagnostics:")
        for (index, diagnostic) in context.diagnostics.enumerated() {
            var line = "\(index + 1). [\(diagnostic.verifier)] \(diagnostic.message)"
            if let suggestion = diagnostic.suggestion {
                line += " Suggestion: \(suggestion)"
            }
            lines.append(line)
        }
        lines.append("")
        lines.append("Produce a corrected response to the original task that addresses every diagnostic. Respond with the corrected response only.")
        return lines.joined(separator: "\n")
    }

    /// Diagnostic-only repair prompt preserving the framework's historical
    /// behavior: no task restatement, no failed output. Only sufficient
    /// for *stateful* ``ModelResponding`` conformers whose transcript
    /// still contains the task and the failed answer.
    public static let diagnosticOnly = RepairPromptBuilder(failedOutputByteCap: 0) { context in
        LoopCore.repairPrompt(from: .combined(context.diagnostics))
    }

    /// Truncates `text` to at most `cap` UTF-8 bytes on a character
    /// boundary. Returns the (possibly shortened) text and whether any
    /// truncation happened.
    static func truncate(_ text: String, toUTF8Bytes cap: Int) -> (text: String, truncated: Bool) {
        guard text.utf8.count > cap else { return (text, false) }
        var bytes = 0
        var end = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            bytes += text[index..<next].utf8.count
            if bytes > cap { break }
            end = next
            index = next
        }
        return (String(text[..<end]), true)
    }
}

/// Next action decided by ``LoopCore`` after a completed model turn.
enum LoopStep: Sendable {
    /// The output passed every verifier; the run is complete.
    case done(String)
    /// A repair turn was scheduled; re-enter the loop with this prompt.
    case repair(nextPrompt: String)
}

/// Typed-loop counterpart of ``LoopStep``, decided after a completed
/// extraction turn.
enum TypedLoopStep<Value: Sendable>: Sendable {
    /// The extracted value passed every typed verifier; the run is complete.
    case done(Value)
    /// A repair extraction was scheduled; re-invoke the extractor with this
    /// prompt.
    case repair(nextPrompt: String)
}

/// Shared engine for ``ControlLoop`` and ``StreamingControlLoop``. Budget
/// check-then-record, verifier execution, verdict disposition, and repair
/// prompt construction live here exactly once; the loop variants keep only
/// their transport concerns — `respond()` for the non-streaming loop,
/// chunk plumbing for the streaming loop.
///
/// Budget semantics (see ``Budget/exhaustion(afterAdding:to:)``): each cap
/// is the number of allowed occurrences, enforced by checking *before*
/// recording. `maxTurns: 1` permits exactly one model call and
/// `maxRepairAttempts: 1` permits exactly one repair.
struct LoopCore: Sendable {
    /// Per-run resource caps.
    let budget: Budget
    /// Cheapest-first verifier chain applied to every completed turn.
    let outputVerifier: VerifierChain<String>
    /// Backoff schedule for transient model-invocation failures.
    let retryPolicy: RetryPolicy
    /// Decides which model-invocation errors are worth a retry.
    let retryClassifier: any RetryClassifier
    /// Builds the next prompt when a turn fails verification and a repair
    /// turn is scheduled.
    let repairPromptBuilder: RepairPromptBuilder
    /// Mirror hook for the streaming loop's event continuation; a no-op for
    /// the non-streaming loop. Called alongside — never instead of — the
    /// ``RunContext``'s tracer and progress reporter.
    let emit: @Sendable (ProgressEvent) -> Void
    /// Per-run count of guardrail violations surfaced by the model layer.
    /// One `LoopCore` is constructed per run, so the meter's lifetime is
    /// exactly one run.
    let guardrailMeter = GuardrailViolationMeter()

    init(
        budget: Budget,
        outputVerifier: VerifierChain<String>,
        retryPolicy: RetryPolicy = .default,
        retryClassifier: any RetryClassifier = DefaultRetryClassifier(),
        repairPromptBuilder: RepairPromptBuilder = .default,
        emit: @escaping @Sendable (ProgressEvent) -> Void = { _ in }
    ) {
        self.budget = budget
        self.outputVerifier = outputVerifier
        self.retryPolicy = retryPolicy
        self.retryClassifier = retryClassifier
        self.repairPromptBuilder = repairPromptBuilder
        self.emit = emit
    }

    /// Starts a turn: folds elapsed time and the run's tool-call meter into
    /// `usage`, checks the budget for one more turn, and only then records
    /// it — so the recorded turn is always allowed to run.
    func beginTurn(
        usage: inout BudgetUsage,
        started: ContinuousClock.Instant,
        runContext: RunContext
    ) async throws {
        try Task.checkCancellation()
        usage.recordElapsed(ContinuousClock.now - started)
        usage.toolCalls = await runContext.toolCallMeter.count
        if let exhaustion = budget.exhaustion(afterAdding: .turns, to: usage) {
            throw await exhausted(exhaustion, usage: usage, runContext: runContext)
        }
        usage.recordTurn()
        emit(.turnStarted(turn: usage.turns))
        await runContext.progress.report(.turnStarted(turn: usage.turns))
    }

    /// Invokes the model transport for one turn with ``Retry/with(policy:classifier:body:)``
    /// wrapped around it: transient-classified errors (per ``retryClassifier``)
    /// are retried on the ``retryPolicy`` schedule; terminal errors —
    /// guardrail violations, unsupported language, context-window exhaustion,
    /// verifier-style failures — surface immediately without consuming a
    /// retry attempt or any repair budget. Elapsed time (including retry
    /// backoff sleeps) is folded into `usage` on both paths so it debits
    /// ``Budget/wallClock`` at the next budget check.
    ///
    /// On failure the error is mapped through
    /// ``CompoundError/mapSessionError(_:classifier:)`` (a no-op for errors
    /// the ``ModelClient`` boundary already mapped), the per-run guardrail
    /// counter is recorded, and the run-ended trace is emitted.
    /// `CancellationError` passes through unmapped — the loops throw raw
    /// cancellation everywhere else.
    ///
    /// The whole invocation — retries and backoff sleeps included — runs
    /// under ``withDeadline(_:clock:operation:)`` capped at the budget's
    /// *remaining* wall clock, so a hung model call surfaces as
    /// ``CompoundError/budgetExhausted(_:_:)`` with
    /// ``BudgetExhaustion/wallClock`` at the cap instead of blocking the run
    /// forever. (The deadline cancels the in-flight call; a transport that
    /// never suspends nor checks cancellation keeps running detached, but
    /// the loop still returns at the cap.)
    func invokeModel<Output: Sendable>(
        usage: inout BudgetUsage,
        started: ContinuousClock.Instant,
        runContext: RunContext,
        body: @escaping @Sendable () async throws -> Output
    ) async throws -> Output {
        usage.recordElapsed(ContinuousClock.now - started)
        let remainingWall = budget.wallClock - usage.elapsed
        guard remainingWall > .zero else {
            throw await exhausted(.wallClock, usage: usage, runContext: runContext)
        }
        do {
            let output = try await withDeadline(remainingWall) {
                try await Retry.with(policy: self.retryPolicy, classifier: self.retryClassifier, body: body)
            }
            usage.recordElapsed(ContinuousClock.now - started)
            return output
        } catch is DeadlineExceededError {
            usage.recordElapsed(ContinuousClock.now - started)
            throw await exhausted(.wallClock, usage: usage, runContext: runContext)
        } catch {
            usage.recordElapsed(ContinuousClock.now - started)
            throw await modelFailure(error, usage: usage, runContext: runContext)
        }
    }

    /// Maps a model-transport error into the taxonomy, records the per-run
    /// guardrail-violation counter when applicable, records the run-ended
    /// trace, and returns the error for the caller to throw.
    /// `CancellationError` and existing ``CompoundError``s pass through
    /// unchanged.
    func modelFailure(
        _ error: any Error,
        usage: BudgetUsage,
        runContext: RunContext
    ) async -> any Error {
        let mapped: any Error = error is CancellationError
            ? error
            : CompoundError.mapSessionError(error)
        if let compound = mapped as? CompoundError, case .guardrailViolation(let context) = compound {
            let count = await guardrailMeter.increment()
            await runContext.tracer.record(
                .info(
                    runID: runContext.runID,
                    category: "guardrailViolation",
                    message: "guardrail violation #\(count)" + (context.map { ": \($0)" } ?? "")
                )
            )
        }
        await runContext.tracer.record(.runEnded(runID: runContext.runID, success: false, usage: usage))
        return mapped
    }

    /// Disposes of a completed turn's output: runs the verifier chain and
    /// acts on the verdict. Returns ``LoopStep/done(_:)`` on pass,
    /// ``LoopStep/repair(nextPrompt:)`` when a repair turn fits the budget,
    /// and throws for every terminal disposition.
    ///
    /// `originalTask` is the prompt the run *started* with — never a prior
    /// repair prompt — so ``repairPromptBuilder`` can rebuild a
    /// self-contained prompt for stateless transports.
    ///
    /// `isFinal` is `true` (the default) when a passing verdict completes
    /// the run. The typed loop's reason-then-extract mode passes `false`
    /// for its phase-one reasoning turn: a pass there hands off to the
    /// extraction phase, so the successful run-ended trace and completion
    /// event must wait for the typed settle. Failure paths (repair
    /// scheduling, reject, escalate, budget exhaustion) are unaffected.
    func settle(
        output: String,
        originalTask: String,
        usage: inout BudgetUsage,
        started: ContinuousClock.Instant,
        runContext: RunContext,
        isFinal: Bool = true
    ) async throws -> LoopStep {
        usage.toolCalls = await runContext.toolCallMeter.count
        let (verdict, diagnostics) = try await runVerifiers(
            chain: outputVerifier,
            input: output,
            runContext: runContext
        )
        switch try await dispose(
            verdict: verdict,
            diagnostics: diagnostics,
            renderedOutput: output,
            originalTask: originalTask,
            usage: &usage,
            started: started,
            runContext: runContext,
            isFinal: isFinal
        ) {
        case .pass:
            return .done(output)
        case .repair(let nextPrompt):
            return .repair(nextPrompt: nextPrompt)
        }
    }

    /// Best-of-N counterpart of ``settle(output:originalTask:usage:started:runContext:isFinal:)``.
    ///
    /// The chain has already run — once per candidate — inside
    /// ``BestOfNSampler``, so this disposes the *selected* candidate's
    /// verdict without re-verifying it. Re-running the chain here would
    /// double every verifier's cost and, for a verifier with any
    /// nondeterminism, could contradict the verdict the selection was based
    /// on. The losing candidates contribute nothing: their diagnostics are
    /// never fed to a repair turn, because a repair prompt describing an
    /// output the model is not being asked to fix is worse than no prompt.
    func settleSelected(
        _ draw: BestOfNDraw,
        originalTask: String,
        usage: inout BudgetUsage,
        started: ContinuousClock.Instant,
        runContext: RunContext,
        isFinal: Bool = true
    ) async throws -> LoopStep {
        usage.toolCalls = await runContext.toolCallMeter.count
        let selected = draw.selected
        switch try await dispose(
            verdict: selected.verdict,
            diagnostics: selected.diagnostics,
            renderedOutput: selected.output,
            originalTask: originalTask,
            usage: &usage,
            started: started,
            runContext: runContext,
            isFinal: isFinal
        ) {
        case .pass:
            return .done(selected.output)
        case .repair(let nextPrompt):
            return .repair(nextPrompt: nextPrompt)
        }
    }

    /// Typed-loop counterpart of ``settle(output:originalTask:usage:started:runContext:isFinal:)``:
    /// runs `verifiers` over the extracted `value` and disposes of the
    /// verdict with the exact same budget, trace, and repair semantics as
    /// the string path. `renderedOutput` is the string form of `value`
    /// echoed into the repair prompt (typed values have no canonical text,
    /// so the caller renders once and the repair context byte-caps it).
    /// `originalTask` is the extraction source — the phase-one reasoning
    /// text in reason-then-extract mode, the user prompt in direct mode —
    /// so a repair prompt stays self-contained for stateless extractors.
    func settleTyped<Value: Sendable>(
        value: Value,
        renderedOutput: String,
        verifiers: VerifierChain<Value>,
        originalTask: String,
        usage: inout BudgetUsage,
        started: ContinuousClock.Instant,
        runContext: RunContext
    ) async throws -> TypedLoopStep<Value> {
        usage.toolCalls = await runContext.toolCallMeter.count
        let (verdict, diagnostics) = try await runVerifiers(
            chain: verifiers,
            input: value,
            runContext: runContext
        )
        switch try await dispose(
            verdict: verdict,
            diagnostics: diagnostics,
            renderedOutput: renderedOutput,
            originalTask: originalTask,
            usage: &usage,
            started: started,
            runContext: runContext,
            isFinal: true
        ) {
        case .pass:
            return .done(value)
        case .repair(let nextPrompt):
            return .repair(nextPrompt: nextPrompt)
        }
    }

    /// Verdict disposition shared by the string and typed settles. Records
    /// budget, trace, and progress effects; returns ``Disposition/pass`` or
    /// ``Disposition/repair(nextPrompt:)``, and throws for every terminal
    /// verdict.
    private func dispose(
        verdict: Verdict,
        diagnostics: [Diagnostic],
        renderedOutput: String,
        originalTask: String,
        usage: inout BudgetUsage,
        started: ContinuousClock.Instant,
        runContext: RunContext,
        isFinal: Bool
    ) async throws -> Disposition {
        switch verdict {
        case .pass:
            if isFinal {
                await runContext.tracer.record(.runEnded(runID: runContext.runID, success: true, usage: usage))
                emit(.runCompleted(success: true))
            }
            return .pass

        case .repair(let diag):
            usage.recordElapsed(ContinuousClock.now - started)
            if let exhaustion = budget.exhaustion(afterAdding: .repairAttempts, to: usage) {
                throw await exhausted(exhaustion, usage: usage, runContext: runContext)
            }
            usage.recordRepair()
            await runContext.tracer.record(
                .repairScheduled(runID: runContext.runID, attempt: usage.repairAttempts, diagnostic: diag)
            )
            emit(.repairScheduled(attempt: usage.repairAttempts, diagnostic: diag))
            let (failedOutput, wasTruncated) = RepairPromptBuilder.truncate(
                renderedOutput,
                toUTF8Bytes: repairPromptBuilder.failedOutputByteCap
            )
            let repairContext = RepairContext(
                originalTask: originalTask,
                failedOutput: failedOutput,
                failedOutputTruncated: wasTruncated,
                diagnostics: diagnostics.isEmpty ? [diag] : diagnostics,
                attempt: usage.repairAttempts
            )
            return .repair(nextPrompt: repairPromptBuilder.build(repairContext))

        case .reject(let d):
            await runContext.tracer.record(.runEnded(runID: runContext.runID, success: false, usage: usage))
            emit(.runCompleted(success: false))
            // The payload is the rejecting verifier's own diagnostic — the
            // most recent one surfaced in the run — never a stale diagnostic
            // from an earlier repair turn.
            throw CompoundError.verifierRejected(reason: d.message, lastDiagnostic: d)

        case .escalate(let d):
            await runContext.tracer.record(.escalation(runID: runContext.runID, reason: d.message))
            await runContext.tracer.record(.runEnded(runID: runContext.runID, success: false, usage: usage))
            emit(.runCompleted(success: false))
            throw CompoundError.escalationRequired(reason: d.message, lastDiagnostic: d)
        }
    }

    /// Outcome of ``dispose(verdict:diagnostics:renderedOutput:originalTask:usage:started:runContext:isFinal:)``
    /// when the verdict was not terminal.
    private enum Disposition: Sendable {
        case pass
        case repair(nextPrompt: String)
    }

    /// Attempts to salvage partial output accumulated before a mid-stream
    /// stall: the full verifier chain runs over `partial`, and only a
    /// passing verdict rescues the turn — repair, reject, and escalate all
    /// decline, because a stalled model cannot take a repair prompt. On
    /// pass, the successful run-ended trace and completion event are
    /// recorded; on decline nothing is recorded and the caller throws its
    /// timeout error instead.
    ///
    /// - Returns: `true` when `partial` passed every chain member and the
    ///   caller may return it as the run's final output.
    func salvage(
        partial: String,
        usage: BudgetUsage,
        runContext: RunContext
    ) async -> Bool {
        guard
            let (verdict, _) = try? await runVerifiers(chain: outputVerifier, input: partial, runContext: runContext),
            verdict.isPass
        else {
            return false
        }
        await runContext.tracer.record(.runEnded(runID: runContext.runID, success: true, usage: usage))
        emit(.runCompleted(success: true))
        return true
    }

    /// Records the budget-exhaustion trace pair, emits the failure event,
    /// and returns the error for the caller to throw.
    func exhausted(
        _ kind: BudgetExhaustion,
        usage: BudgetUsage,
        runContext: RunContext
    ) async -> CompoundError {
        await runContext.tracer.record(.budgetExhausted(runID: runContext.runID, kind: kind))
        await runContext.tracer.record(.runEnded(runID: runContext.runID, success: false, usage: usage))
        emit(.runCompleted(success: false))
        return .budgetExhausted(kind, usage)
    }

    // Runs the chain member-by-member so each verifier gets a paired
    // verifierStarted / verifierCompleted progress event. The chain's internal
    // tracer events are still emitted (via member.verify -> chain logic is in
    // VerifierChain), so we iterate the members directly here to keep the
    // progress channel honest about which verifier produced which verdict.
    // Generic over the chain's input so the string output chain and a typed
    // extraction chain share one implementation.
    //
    // Mirrors VerifierChain.verifyCollecting's mode semantics: shortCircuit
    // stops at the first non-pass verdict; collectAll keeps going past
    // .repair verdicts (up to the diagnostic cap) so one repair round can
    // fix every reported defect, while .reject/.escalate terminate
    // immediately in both modes.
    private func runVerifiers<Input: Sendable>(
        chain: VerifierChain<Input>,
        input: Input,
        runContext: RunContext
    ) async throws -> (verdict: Verdict, diagnostics: [Diagnostic]) {
        var collected: [Diagnostic] = []
        let cap: Int
        switch chain.mode {
        case .shortCircuit: cap = 1
        case .collectAll(let maxDiagnostics): cap = max(1, maxDiagnostics)
        }

        for member in chain.members {
            let verdict = try await evaluate(member, input: input, runContext: runContext)
            switch verdict {
            case .pass:
                continue
            case .repair(let diagnostic):
                if case .shortCircuit = chain.mode {
                    return (verdict, [diagnostic])
                }
                if collected.count < cap {
                    collected.append(diagnostic)
                }
            case .reject, .escalate:
                return (verdict, [verdict.diagnostic].compactMap { $0 })
            }
        }

        guard !collected.isEmpty else { return (.pass, []) }
        return (.repair(.combined(collected, verifier: chain.name)), collected)
    }

    /// Runs one chain member, emitting the paired progress events and the
    /// `verifierEvaluated` trace event. Shared by the single-candidate
    /// traversal and the best-of-N per-member traversal so a verifier is
    /// observed identically whichever path reached it.
    private func evaluate<Input: Sendable>(
        _ member: AnyVerifier<Input>,
        input: Input,
        runContext: RunContext
    ) async throws -> Verdict {
        emit(.verifierStarted(name: member.name, cost: member.cost))
        await runContext.progress.report(.verifierStarted(name: member.name, cost: member.cost))
        let started = ContinuousClock.now
        let verdict = try await member.verify(input, context: runContext)
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
        emit(.verifierCompleted(name: member.name, verdict: verdict))
        await runContext.progress.report(.verifierCompleted(name: member.name, verdict: verdict))
        return verdict
    }

    /// Runs **every** chain member over `input` and returns each member's
    /// own verdict, paired with the weight `weight` assigns it.
    ///
    /// Best-of-N needs per-member verdicts, not a folded chain verdict: a
    /// weighted score is undefined unless you know which verifiers a
    /// candidate satisfied. That means the chain's
    /// ``VerifierChain/Mode/shortCircuit`` mode is deliberately *not*
    /// honored here — a short-circuiting chain would score every failing
    /// candidate identically and best-of-N would degenerate to picking the
    /// first one. Terminal verdicts (``Verdict/reject(_:)``,
    /// ``Verdict/escalate(_:)``) still stop the traversal: the candidate is
    /// already disqualified and further verifier cost buys nothing.
    func evaluateMembers<Input: Sendable>(
        chain: VerifierChain<Input>,
        input: Input,
        runContext: RunContext,
        weight: (String) -> Double
    ) async throws -> [SampledCandidate.MemberVerdict] {
        var out: [SampledCandidate.MemberVerdict] = []
        out.reserveCapacity(chain.members.count)
        for member in chain.members {
            let verdict = try await evaluate(member, input: input, runContext: runContext)
            out.append(
                SampledCandidate.MemberVerdict(
                    verifier: member.name,
                    verdict: verdict,
                    weight: weight(member.name)
                )
            )
            switch verdict {
            case .pass, .repair:
                continue
            case .reject, .escalate:
                return out
            }
        }
        return out
    }

    /// Counts guardrail violations for a single run. Actor-backed because
    /// ``LoopCore`` is a value type shared across concurrent contexts.
    actor GuardrailViolationMeter {
        /// Violations recorded so far.
        private(set) var count = 0

        /// Records one violation and returns the new count.
        func increment() -> Int {
            count += 1
            return count
        }
    }

    /// Legacy diagnostic-only formatting, kept as the body of
    /// ``RepairPromptBuilder/diagnosticOnly``. Assumes a *stateful*
    /// transport that still has the task and failed answer in its
    /// transcript.
    static func repairPrompt(from diagnostic: Diagnostic) -> String {
        var msg = "The previous response failed verification: \(diagnostic.message)."
        if let suggestion = diagnostic.suggestion {
            msg += " " + suggestion
        }
        msg += " Produce a corrected response."
        return msg
    }
}
