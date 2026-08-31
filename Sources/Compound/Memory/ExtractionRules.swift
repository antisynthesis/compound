import Foundation

/// One pattern that locates a claim inside a single sentence.
///
/// A rule is a `Regex` plus the metadata a match becomes: which relation
/// was asserted, how far the phrasing is trusted, how much it moves the
/// importance baseline, and what tags the resulting record carries.
///
/// Two captures are special, and both are optional:
///
/// - `value` — **required**. The span that becomes the claim text. It is
///   used verbatim (whitespace-trimmed only), so it must be written to
///   capture words the user actually typed, never a reconstruction.
/// - `predicate` — when present, its normalized text replaces
///   ``predicate``. This is what makes one attribute rule cover
///   "my *dentist* is …", "my *work email* is …", and "my *deadline*
///   is …" without a rule per noun.
/// - `subject` — when present, its normalized text replaces the default
///   subject. The rules that ship are all first-person, so they omit it
///   and the extractor uses the literal `"user"`.
///
/// Every shipped pattern uses explicit `{n,m}` upper bounds, matching the
/// discipline ``PatternRedactor`` and ``SecretsVerifier`` already follow:
/// extraction runs over attacker-influenced text, and an unbounded
/// quantifier there is a denial-of-service primitive.
///
/// Marked `@unchecked Sendable` for the same reason ``PatternRedactor``
/// is: `Regex<AnyRegexOutput>` is not formally `Sendable`, every stored
/// field here is immutable, and regex matching is safe to share across
/// actors.
public struct ExtractionRule: @unchecked Sendable {
    /// Stable rule name, recorded on every span it produces.
    public let name: String
    /// The compiled pattern. Must contain a capture named `value`.
    public let regex: Regex<AnyRegexOutput>
    /// Relation asserted by a match, unless the pattern captures
    /// `predicate`.
    public let predicate: String
    /// Trust **ceiling** for spans this rule produces.
    ///
    /// The extractor derives an origin from the message's role and then
    /// takes whichever of the two is *less* trusted. The default of
    /// ``MemoryOrigin/userStated`` therefore never lowers anything, while
    /// a custom rule can mark itself ``MemoryOrigin/derived`` to say "no
    /// matter who typed this, it is an inference" — which the
    /// reconciler's trust gate then holds to a higher confidence bar.
    public let origin: MemoryOrigin
    /// Confidence in `[0, 1]` assigned to a match.
    public let confidence: Double
    /// Signed adjustment to the importance baseline of 5.
    public let importanceDelta: Int
    /// Tags carried onto the candidate.
    public let tags: Set<String>

    /// Wraps an already-compiled pattern.
    ///
    /// - Precondition: `confidence` is in `[0, 1]`.
    public init(
        name: String,
        regex: Regex<AnyRegexOutput>,
        predicate: String,
        origin: MemoryOrigin = .userStated,
        confidence: Double,
        importanceDelta: Int = 0,
        tags: Set<String> = []
    ) {
        precondition(confidence >= 0 && confidence <= 1, "confidence must be in [0, 1]")
        self.name = name
        self.regex = regex
        self.predicate = predicate
        self.origin = origin
        self.confidence = confidence
        self.importanceDelta = importanceDelta
        self.tags = tags
    }

    /// Compiles `pattern` and stores it.
    ///
    /// - Throws: Any error from `Regex.init(_:)` if the pattern is
    ///   invalid.
    public init(
        name: String,
        pattern: String,
        predicate: String,
        origin: MemoryOrigin = .userStated,
        confidence: Double,
        importanceDelta: Int = 0,
        tags: Set<String> = []
    ) throws {
        self.init(
            name: name,
            regex: try Regex(pattern),
            predicate: predicate,
            origin: origin,
            confidence: confidence,
            importanceDelta: importanceDelta,
            tags: tags
        )
    }

