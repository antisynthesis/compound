import Foundation

/// Rule-based, model-free fact extraction. This is the product; the
/// model-backed ``ModelFactExtractor`` is an optional narrowing pass on
/// top of it.
///
/// Everything here is a pure function of the turn, the rule table, and
/// the injected `now`. That buys three things the memory layer cannot do
/// without:
///
/// - **Reproducibility.** The reconciler's contradiction resolution is a
///   total order over candidate fields, and the memory eval gates on a
///   committed baseline. Both break the moment extraction can return
///   different candidates for the same input.
/// - **Availability.** A default that needs a model is a default that
///   fails on an ineligible device or a cold model session. The write
///   path degrades to *no* model call, not to no memory.
/// - **Safety.** A rule can decide *that* something was asserted and
///   *which relation* it asserts, but the claim text always comes out of
///   the user's own sentence. There is no code path here that composes
///   text, so there is no code path that can be talked into composing it.
///
/// ### Processing order
///
/// Fully determined, and worth stating because span order is the
/// tie-break everything downstream inherits:
///
/// 1. Messages in source order — the user message, then the assistant
///    message only when ``extractsAssistantMessage`` is on.
/// 2. Sentences in order, split on `.`, `!`, `?`, and newlines.
/// 3. Per sentence: unwrap a correction opener, then a retraction
///    wrapper, then evaluate the value table in order, taking each
///    rule's first match.
///
/// Candidates whose ``FactID`` would collide are deduplicated keeping the
/// first, then the list is truncated to ``ExtractionContext/maxCandidates``
/// from the tail — a user who buries a fact under a wall of text loses
/// the end of the wall, not the opening sentence.
///
/// ### Who gets extracted from
///
/// Only the user message, by default. The assistant message is opt-in and
/// its candidates carry ``MemoryOrigin/assistantStated``, which the
/// reconciler holds to a much higher confidence bar. The memory-poisoning
/// literature is explicit that permissive write policies are what made
/// one evaluated agent 66.67% attackable; writing down whatever the model
/// just said, at user trust, is exactly that policy.
///
/// Marked `@unchecked Sendable` for the reason ``ExtractionRule`` is:
/// `Regex<AnyRegexOutput>` is not formally `Sendable`, all stored state is
/// immutable, and matching is safe to share across actors.
public struct DeterministicFactExtractor: FactExtracting, @unchecked Sendable {
    /// The value table, evaluated in order.
    public let rules: [ExtractionRule]
    /// Retraction wrappers, evaluated before the value table.
    public let retractionRules: [ExtractionRule]
    /// Whether the assistant's message is also extracted from. Off by
    /// default; see the type's discussion.
    public let extractsAssistantMessage: Bool

    /// Stable extractor name, recorded in every candidate's provenance.
    public let name = "deterministic.v1"

    /// Creates an extractor.
    ///
    /// - Parameters:
    ///   - rules: The value table. Order is meaningful — it decides span
    ///     emission order and which rule wins a deduplication.
    ///   - retractionRules: Wrappers that mark a sentence as a
    ///     retraction and capture what is being retracted.
    ///   - extractsAssistantMessage: Opt in to extracting from the
    ///     assistant turn.
    public init(
        rules: [ExtractionRule] = DeterministicFactExtractor.defaultRules,
        retractionRules: [ExtractionRule] = DeterministicFactExtractor.defaultRetractionRules,
        extractsAssistantMessage: Bool = false
    ) {
        self.rules = rules
        self.retractionRules = retractionRules
        self.extractsAssistantMessage = extractsAssistantMessage
    }

    // MARK: - Spans

    /// Locates every span the rule table finds in `turn`, in deterministic
    /// order.
    ///
    /// Exposed separately from ``extract(from:context:)`` because it is
    /// the unit ``ModelFactExtractor`` narrows: a model selects from this
    /// list rather than producing one of its own.
    ///
    /// The list is **not** truncated to
    /// ``ExtractionContext/maxCandidates`` and is **not** deduplicated —
    /// both happen when spans become candidates, so a narrowing pass sees
    /// everything the rules found.
    public func spans(in turn: MemoryTurn, context _: ExtractionContext) -> [FactSpan] {
        let detector = Self.makeDateDetector()
        var out: [FactSpan] = []
        for message in sourceMessages(of: turn) {
            let roleOrigin = Self.origin(for: message.role)
            for sentence in Self.sentences(of: message.content) {
                appendSpans(
                    for: sentence,
                    messageID: message.id,
                    roleOrigin: roleOrigin,
                    detector: detector,
                    into: &out
                )
            }
        }
        return out
    }

    /// Extracts candidates from `turn`.
    public func extract(from turn: MemoryTurn, context: ExtractionContext) async throws -> [FactCandidate] {
        candidates(from: spans(in: turn, context: context), turn: turn, context: context)
    }

