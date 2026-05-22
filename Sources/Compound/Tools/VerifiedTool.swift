import Foundation
import FoundationModels

/// Nothing reaches through unguarded. This wraps any
/// `FoundationModels.Tool` so every invocation is gated by:
/// (1) a ``Policy`` check against the caller's ``AuthContext``,
/// (2) a chain of deterministic verifiers run against the decoded
/// arguments, and (3) full observability through the run's ``Tracer``.
///
/// The wrapped tool executes only if policy allows and argument
/// verification passes — otherwise it does not run, and the trace says
/// why. This is the chokepoint where the model reaches into the world: the
/// place its tool calls are disposed of by the deterministic layer instead
/// of taken at their word.
public struct VerifiedTool<Wrapped: Tool>: Tool where Wrapped.Arguments: Sendable {
    public typealias Arguments = Wrapped.Arguments
    public typealias Output = Wrapped.Output

    /// Underlying tool that performs the work.
    public let wrapped: Wrapped
    /// Cheapest-first verifier chain run against decoded arguments.
    public let argumentVerifiers: VerifierChain<Wrapped.Arguments>
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
        requiredScopes: Set<String>,
        runContext: RunContext,
        policy: any Policy
    ) {
        self.wrapped = wrapped
        self.argumentVerifiers = argumentVerifiers
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
    /// - Throws: ``CompoundError/policyDenied(reason:)`` on policy denial,
    ///   ``CompoundError/toolArgumentRejected(name:diagnostic:)`` on an
    ///   argument-verifier non-pass, or any error thrown by the wrapped
    ///   tool's `call(arguments:)`.
    public func call(arguments: Wrapped.Arguments) async throws -> Wrapped.Output {
        await runContext.tracer.record(
            .toolInvocationRequested(runID: runContext.runID, tool: wrapped.name)
        )
        await runContext.progress.report(.toolInvocationRequested(name: wrapped.name))

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
            await runContext.progress.report(.toolInvocationCompleted(name: wrapped.name, succeeded: false))
            throw CompoundError.toolArgumentRejected(name: wrapped.name, diagnostic: d)
        case .reject(let d):
            await runContext.progress.report(.toolInvocationCompleted(name: wrapped.name, succeeded: false))
            throw CompoundError.toolArgumentRejected(name: wrapped.name, diagnostic: d)
        case .escalate(let d):
            await runContext.progress.report(.toolInvocationCompleted(name: wrapped.name, succeeded: false))
            throw CompoundError.escalationRequired(reason: d.message, lastDiagnostic: d)
        }

        let started = ContinuousClock.now
        do {
            let output = try await wrapped.call(arguments: arguments)
            let elapsed = ContinuousClock.now - started
            await runContext.tracer.record(
                .toolInvocationCompleted(
                    runID: runContext.runID,
                    tool: wrapped.name,
                    elapsed: elapsed,
                    succeeded: true
                )
            )
            await runContext.progress.report(.toolInvocationCompleted(name: wrapped.name, succeeded: true))
            return output
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
    }
}
