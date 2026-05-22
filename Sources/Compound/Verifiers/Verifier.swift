import Foundation

/// The deterministic disposer. The model proposes; the system disposes. The
/// model is a beautiful liar — fluent, confident, wrong on its own schedule —
/// and a verifier is the part that does not negotiate with that confidence. It
/// inspects a piece of model output (or a tool argument) and returns a
/// ``Verdict``; the system's reliability bound is the verifier's reliability
/// bound, which is why every implementation declares its ``cost`` for
/// cheapest-first chain ordering. No silent abstraction stands between the
/// proposal and the judgment.
///
/// # Example
/// ```swift
/// struct NonEmpty: Verifier {
///     let name = "non.empty"
///     let cost: VerifierCost = .parse
///     func verify(_ input: String, context: RunContext) async throws -> Verdict {
///         input.isEmpty ? .reject(Diagnostic(verifier: name, message: "empty output")) : .pass
///     }
/// }
/// ```
public protocol Verifier<Input>: Sendable {
    associatedtype Input: Sendable
    /// Stable name used in trace events and diagnostics.
    var name: String { get }
    /// Cost class for ordering. Required so a chain's cheapest-first
    /// guarantee is provably enforceable from the protocol surface — no
    /// silent default that would let an expensive verifier claim `.parse`.
    var cost: VerifierCost { get }
    /// Inspects `input` and returns a ``Verdict``.
    ///
    /// - Parameters:
    ///   - input: The value being verified.
    ///   - context: The active ``RunContext``; used for tracing and
    ///     cancellation.
    /// - Returns: The verdict.
    /// - Throws: Implementation errors. The control loop translates these
    ///   into ``CompoundError`` at the surface.
    func verify(_ input: Input, context: RunContext) async throws -> Verdict
}

/// A type-erased ``Verifier`` for heterogeneous chains — the seam that lets
/// instruments of different shapes line up in a single disposer. The wrapped
/// closure preserves ``name`` and ``cost`` from the source verifier.
public struct AnyVerifier<Input: Sendable>: Verifier {
    /// Inherited name from the wrapped verifier (or supplied at init).
    public let name: String
    /// Inherited cost from the wrapped verifier (or supplied at init).
    public let cost: VerifierCost
    private let _verify: @Sendable (Input, RunContext) async throws -> Verdict

    /// Wraps an existing ``Verifier`` whose `Input` matches.
    public init<V: Verifier>(_ wrapped: V) where V.Input == Input {
        self.name = wrapped.name
        self.cost = wrapped.cost
        self._verify = { input, ctx in
            try await wrapped.verify(input, context: ctx)
        }
    }

    /// Constructs a verifier inline from a closure. Useful for one-off
    /// checks and tests.
    public init(
        name: String,
        cost: VerifierCost,
        verify: @escaping @Sendable (Input, RunContext) async throws -> Verdict
    ) {
        self.name = name
        self.cost = cost
        self._verify = verify
    }

    public func verify(_ input: Input, context: RunContext) async throws -> Verdict {
        try await _verify(input, context)
    }
}

extension Verifier {
    /// Returns a type-erased wrapper around this verifier.
    public func erased() -> AnyVerifier<Input> {
        AnyVerifier(self)
    }
}