    /// Turns spans into candidates, applying the redaction rejection
    /// filter, the verbatim re-check, deduplication, and truncation.
    ///
    /// Shared with ``ModelFactExtractor`` so the two extractors cannot
    /// drift on any of those four rules.
    func candidates(
        from spans: [FactSpan],
        turn: MemoryTurn,
        context: ExtractionContext,
        extractorName: String? = nil
    ) -> [FactCandidate] {
        guard context.maxCandidates > 0 else { return [] }
        let evidence = turn.sourceMessages
        var seen: Set<String> = []
        var out: [FactCandidate] = []
        for span in spans {
            // Redaction runs on the way IN, as a rejection filter. A
            // redacted span is no longer a verbatim span, so storing the
            // redacted form would void the invariant the whole write path
            // rests on — and a claim that contains a secret should not be
            // persisted in any form.
            var applied: [String] = []
            let scrubbed = runRedactors(context.redactors, on: span.text, applied: &applied)
            guard scrubbed == span.text else { continue }

            let candidate = FactCandidate(
                threadID: context.threadID,
                subject: span.subject,
                predicate: span.predicate,
                text: span.text,
                origin: span.origin,
                confidence: span.confidence,
                importance: span.importance,
                tags: span.tags,
                sourceMessageIDs: [span.messageID],
                validFrom: context.now,
                expiresAt: nil,
                extractor: extractorName ?? name
            )
            // Belt and braces: the rules only ever hand back substrings,
            // so this cannot fail for the deterministic path. It can fail
            // for a caller-supplied rule table whose pattern reconstructs
            // text, which is precisely the mistake worth catching here
            // rather than three layers downstream.
            guard candidate.isVerbatim(in: evidence) else { continue }

            let id = candidate.derivedFactID
            guard seen.insert(id).inserted else { continue }
            out.append(candidate)
            if out.count == context.maxCandidates { break }
        }
        return out
    }

    // MARK: - Per-sentence pipeline

    private func appendSpans(
        for sentence: Substring,
        messageID: UUID,
        roleOrigin: MemoryOrigin,
        detector: NSDataDetector?,
        into out: inout [FactSpan]
    ) {
        // Temporal is a *modifier*, never a rule of its own: a sentence
        // containing a date but asserting nothing produces no candidate.
        // Detection is presence-only, which is a pure function of the
        // text — resolving the date would not be, since NSDataDetector
        // interprets "tomorrow" against the current clock.
        let temporal = Self.containsDate(sentence, detector: detector)
        var extraTags: Set<String> = temporal ? ["temporal"] : []

        var text = sentence
        if let rest = Self.correctionRemainder(of: text) {
            extraTags.insert("correction")
            text = rest
        }

        if let (rule, capture) = firstMatch(in: text, rules: retractionRules) {
            extraTags.formUnion(rule.tags)
            let object = capture.value
            let before = out.count
            appendValueSpans(
                in: object[object.startIndex...],
                messageID: messageID,
                roleOrigin: roleOrigin,
                temporal: temporal,
                extraTags: extraTags,
                confidenceOverride: rule.confidence,
                into: &out
            )
            if out.count == before {
                // Nothing in the value table recognised the retracted
                // object, so the object itself is recorded under the
                // retraction predicate. Dropping it here would silently
                // discard an explicit "forget X".
                out.append(
                    makeSpan(
                        index: out.count,
                        messageID: messageID,
                        subject: "user",
                        predicate: rule.predicate,
                        text: object,
                        rule: rule,
                        roleOrigin: roleOrigin,
                        temporal: temporal,
                        extraTags: extraTags,
                        confidenceOverride: nil
                    )
                )
            }
            return
        }

        appendValueSpans(
            in: text,
            messageID: messageID,
            roleOrigin: roleOrigin,
            temporal: temporal,
            extraTags: extraTags,
            confidenceOverride: nil,
            into: &out
        )
    }

    private func appendValueSpans(
        in text: Substring,
        messageID: UUID,
        roleOrigin: MemoryOrigin,
        temporal: Bool,
        extraTags: Set<String>,
        confidenceOverride: Double?,
        into out: inout [FactSpan]
    ) {
        for rule in rules {
            guard let capture = rule.match(text) else { continue }
            out.append(
                makeSpan(
                    index: out.count,
                    messageID: messageID,
                    subject: capture.subject.map(MemoryText.normalize) ?? "user",
                    predicate: MemoryText.normalize(capture.predicate ?? rule.predicate),
                    text: capture.value,
                    rule: rule,
                    roleOrigin: roleOrigin,
                    temporal: temporal,
                    extraTags: extraTags,
                    confidenceOverride: confidenceOverride
                )
            )
        }
    }

    private func firstMatch(
        in text: Substring,
        rules: [ExtractionRule]
    ) -> (ExtractionRule, ExtractionRule.Capture)? {
        for rule in rules {
            if let capture = rule.match(text) { return (rule, capture) }
        }
        return nil
    }

