import Foundation

/// Deterministic judgment returned by a ``Verifier``. The four cases mirror
/// the pattern's vocabulary: `pass` (move on), `repair` (retry with
/// diagnostic), `reject` (give up cleanly), `escalate` (defer to a human).
/// The control loop reacts to each.
public enum Verdict: Sendable, Equatable {
    /// Verification succeeded.
    case pass
    /// Verification failed but is worth retrying with the supplied
    /// diagnostic threaded into the next prompt.
    case repair(Diagnostic)
    /// Verification failed terminally; the run should fail with the
    /// diagnostic surfaced.
    case reject(Diagnostic)
    /// Verification cannot be resolved by the framework; defer to a
    /// human operator.
    case escalate(Diagnostic)

    /// `true` if this is ``pass``.
    public var isPass: Bool {
        if case .pass = self { return true }
        return false
    }
}

extension Verdict {
    /// Convenience factory: build a `.reject` verdict from a free-form
    /// reason string. The diagnostic is synthesized with verifier name
    /// `"reject"` so existing call sites that pass a string keep compiling.
    public static func reject(_ reason: String) -> Verdict {
        .reject(Diagnostic(verifier: "reject", message: reason))
    }

    /// Convenience factory: build an `.escalate` verdict from a free-form
    /// reason string.
    public static func escalate(_ reason: String) -> Verdict {
        .escalate(Diagnostic(verifier: "escalate", message: reason))
    }
}

/// Structured failure description carried by ``Verdict/repair(_:)``,
/// ``Verdict/reject(_:)``, and ``Verdict/escalate(_:)``. Pairs a
/// verifier-identified message with an optional repair suggestion and
/// source location so consumers can render actionable diagnostics.
public struct Diagnostic: Sendable, Equatable, Hashable {
    /// Name of the originating verifier.
    public let verifier: String
    /// What went wrong.
    public let message: String
    /// Optional repair suggestion; used by the control loop when crafting
    /// the next prompt.
    public let suggestion: String?
    /// Optional offset range pointing into the verified input.
    public let location: SourceRange?

    /// Creates a diagnostic.
    public init(verifier: String, message: String, suggestion: String? = nil, location: SourceRange? = nil) {
        self.verifier = verifier
        self.message = message
        self.suggestion = suggestion
        self.location = location
    }

    /// Single-line summary suitable for logs and UI.
    public var summary: String {
        var out = "[\(verifier)] \(message)"
        if let suggestion { out += " (try: \(suggestion))" }
        if let location { out += " at \(location.start)..\(location.end)" }
        return out
    }
}

/// Half-open `[start, end)` byte/character offset range used by
/// ``Diagnostic`` to point at a span of input.
public struct SourceRange: Sendable, Equatable, Hashable {
    /// Inclusive start offset.
    public let start: Int
    /// Exclusive end offset.
    public let end: Int
    /// Creates a range.
    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

/// Cost hint used by ``VerifierChain`` to order verifiers cheapest-first.
/// Numeric values are deliberate — chains sort ascending. The names mirror
/// the ladder in the pattern doc: parse, schema, types, lint, unit,
/// integration, proof, human.
public enum VerifierCost: Int, Sendable, Comparable {
    /// Free or near-free structural checks (encoding, parse-ability).
    case parse = 0
    /// Schema/shape conformance.
    case schema = 10
    /// Type-level checks (e.g. compile-style).
    case types = 20
    /// Lint and style checks.
    case lint = 30
    /// Unit-level execution checks.
    case unitTest = 40
    /// Integration-level execution checks.
    case integrationTest = 50
    /// Formal proof or other expensive verification.
    case proof = 60
    /// Human-in-the-loop review.
    case human = 70

    public static func < (lhs: VerifierCost, rhs: VerifierCost) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
