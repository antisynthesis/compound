import Foundation

/// Runs a heterogeneous set of ``Verifier``s cheapest-first. Composing a
/// chain is the primary way clients build a complete disposer: parse
/// before schema, schema before types, types before tests, and so on.
/// Order is enforced by a deterministic `(cost, name)` sort regardless of
/// insertion order, so equal-cost members always run in the same order.
///
/// Disposition is governed by ``Mode``: the default
/// ``Mode/shortCircuit`` stops at the first non-``Verdict/pass`` verdict,
/// while ``Mode/collectAll(maxDiagnostics:)`` keeps running past
/// ``Verdict/repair(_:)`` verdicts so one repair round can fix every
/// reported defect at once (``Verdict/reject(_:)`` and
/// ``Verdict/escalate(_:)`` still terminate immediately in both modes).
///
/// # Example
/// ```swift
/// let chain = VerifierChain<String>(name: "output", mode: .collectAll(maxDiagnostics: 8), [
///     NonEmptyVerifier().erased(),
///     UTF8Verifier().erased(),
///     JSONSchemaVerifier(schema: schema).erased(),
/// ])
/// ```
public struct VerifierChain<Input: Sendable>: Verifier {
    /// Disposition strategy for non-``Verdict/pass`` verdicts.
    public enum Mode: Sendable, Equatable {
        /// Stop at the first non-``Verdict/pass`` verdict (the default).
        /// Cheapest for gate-style chains, but each repair round surfaces
        /// exactly one defect.
        case shortCircuit
        /// Keep running past ``Verdict/repair(_:)`` verdicts, aggregate up
        /// to `maxDiagnostics` diagnostics, and surface them together so a
        /// single repair round can address every defect. ``Verdict/reject(_:)``
        /// and ``Verdict/escalate(_:)`` still terminate the chain
        /// immediately — they are not worth spending further verifier cost
        /// on. `maxDiagnostics` values below 1 are treated as 1.
        case collectAll(maxDiagnostics: Int)

        /// ``collectAll(maxDiagnostics:)`` with the default cap of 8.
        public static var collectingAll: Mode { .collectAll(maxDiagnostics: 8) }
    }

    /// Chain-level name used in trace events.
    public let name: String
    /// Inherited cost from the cheapest member, or ``VerifierCost/parse``
    /// for an empty chain.
    public let cost: VerifierCost
    /// Members in ascending `(cost, name)` order.
    public let members: [AnyVerifier<Input>]
    /// Disposition strategy for non-``Verdict/pass`` verdicts.
    public let mode: Mode

    /// Creates a chain. Members are sorted ascending by the deterministic
    /// key `(cost, name)` — insertion order never affects execution order,
    /// even between members of equal cost.
    public init(name: String = "chain", mode: Mode = .shortCircuit, _ members: [AnyVerifier<Input>]) {
        self.name = name
        self.mode = mode
        self.members = members.sorted {
            ($0.cost.rawValue, $0.name) < ($1.cost.rawValue, $1.name)
        }
        self.cost = self.members.first?.cost ?? .parse
    }

    /// Runs the members cheapest-first per ``mode``, emitting a
    /// ``TraceEvent/verifierEvaluated(runID:verifier:cost:verdict:elapsed:)``
    /// for each member evaluated.
    ///
    /// In ``Mode/collectAll(maxDiagnostics:)`` multiple accumulated
    /// ``Verdict/repair(_:)`` diagnostics are folded into one via
    /// ``Diagnostic/combined(_:verifier:)``; callers that need the
    /// individual diagnostics use ``verifyCollecting(_:context:)``.
    public func verify(_ input: Input, context: RunContext) async throws -> Verdict {
        try await verifyCollecting(input, context: context).verdict
    }

    /// Like ``verify(_:context:)`` but also returns the individual
    /// non-``Verdict/pass`` diagnostics gathered along the way (one entry
    /// under ``Mode/shortCircuit``; up to `maxDiagnostics` under
    /// ``Mode/collectAll(maxDiagnostics:)``). Empty on a passing verdict.
    public func verifyCollecting(
        _ input: Input,
        context: RunContext
    ) async throws -> (verdict: Verdict, diagnostics: [Diagnostic]) {
        var collected: [Diagnostic] = []
        let cap: Int
        switch mode {
        case .shortCircuit: cap = 1
        case .collectAll(let maxDiagnostics): cap = max(1, maxDiagnostics)
        }

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
            switch verdict {
            case .pass:
                continue
            case .repair(let diagnostic):
                if case .shortCircuit = mode {
                    return (verdict, [diagnostic])
                }
                if collected.count < cap {
                    collected.append(diagnostic)
                }
            case .reject, .escalate:
                // Terminal in both modes: the diagnostic is the terminating
                // verifier's own, never a stale aggregate.
                return (verdict, [verdict.diagnostic].compactMap { $0 })
            }
        }

        guard !collected.isEmpty else { return (.pass, []) }
        return (.repair(.combined(collected, verifier: name)), collected)
    }
}

extension VerifierChain {
    /// Constructs an empty chain (always returns ``Verdict/pass``).
    public static func empty(named name: String = "chain") -> VerifierChain<Input> {
        VerifierChain(name: name, [])
    }
}