    /// Runs the rule against one already-split sentence and returns the
    /// first match's captures, or `nil` when it does not fire.
    ///
    /// "First match" is literal: a rule contributes at most one span per
    /// sentence. A sentence that repeats a pattern ("I like tea and I
    /// like coffee") therefore yields one candidate, not two. That is a
    /// deliberate cap on how much one sentence can write, following the
    /// memory-poisoning literature's finding that permissive write
    /// policies are what turn a single crafted message into many stored
    /// records.
    func match(_ sentence: Substring) -> Capture? {
        let text = String(sentence)
        guard let match = try? regex.firstMatch(in: text) else { return nil }
        guard let value = match.output["value"]?.substring else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Capture(
            value: trimmed,
            predicate: match.output["predicate"]?.substring.map(String.init),
            subject: match.output["subject"]?.substring.map(String.init)
        )
    }

    /// The captures one firing produced.
    struct Capture {
        let value: String
        let predicate: String?
        let subject: String?
    }
}

// MARK: - Default rule tables

extension ExtractionRule {
    /// Compiles a pattern that is a source literal in this file.
    ///
    /// `try!` is correct here for the same reason ``PIIVerifier`` and
    /// ``FormatVerifiers`` use it: the patterns are fixed strings in the
    /// library, so a failure is a build-time authoring error that a test
    /// run catches immediately, not a runtime condition a caller could
    /// recover from.
    fileprivate static func compiled(_ pattern: String) -> Regex<AnyRegexOutput> {
        // swiftlint:disable:next force_try
        try! Regex(pattern)
    }
}

