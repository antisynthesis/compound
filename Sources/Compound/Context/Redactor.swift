import Foundation

/// Deterministic transformation applied to text before it reaches the
/// model. PII patterns, secret patterns, and classification markers are
/// typical use cases. The model only ever sees what survives this pass.
public protocol Redactor: Sendable {
    /// Stable name surfaced in ``AssembledContext/redactionsApplied``.
    var name: String { get }
    /// Returns `text` with sensitive content replaced.
    func redact(_ text: String) -> String
}

/// ``Redactor`` backed by a single `Regex` substitution.
///
/// Marked `@unchecked Sendable` because `Regex<AnyRegexOutput>` is not
/// formally `Sendable`. All stored fields are immutable and regex
/// matching is safe to share across actors.
public struct PatternRedactor: Redactor, @unchecked Sendable {
    /// Stable name.
    public let name: String
    /// Compiled regex.
    public let pattern: Regex<AnyRegexOutput>
    /// Replacement string substituted for every match.
    public let replacement: String

    /// Compiles `pattern` and stores it for reuse.
    ///
    /// - Throws: Any error from `Regex.init(_:)` if the pattern is invalid.
    public init(name: String, pattern: String, replacement: String = "⟨redacted⟩") throws {
        self.name = name
        self.pattern = try Regex(pattern)
        self.replacement = replacement
    }

    /// Returns `text` with every match of ``pattern`` replaced by
    /// ``replacement``.
    public func redact(_ text: String) -> String {
        text.replacing(pattern, with: replacement)
    }
}

/// Composes multiple redactors into a single pipeline; members run in
/// the order supplied at construction.
public struct CompositeRedactor: Redactor {
    /// Stable name.
    public let name: String
    /// Member redactors in application order.
    public let members: [any Redactor]

    /// Creates a composite over `members`.
    public init(name: String = "composite-redactor", _ members: [any Redactor]) {
        self.name = name
        self.members = members
    }

    /// Folds every member over `text` left-to-right.
    public func redact(_ text: String) -> String {
        members.reduce(text) { $1.redact($0) }
    }
}

/// Convenience set of common redactors. Not a substitute for a real DLP
/// layer; useful for prototypes and as a baseline.
public enum CommonRedactors {
    /// Redactor that masks email addresses.
    public static func email() throws -> PatternRedactor {
        try PatternRedactor(
            name: "email",
            pattern: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#,
            replacement: "⟨email⟩"
        )
    }

    /// Redactor that masks US phone numbers (with optional separators).
    public static func usPhone() throws -> PatternRedactor {
        try PatternRedactor(
            name: "us-phone",
            pattern: #"\(?\d{3}\)?[\s.\-]?\d{3}[\s.\-]?\d{4}"#,
            replacement: "⟨phone⟩"
        )
    }

    /// Redactor that masks `Bearer <token>` authorization headers.
    public static func bearerToken() throws -> PatternRedactor {
        try PatternRedactor(
            name: "bearer-token",
            pattern: #"(?i)bearer\s+[A-Za-z0-9._\-]{16,}"#,
            replacement: "Bearer ⟨token⟩"
        )
    }

    /// Redactor that masks AWS access key identifiers (`AKIA...`).
    public static func awsAccessKey() throws -> PatternRedactor {
        try PatternRedactor(
            name: "aws-access-key",
            pattern: #"AKIA[0-9A-Z]{16}"#,
            replacement: "⟨aws-key⟩"
        )
    }
}
