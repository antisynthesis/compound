import Foundation
import FoundationModels

/// Wraps any `FoundationModels.Tool` so every invocation is gated by:
/// (1) a ``Policy`` check against the caller's ``AuthContext``,
/// (2) a chain of deterministic verifiers run against the decoded
/// arguments, (3) a chain of deterministic verifiers run against the
/// tool's *output* before it re-enters the model's context, and
/// (4) full observability through the run's ``Tracer``.
///
/// The wrapped tool only executes if policy allows and argument
/// verification passes, and its result only reaches the model if output
/// verification passes. This is the tool-surface chokepoint of the
/// Compound pattern — the place where the model's tool calls are
/// disposed of by the deterministic layer rather than executed
/// directly. Output verification matters because tool results are
/// untrusted input: indirect prompt injection travels through fetched
/// pages, retrieved documents, and stored values, so the output chain
/// is the last deterministic gate before that text reaches the model.
///
/// String-level verifiers become one-line output gates via `contramap`
/// (an identity projection when `Output == String`):
///
/// ```swift
/// try registry.register(
///     WebFetchTool(),
///     outputVerifiers: [
///         SecretsVerifier().contramap { (s: String) in s },
///         PIIVerifier().contramap { (s: String) in s },
///     ]
/// )
/// ```
///
/// Repair semantics are preserved at the tool boundary: a `.repair`
/// verdict from either chain does not abort the run. For tools whose
/// `Output` is `String` the diagnostic (message plus suggestion) is
/// returned *in band* via ``ToolResult`` so the model can correct the
/// call and retry; for non-string outputs the typed error is thrown.
public struct VerifiedTool<Wrapped: Tool>: Tool
where Wrapped.Arguments: Sendable, Wrapped.Output: Sendable {
    public typealias Arguments = Wrapped.Arguments
    public typealias Output = Wrapped.Output

    /// Underlying tool that performs the work.
    public let wrapped: Wrapped
    /// Cheapest-first verifier chain run against decoded arguments.
    public let argumentVerifiers: VerifierChain<Wrapped.Arguments>
    /// Cheapest-first verifier chain run against the tool's output
    /// before it is returned to the model. Defaults to an empty chain
    /// (always passes).
    public let outputVerifiers: VerifierChain<Wrapped.Output>
    /// Scopes the caller's ``AuthContext`` must hold.
    public let requiredScopes: Set<String>
    /// Run context (tracer, progress, identity).
    public let runContext: RunContext
    /// Policy authority consulted before each invocation.
    public let policy: any Policy

    /// Wraps `wrapped` with the supplied gating layers.
    public init(
        wrapped: Wrapped,
        argumentVerifiers: VerifierChain<Wrapped.Arguments>,
        outputVerifiers: VerifierChain<Wrapped.Output> = .empty(named: "output"),
        requiredScopes: Set<String>,
        runContext: RunContext,
        policy: any Policy
    ) {
        self.wrapped = wrapped
        self.argumentVerifiers = argumentVerifiers
        self.outputVerifiers = outputVerifiers
        self.requiredScopes = requiredScopes
        self.runContext = runContext
        self.policy = policy
    }

    /// Inherited tool name.
    public var name: String { wrapped.name }
    /// Inherited tool description.
    public var description: String { wrapped.description }
    /// Inherited argument schema.
    public var parameters: GenerationSchema { wrapped.parameters }
    /// Inherited flag controlling whether the schema is embedded in instructions.
    public var includesSchemaInInstructions: Bool { wrapped.includesSchemaInInstructions }

    /// Runs the gated tool invocation.
    ///
    /// Every invocation attempt is counted against the run's
    /// ``ToolCallMeter`` before any other gate runs, so
    /// ``Budget/maxToolCalls`` is enforced mid-turn: with a cap of N, the
    /// N+1-th call is refused before policy evaluation, argument
    /// verification, or execution.
    ///
    /// Verdict disposition, argument side (before execution):
    /// - `.pass` — proceed.
    /// - `.repair` — traced as ``TraceEvent/toolArgumentRejected(runID:tool:diagnostic:)``;
    ///   when `Output == String` the diagnostic returns in band so the
    ///   model retries, otherwise
    ///   ``CompoundError/toolArgumentRejected(name:diagnostic:)`` is thrown.
    /// - `.reject` — traced, then throws `toolArgumentRejected`.
    /// - `.escalate` — traced as ``TraceEvent/escalation(runID:reason:)``,
    ///   then throws ``CompoundError/escalationRequired(reason:lastDiagnostic:)``.
    ///
    /// Output side (after execution, before the result reaches the model):
    /// - `.pass` — the result is returned; if it is an in-band
    ///   ``ToolResult`` error string, the trace records `succeeded: false`.
    /// - `.repair` — traced as ``TraceEvent/toolOutputRejected(runID:tool:diagnostic:)``;
    ///   in-band diagnostic when `Output == String`, otherwise throws
    ///   ``CompoundError/toolOutputRejected(name:diagnostic:)``.
    /// - `.reject` — traced, then throws `toolOutputRejected`.
    /// - `.escalate` — traced, then throws `escalationRequired`.
    ///
    /// - Throws: ``CompoundError/budgetExhausted(_:_:)`` with `.toolCalls`
    ///   when the run's tool-call cap trips,
    ///   ``CompoundError/policyDenied(reason:)`` on policy denial, the
    ///   verdict-specific errors above, or any error thrown by the wrapped
    ///   tool's `call(arguments:)`.
    public func call(arguments: Wrapped.Arguments) async throws -> Wrapped.Output {
        await runContext.tracer.record(
            .toolInvocationRequested(runID: runContext.runID, tool: wrapped.name)
        )
        await runContext.progress.report(.toolInvocationRequested(name: wrapped.name))

        do {
            try await runContext.toolCallMeter.record()
        } catch {
            await runContext.tracer.record(.budgetExhausted(runID: runContext.runID, kind: .toolCalls))
            await runContext.progress.report(.toolInvocationCompleted(name: wrapped.name, succeeded: false))
            throw error
        }

        let decision = await policy.evaluate(
            .toolInvocation(name: wrapped.name, requiredScopes: requiredScopes),
            auth: runContext.auth
        )
        if case .deny(let reason) = decision {
            await runContext.tracer.record(
                .toolPolicyDenied(runID: runContext.runID, tool: wrapped.name, reason: reason)
            )
            await runContext.progress.report(.toolInvocationCompleted(name: wrapped.name, succeeded: false))
            throw CompoundError.policyDenied(reason: reason)
        }

        let verdict = try await argumentVerifiers.verify(arguments, context: runContext)
        switch verdict {
        case .pass:
            break
        case .repair(let d):
            await runContext.tracer.record(
                .toolArgumentRejected(runID: runContext.runID, tool: wrapped.name, diagnostic: d)
            )
            await runContext.progress.report(.toolInvocationCompleted(name: wrapped.name, succeeded: false))
            if let inBand = ToolResult.argumentRepairRequest(tool: wrapped.name, diagnostic: d) as? Wrapped.Output {
                return inBand
            }
            throw CompoundError.toolArgumentRejected(name: wrapped.name, diagnostic: d)
        case .reject(let d):
            await runContext.tracer.record(
                .toolArgumentRejected(runID: runContext.runID, tool: wrapped.name, diagnostic: d)
            )
            await runContext.progress.report(.toolInvocationCompleted(name: wrapped.name, succeeded: false))
            throw CompoundError.toolArgumentRejected(name: wrapped.name, diagnostic: d)
        case .escalate(let d):
            await runContext.tracer.record(.escalation(runID: runContext.runID, reason: d.message))
            await runContext.progress.report(.toolInvocationCompleted(name: wrapped.name, succeeded: false))
            throw CompoundError.escalationRequired(reason: d.message, lastDiagnostic: d)
        }

        let started = ContinuousClock.now
        let output: Wrapped.Output
        do {
            output = try await wrapped.call(arguments: arguments)
        } catch {
            let elapsed = ContinuousClock.now - started
            await runContext.tracer.record(
                .toolInvocationCompleted(
                    runID: runContext.runID,
                    tool: wrapped.name,
                    elapsed: elapsed,
                    succeeded: false
                )
            )
            await runContext.progress.report(.toolInvocationCompleted(name: wrapped.name, succeeded: false))
            throw error
        }
        let elapsed = ContinuousClock.now - started

        let outputVerdict = try await outputVerifiers.verify(output, context: runContext)
        switch outputVerdict {
        case .pass:
            // Honest tracing: an in-band "error: ..." result is a failed
            // invocation from the run's perspective even though the tool
            // returned normally.
            let succeeded = !Self.isInBandFailure(output)
            await runContext.tracer.record(
                .toolInvocationCompleted(
                    runID: runContext.runID,
                    tool: wrapped.name,
                    elapsed: elapsed,
                    succeeded: succeeded
                )
            )
            await runContext.progress.report(.toolInvocationCompleted(name: wrapped.name, succeeded: succeeded))
            return output
        case .repair(let d):
            await recordOutputRejection(d, elapsed: elapsed)
            if let inBand = ToolResult.outputRepairRequest(tool: wrapped.name, diagnostic: d) as? Wrapped.Output {
                return inBand
            }
            throw CompoundError.toolOutputRejected(name: wrapped.name, diagnostic: d)
        case .reject(let d):
            await recordOutputRejection(d, elapsed: elapsed)
            throw CompoundError.toolOutputRejected(name: wrapped.name, diagnostic: d)
        case .escalate(let d):
            await recordOutputRejection(d, elapsed: elapsed)
            await runContext.tracer.record(.escalation(runID: runContext.runID, reason: d.message))
            throw CompoundError.escalationRequired(reason: d.message, lastDiagnostic: d)
        }
    }

    /// Traces an output-side rejection: the rejection event, then the
    /// invocation completion with `succeeded: false`, then the progress
    /// report. The rejected output itself is never placed in the trace.
    private func recordOutputRejection(_ diagnostic: Diagnostic, elapsed: Duration) async {
        await runContext.tracer.record(
            .toolOutputRejected(runID: runContext.runID, tool: wrapped.name, diagnostic: diagnostic)
        )
        await runContext.tracer.record(
            .toolInvocationCompleted(
                runID: runContext.runID,
                tool: wrapped.name,
                elapsed: elapsed,
                succeeded: false
            )
        )
        await runContext.progress.report(.toolInvocationCompleted(name: wrapped.name, succeeded: false))
    }

    /// `true` when a string-output tool returned an in-band
    /// ``ToolResult`` failure string.
    private static func isInBandFailure(_ output: Wrapped.Output) -> Bool {
        guard let text = output as? String else { return false }
        return ToolResult.isInBandError(text)
    }
}