extension DeterministicFactExtractor {
    /// The rule table that ships by default, in evaluation order.
    ///
    /// Order matters twice. It is the tie-break for span emission within
    /// a sentence, and — because candidates that would derive the same
    /// ``FactID`` are deduplicated keeping the *first* — it decides which
    /// rule wins when two describe the same claim. `identity` sits ahead
    /// of `attribute` for exactly that reason: "my name is Ada" is a
    /// name, not a generic attribute that happens to be called "name".
    ///
    /// Every value span is captured, never composed. A rule may decide
    /// *that* something was said and *what relation* it asserts; the words
    /// themselves always come out of the user's own sentence.
    public static let defaultRules: [ExtractionRule] = [
        // identity — "my name is X" / "call me X".
        ExtractionRule(
            name: "identity",
            regex: ExtractionRule.compiled(#"(?i)\b(?:my name is|call me)\s{1,4}(?<value>[^,;:\n]{1,64})"#),
            predicate: "name",
            confidence: 0.9,
            importanceDelta: 3,
            tags: ["core"]
        ),
        // identity — "I'm X" / "I am X". The value must be capitalized,
        // which is the whole reason this is a separate rule from the one
        // above: an unrestricted "I am X" swallows "I am allergic to
        // peanuts" and stores "allergic to peanuts" as a name. Requiring
        // a capitalized run is a cheap, deterministic proxy for "this is
        // a proper noun" that costs a few real names in lowercase-typing
        // users and buys immunity to the entire copula family.
        ExtractionRule(
            name: "identity-copula",
            regex: ExtractionRule.compiled(
                #"\b[Ii](?:\s{1,3}am|['’]m)\s{1,3}(?<value>\p{Lu}[\p{L}'’\-]{1,30}(?:\s\p{Lu}[\p{L}'’\-]{1,30}){0,2})"#
            ),
            predicate: "name",
            confidence: 0.9,
            importanceDelta: 3,
            tags: ["core"]
        ),
        // preference, positive.
        ExtractionRule(
            name: "preference-positive",
            regex: ExtractionRule.compiled(
                #"(?i)\bi\s{1,3}(?:prefer|like|love|enjoy)\s{1,4}(?<value>[^,;:\n]{1,80})"#
            ),
            predicate: "prefers",
            confidence: 0.8,
            importanceDelta: 2,
            tags: ["preference"]
        ),
        // preference, negative. Listed after the positive rule but
        // structurally disjoint from it: the negative forms all place a
        // word between "I" and the verb ("I don't like"), which the
        // positive pattern's `\s{1,3}` cannot span.
        ExtractionRule(
            name: "preference-negative",
            regex: ExtractionRule.compiled(
                #"(?i)\bi\s{1,3}(?:dislike|hate|don['’]?t like|do not like|can['’]?t stand|cannot stand)\s{1,4}(?<value>[^,;:\n]{1,80})"#
            ),
            predicate: "dislikes",
            confidence: 0.8,
            importanceDelta: 2,
            tags: ["preference"]
        ),
        // attribute — "my <noun> is X", with the noun becoming the
        // predicate. One rule covers an open-ended set of relations
        // without a model, which is the point.
        ExtractionRule(
            name: "attribute",
            regex: ExtractionRule.compiled(
                #"(?i)\bmy\s{1,3}(?<predicate>[a-z]{2,24}(?:\s[a-z]{2,24}){0,2})\s{1,3}is\s{1,4}(?<value>[^,;:\n]{1,80})"#
            ),
            predicate: "attribute",
            confidence: 0.75,
            importanceDelta: 1
        ),
        // location — "I live in X" / "I work in X".
        ExtractionRule(
            name: "location",
            regex: ExtractionRule.compiled(
                #"(?i)\bi\s{1,3}(?:live|work)\s{1,3}in\s{1,4}(?<value>[^,;:\n]{1,64})"#
            ),
            predicate: "location",
            confidence: 0.85,
            importanceDelta: 2,
            tags: ["core"]
        ),
        // constraint — "I'm allergic to X" / "I am unable to X". Highest
        // importance delta of the table: a constraint that is forgotten
        // is the failure mode with an actual cost attached.
        ExtractionRule(
            name: "constraint",
            regex: ExtractionRule.compiled(
                #"(?i)\bi(?:\s{1,3}am|['’]m)\s{1,3}(?:allergic to|unable to)\s{1,4}(?<value>[^,;:\n]{1,64})"#
            ),
            predicate: "constraint",
            confidence: 0.9,
            importanceDelta: 3,
            tags: ["core"]
        ),
    ]

    /// Rules that mark a sentence as a *retraction* and capture what is
    /// being retracted.
    ///
    /// These are a separate table because they compose rather than emit:
    /// the captured remainder is re-run through ``defaultRules``, so
    /// "forget that I live in Berlin" produces a `location` candidate
    /// tagged `retraction` — a candidate the reconciler can aim at the
    /// right slot — instead of an untargeted "forget something" record.
    /// When nothing in the value table fires on the remainder, the
    /// remainder itself is emitted under the `retraction` predicate so
    /// the intent is not silently dropped.
    ///
    /// Producing a retraction *candidate* is all that happens here.
    /// Deciding whether it retires anything is the reconciler's job, and
    /// the destructive path (purge) is reachable only from an explicit
    /// user or compliance call — never from a sentence.
    public static let defaultRetractionRules: [ExtractionRule] = [
        ExtractionRule(
            name: "retraction",
            regex: ExtractionRule.compiled(
                #"(?i)\b(?:forget (?:that|about)|delete|don['’]?t remember|do not remember)\s{1,4}(?<value>[^,;:\n]{1,80})"#
            ),
            predicate: "retraction",
            confidence: 0.9,
            importanceDelta: 0,
            tags: ["retraction"]
        ),
        ExtractionRule(
            name: "retraction-no-longer-true",
            regex: ExtractionRule.compiled(
                #"(?i)^(?<value>[^,;:\n]{1,80}?)\s{1,3}is no longer true$"#
            ),
            predicate: "retraction",
            confidence: 0.9,
            importanceDelta: 0,
            tags: ["retraction"]
        ),
    ]

    /// Sentence openers that mark a *correction*: the rest of the
    /// sentence is re-run through the value table and the result is
    /// tagged `correction`.
    ///
    /// This is a prefix test rather than an ``ExtractionRule`` because it
    /// captures a *remainder*, not a value — it decides how the rest of
    /// the sentence is interpreted rather than asserting anything itself.
    /// A correction that matches no value rule emits nothing: "actually,
    /// never mind" is not a claim.
    nonisolated(unsafe) public static let correctionPrefix: Regex<AnyRegexOutput> =
        ExtractionRule.compiled(#"(?i)^(?:actually|no,|that['’]s wrong|i meant)[\s,]{0,3}(?<rest>[^\n]{1,400})"#)
}
