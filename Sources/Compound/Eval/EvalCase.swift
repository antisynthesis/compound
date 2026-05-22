import Foundation

/// One refusal to ship on faith. A prompt plus a list of ``EvalPredicate``
/// that must all pass for the case to count as green — because measuring
/// beats trusting the vibe. Cases are inert data; ``EvalRunner`` is what
/// drags them through a session and makes them prove it.
public struct EvalCase: Sendable {
    /// Stable case identifier.
    public let id: String
    /// User prompt fed to the session.
    public let prompt: String
    /// Predicates evaluated against the run outcome.
    public let predicates: [any EvalPredicate]
    /// Free-form tags used by ``EvalSuite/filtered(tags:)``.
    public let tags: Set<String>
    /// Metadata propagated through the run.
    public let metadata: [String: String]
    /// Auth context the case runs under.
    public let auth: AuthContext

    /// Creates an eval case.
    public init(
        id: String,
        prompt: String,
        predicates: [any EvalPredicate],
        tags: Set<String> = [],
        metadata: [String: String] = [:],
        auth: AuthContext = .anonymous
    ) {
        self.id = id
        self.prompt = prompt
        self.predicates = predicates
        self.tags = tags
        self.metadata = metadata
        self.auth = auth
    }
}

/// A named battery of ``EvalCase``s — the questions you commit to asking
/// every build before you let yourself believe it works.
public struct EvalSuite: Sendable {
    /// Suite name surfaced in ``EvalReport``.
    public let name: String
    /// Suite cases in declaration order.
    public let cases: [EvalCase]

    /// Creates a suite.
    public init(name: String, cases: [EvalCase]) {
        self.name = name
        self.cases = cases
    }

    /// Returns a new suite containing only cases whose tags overlap
    /// `tags`.
    public func filtered(tags: Set<String>) -> EvalSuite {
        EvalSuite(
            name: name,
            cases: cases.filter { !$0.tags.isDisjoint(with: tags) }
        )
    }
}
