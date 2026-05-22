import Foundation

/// A complete disposer, assembled from sharper instruments. Runs a
/// heterogeneous set of ``Verifier``s cheapest-first and short-circuits on the
/// first non-``Verdict/pass`` verdict — spend nothing proving what a cheap
/// check already condemned. Composing a chain is the primary way clients build
/// a disposer: parse before schema, schema before types, types before tests,
/// and so on. Order is enforced by ``VerifierCost`` regardless of insertion
/// order, because the guarantee should not depend on the caller remembering it.
///
/// # Example
/// ```swift
/// let chain = VerifierChain<String>(name: "output", [
///     NonEmptyVerifier().erased(),
///     UTF8Verifier().erased(),
///     JSONSchemaVerifier(schema: schema).erased(),
/// ])
/// ```
public struct VerifierChain<Input: Sendable>: Verifier {
    /// Chain-level name used in trace events.
    public let name: String
    /// Inherited cost from the cheapest member, or ``VerifierCost/parse``
    /// for an empty chain.
    public let cost: VerifierCost
    /// Members in ascending cost order.
    public let members: [AnyVerifier<Input>]

    /// Creates a chain. Members are sorted ascending by ``VerifierCost``.
    public init(name: String = "chain", _ members: [AnyVerifier<Input>]) {
        self.name = name
        self.members = members.sorted { $0.cost < $1.cost }
        self.cost = self.members.first?.cost ?? .parse
    }

    /// Runs each member until one returns a non-``Verdict/pass`` verdict,
    /// emitting a ``TraceEvent/verifierEvaluated(runID:verifier:cost:verdict:elapsed:)``
    /// for each.
    public func verify(_ input: Input, context: RunContext) async throws -> Verdict {
        for member in members {
            let started = ContinuousClock.now
            let verdict = try await member.verify(input, context: context)
            let elapsed = ContinuousClock.now - started
            await context.tracer.record(
                .verifierEvaluated(
                    runID: context.runID,
                    verifier: member.name,
                    cost: member.cost,
                    verdict: verdict,
                    elapsed: elapsed
                )
            )
            if !verdict.isPass {
                return verdict
            }
        }
        return .pass
    }
}

extension VerifierChain {
    /// Constructs an empty chain (always returns ``Verdict/pass``).
    public static func empty(named name: String = "chain") -> VerifierChain<Input> {
        VerifierChain(name: name, [])
    }
}