    private func makeSpan(
        index: Int,
        messageID: UUID,
        subject: String,
        predicate: String,
        text: String,
        rule: ExtractionRule,
        roleOrigin: MemoryOrigin,
        temporal: Bool,
        extraTags: Set<String>,
        confidenceOverride: Double?
    ) -> FactSpan {
        // The rule's origin is a ceiling, not an assignment: a first-party
        // sentence cannot be trusted *more* than the rule allows, and a
        // rule cannot promote an assistant statement to user trust.
        let origin = roleOrigin.trustRank <= rule.origin.trustRank ? roleOrigin : rule.origin
        return FactSpan(
            index: index,
            messageID: messageID,
            subject: subject,
            predicate: predicate,
            text: text,
            ruleName: rule.name,
            confidence: confidenceOverride ?? rule.confidence,
            importance: Self.importance(rule: rule, origin: origin, temporal: temporal),
            tags: rule.tags.union(extraTags),
            origin: origin
        )
    }

    // MARK: - Scoring

    /// Resolves a span's importance on the Generative-Agents 1–10 scale.
    ///
    /// `5 + ruleDelta + trustAdjustment + temporalBonus`, clamped. The
    /// trust adjustment is deliberately asymmetric (+1 for a user
    /// statement, −2 for anything else): the cost of over-weighting
    /// something the *model* said is a self-reinforcing error loop, which
    /// the 2026 agent-memory survey names as the central risk of writing
    /// derived claims, while the cost of under-weighting it is one
    /// recall that has to come from the archive instead.
    static func importance(rule: ExtractionRule, origin: MemoryOrigin, temporal: Bool) -> Int {
        let raw = 5 + rule.importanceDelta + (origin == .userStated ? 1 : -2) + (temporal ? 1 : 0)
        return min(10, max(1, raw))
    }

    static func origin(for role: ConversationMessage.Role) -> MemoryOrigin {
        switch role {
        case .user: .userStated
        case .assistant: .assistantStated
        case .tool: .toolOutput
        case .system: .derived
        }
    }

    private func sourceMessages(of turn: MemoryTurn) -> [ConversationMessage] {
        extractsAssistantMessage ? [turn.userMessage, turn.assistantMessage] : [turn.userMessage]
    }

    // MARK: - Text utilities

    /// Splits `text` into sentences on `.`, `!`, `?`, and newlines,
    /// dropping the terminator and any empty pieces.
    ///
    /// Sentence granularity is what keeps a rule's value capture from
    /// running off the end of one claim into the next: the value
    /// character classes exclude clause punctuation, and the splitter
    /// handles the rest. It also means a rule fires at most once per
    /// sentence, which bounds how many records one message can write.
    static func sentences(of text: String) -> [Substring] {
        var out: [Substring] = []
        var start = text.startIndex
        var index = text.startIndex
        func flush(_ end: String.Index) {
            let piece = trimmed(text[start..<end])
            if !piece.isEmpty { out.append(piece) }
        }
        while index < text.endIndex {
            let character = text[index]
            if character == "." || character == "!" || character == "?" || character.isNewline {
                flush(index)
                start = text.index(after: index)
            }
            index = text.index(after: index)
        }
        if start < text.endIndex { flush(text.endIndex) }
        return out
    }

    /// Whitespace-trims a `Substring` without copying, so the result is
    /// still a slice of the original message and therefore still a
    /// verbatim span of it.
    static func trimmed(_ slice: Substring) -> Substring {
        var out = slice
        while let first = out.first, first.isWhitespace { out = out.dropFirst() }
        while let last = out.last, last.isWhitespace { out = out.dropLast() }
        return out
    }

    /// Returns the remainder of a sentence that opens with a correction
    /// marker, or `nil` when it does not.
    static func correctionRemainder(of sentence: Substring) -> Substring? {
        let text = String(sentence)
        guard let match = try? correctionPrefix.firstMatch(in: text) else { return nil }
        guard let rest = match.output["rest"]?.substring else { return nil }
        // Map the match back onto the caller's slice so the result stays
        // a slice of the original message rather than of a fresh String.
        let offset = text.distance(from: text.startIndex, to: rest.startIndex)
        guard offset <= sentence.count else { return nil }
        let start = sentence.index(sentence.startIndex, offsetBy: offset)
        let out = trimmed(sentence[start...])
        return out.isEmpty ? nil : out
    }

    static func makeDateDetector() -> NSDataDetector? {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
    }

    /// Whether `sentence` mentions a date at all. Presence only — the
    /// resolved value is never used, because `NSDataDetector` resolves
    /// relative expressions against the current clock and a
    /// clock-dependent tag would make extraction irreproducible.
    static func containsDate(_ sentence: Substring, detector: NSDataDetector?) -> Bool {
        guard let detector else { return false }
        let text = String(sentence)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.firstMatch(in: text, range: range) != nil
    }
}
