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

/// Which assembly inputs a redactor chain is applied to. Assemblers
/// default to ``all`` — retrieved sources and stored history are as
/// capable of carrying secrets as the live user prompt, so scrubbing
/// everything is the safe baseline; narrow the scope only when an input
/// is known-clean and the scan cost matters.
public struct RedactionScope: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    /// Creates a scope from a raw bit mask.
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// The incoming user prompt for this turn.
    public static let userPrompt = RedactionScope(rawValue: 1 << 0)
    /// Retrieved source titles and bodies.
    public static let retrievedSources = RedactionScope(rawValue: 1 << 1)
    /// Stored conversation history (summary input and recent messages).
    public static let history = RedactionScope(rawValue: 1 << 2)
    /// Every input (the default).
    public static let all: RedactionScope = [.userPrompt, .retrievedSources, .history]
}

/// Runs `redactors` over `text` in order, appending the name of each
/// redactor whose output differed (once per name) to `applied`.
func runRedactors(_ redactors: [any Redactor], on text: String, applied: inout [String]) -> String {
    var working = text
    for r in redactors {
        let next = r.redact(working)
        if next != working {
            if !applied.contains(r.name) { applied.append(r.name) }
            working = next
        }
    }
    return working
}

/// ``Redactor`` backed by a single `Regex` substitution.
///
/// Inputs larger than ``inputSizeLimit`` are not scanned — even patterns
/// with bounded quantifiers can be coaxed into slow paths on pathological
/// megabyte inputs. Because a redactor cannot signal failure, the
/// oversized case fails *closed*: the whole text is replaced with a
/// placeholder rather than passed through unredacted.
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
    /// Maximum input size (bytes) the redactor will scan; larger inputs
    /// are replaced wholesale instead of scanned.
    public let inputSizeLimit: Int

    /// 1 MiB — matches ``SecretsVerifier/defaultInputSizeLimit``: bigger
    /// than any realistic prompt input, small enough that regex scans
    /// stay fast.
    public static let defaultInputSizeLimit: Int = 1 << 20

    /// Compiles `pattern` and stores it for reuse.
    ///
    /// Prefer bounded `{n,m}` quantifiers over `+`/`*` in `pattern` so an
    /// adversarial input cannot pin the regex engine.
    ///
    /// - Throws: Any error from `Regex.init(_:)` if the pattern is invalid.
    public init(name: String,
                pattern: String,
                replacement: String = "⟨redacted⟩",
                inputSizeLimit: Int = PatternRedactor.defaultInputSizeLimit) throws {
        self.name = name
        self.pattern = try Regex(pattern)
        self.replacement = replacement
        self.inputSizeLimit = inputSizeLimit
    }

    /// Wraps an already-compiled regex.
    public init(name: String,
                regex: Regex<AnyRegexOutput>,
                replacement: String = "⟨redacted⟩",
                inputSizeLimit: Int = PatternRedactor.defaultInputSizeLimit) {
        self.name = name
        self.pattern = regex
        self.replacement = replacement
        self.inputSizeLimit = inputSizeLimit
    }

    /// Returns `text` with every match of ``pattern`` replaced by
    /// ``replacement``. Inputs over ``inputSizeLimit`` bytes are replaced
    /// entirely (fail closed).
    public func redact(_ text: String) -> String {
        if text.utf8.count > inputSizeLimit {
            return "⟨redacted: input exceeded \(inputSizeLimit)-byte scan limit⟩"
        }
        return text.replacing(pattern, with: replacement)
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
    // Every pattern uses explicit `{n,m}` upper bounds (mirroring
    // SecretsVerifier's rule discipline) so adversarial inputs cannot pin
    // the regex engine on unbounded runs.

    /// Redactor that masks email addresses.
    public static func email() throws -> PatternRedactor {
        try PatternRedactor(
            name: "email",
            pattern: #"[A-Za-z0-9._%+\-]{1,64}@[A-Za-z0-9.\-]{1,253}\.[A-Za-z]{2,24}"#,
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
            pattern: #"(?i)bearer\s{1,8}[A-Za-z0-9._\-]{16,512}"#,
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

    /// One ``PatternRedactor`` per ``SecretsVerifier`` rule, so context
    /// assembly scrubs the same credential shapes the output-side
    /// ``SecretsVerifier`` flags (cloud/SaaS API keys, VCS tokens,
    /// payment keys, JWTs, PEM private-key headers — 24 rules by
    /// default). Rules ship with bounded quantifiers already.
    public static func fromSecretsRules(
        _ rules: [SecretsVerifier.SecretRule] = SecretsVerifier.defaultRules,
        replacement: String = "⟨secret⟩"
    ) -> [PatternRedactor] {
        rules.map {
            PatternRedactor(name: "secret-\($0.id)", regex: $0.pattern, replacement: replacement)
        }
    }
}
