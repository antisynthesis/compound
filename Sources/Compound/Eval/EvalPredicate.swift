import Foundation

/// The question that does not accept a confident answer at face value:
/// given the model's actual output, did the case pass? The model is a
/// beautiful liar, so a predicate checks the work, not the swagger. The
/// protocol stays small so a case can stack any number of them and the
/// runner can compose them.
public protocol EvalPredicate: Sendable {
    /// Stable predicate name surfaced in ``EvalReport``.
    var name: String { get }
    /// Evaluates `output` and returns an ``EvalCheck``.
    func evaluate(output: String, runContext: RunContext) async throws -> EvalCheck
}

/// Result of evaluating one ``EvalPredicate``.
public struct EvalCheck: Sendable, Equatable {
    /// `true` if the check passed.
    public let passed: Bool
    /// Optional failure message (or supplemental note on pass).
    public let message: String?

    /// Creates a check.
    public init(passed: Bool, message: String? = nil) {
        self.passed = passed
        self.message = message
    }

    /// Convenience: a passing check with no message.
    public static let pass = EvalCheck(passed: true)
    /// Convenience: a failing check with an explanation.
    public static func fail(_ msg: String) -> EvalCheck { .init(passed: false, message: msg) }
}

/// Predicate that requires `output` to contain a substring.
public struct ContainsPredicate: EvalPredicate {
    /// Required substring.
    public let needle: String
    /// `true` for case-insensitive matching.
    public let caseInsensitive: Bool
    public var name: String { "contains:\(needle)" }

    /// Creates a predicate.
    public init(_ needle: String, caseInsensitive: Bool = false) {
        self.needle = needle
        self.caseInsensitive = caseInsensitive
    }

    public func evaluate(output: String, runContext _: RunContext) async throws -> EvalCheck {
        let haystack = caseInsensitive ? output.lowercased() : output
        let n = caseInsensitive ? needle.lowercased() : needle
        return haystack.contains(n) ? .pass : .fail("output does not contain '\(needle)'")
    }
}

/// Predicate that requires `output` to *not* contain a substring.
public struct DoesNotContainPredicate: EvalPredicate {
    /// Forbidden substring.
    public let needle: String
    public var name: String { "not-contains:\(needle)" }
    /// Creates a predicate.
    public init(_ needle: String) { self.needle = needle }
    public func evaluate(output: String, runContext _: RunContext) async throws -> EvalCheck {
        output.contains(needle) ? .fail("output contains forbidden '\(needle)'") : .pass
    }
}

/// Predicate that requires `output` to match a regex.
///
/// Marked `@unchecked Sendable` because `Regex<AnyRegexOutput>` is not
/// formally `Sendable`. All stored fields are immutable.
public struct MatchesRegexPredicate: EvalPredicate, @unchecked Sendable {
    /// Source pattern (preserved for the predicate name and diagnostics).
    public let pattern: String
    /// Compiled regex.
    public let regex: Regex<AnyRegexOutput>
    public var name: String { "matches:\(pattern)" }
    /// Compiles `pattern` and stores it.
    public init(_ pattern: String) throws {
        self.pattern = pattern
        self.regex = try Regex(pattern)
    }
    public func evaluate(output: String, runContext _: RunContext) async throws -> EvalCheck {
        ((try? regex.firstMatch(in: output)) != nil) ? .pass : .fail("output does not match /\(pattern)/")
    }
}

/// Conscripts a ``Verifier`` — the system's deterministic disposer — into
/// eval duty. The predicate passes iff the verifier returns ``Verdict/pass``;
/// any other verdict is a failure, diagnostic and all. The same instrument
/// that gates production now interrogates the test bench.
public struct VerifierPredicate<V: Verifier>: EvalPredicate where V.Input == String {
    /// Underlying verifier.
    public let verifier: V
    public var name: String { "verifier:\(verifier.name)" }
    /// Wraps `verifier`.
    public init(_ verifier: V) { self.verifier = verifier }
    public func evaluate(output: String, runContext: RunContext) async throws -> EvalCheck {
        let verdict = try await verifier.verify(output, context: runContext)
        switch verdict {
        case .pass: return .pass
        case .repair(let d): return .fail("repair: \(d.summary)")
        case .reject(let d): return .fail("reject: \(d.message)")
        case .escalate(let d): return .fail("escalate: \(d.message)")
        }
    }
}

/// A predicate carved from a closure on the spot — for the one-off check
/// that doesn't deserve its own type but still has to be answered honestly.
public struct ClosurePredicate: EvalPredicate {
    public let name: String
    private let body: @Sendable (String, RunContext) async throws -> EvalCheck
    /// Wraps `body`.
    public init(name: String, _ body: @escaping @Sendable (String, RunContext) async throws -> EvalCheck) {
        self.name = name
        self.body = body
    }
    public func evaluate(output: String, runContext: RunContext) async throws -> EvalCheck {
        try await body(output, runContext)
    }
}
