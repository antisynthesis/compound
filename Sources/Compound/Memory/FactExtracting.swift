import Foundation

// The write path is **extractive, never generative**. Everything in this
// file exists to make that structural rather than aspirational: a span is
// located inside a real ``ConversationMessage``, carried around as a
// literal substring, and refuses to become a ``Fact`` unless it is still
// a literal substring of the evidence it names.
//
// The reason is narrow and load-bearing. The circuit-analysis result on
// small language models observes that routing tokens are syntactically
// valid either way — a 3B writer emits a perfectly well-formed record
// whether or not the claim inside it was ever said. A clean decode is
// therefore not evidence of correctness, and the only cheap check that
// *is* evidence is "these exact characters appear in the transcript".
// Enforcing that kills hallucinated memories at essentially zero cost,
// which is the single highest-value guard available to an on-device
// memory writer.

/// One candidate claim located inside a specific message, before it has
/// been turned into a ``FactCandidate``.
///
/// Spans are the unit an optional model pass is allowed to operate on.
/// A model may *select* spans and re-rate their importance; it may never
/// add one, edit one's text, or invent a subject. Keeping the selectable
/// unit a struct with a fixed text field is what makes that restriction
/// enforceable by validation rather than by prompt wording.
public struct FactSpan: Sendable, Equatable {
    /// Position of this span in the extractor's own output, assigned in
    /// deterministic `(message, sentence, rule)` order. Stable across
    /// re-runs over identical input, so it is safe to log or to key a
    /// decision on.
    ///
    /// Note that this is **not** the index a
    /// ``ModelFactExtractor/Selector`` addresses; that one is a position
    /// in the array handed to the selector. See
    /// ``FactSpanSelection/spanIndex``.
    public let index: Int
    /// Id of the ``ConversationMessage`` the span was taken from.
    public let messageID: UUID
    /// Normalized subject of the claim (`"user"` for the first-person
    /// rules that ship by default).
    public let subject: String
    /// Normalized predicate (`"name"`, `"prefers"`, `"location"`, …).
    public let predicate: String
    /// The claim, verbatim from the source message.
    public let text: String
    /// Name of the ``ExtractionRule`` that produced the span.
    public let ruleName: String
    /// Rule confidence in `[0, 1]`.
    public let confidence: Double
    /// Importance in `1...10`, already resolved from the rule delta, the
    /// origin, and any temporal signal.
    public let importance: Int
    /// Tags carried by the rule plus any structural tags the sentence
    /// earned (`"correction"`, `"retraction"`, `"temporal"`).
    public let tags: Set<String>
    /// Trust level implied by the message the span came from, capped by
    /// the rule's own ceiling.
    public let origin: MemoryOrigin

    /// Creates a span.
    ///
    /// - Precondition: `confidence` is in `[0, 1]`, `importance` is in
    ///   `1...10`, and `text` is non-empty.
    public init(
        index: Int,
        messageID: UUID,
        subject: String,
        predicate: String,
        text: String,
        ruleName: String,
        confidence: Double,
        importance: Int,
        tags: Set<String> = [],
        origin: MemoryOrigin = .userStated
    ) {
        precondition(confidence >= 0 && confidence <= 1, "confidence must be in [0, 1]")
        precondition(importance >= 1 && importance <= 10, "importance must be in 1...10")
        precondition(!text.isEmpty, "a fact span may not be empty")
        self.index = index
        self.messageID = messageID
        self.subject = subject
        self.predicate = predicate
        self.text = text
        self.ruleName = ruleName
        self.confidence = confidence
        self.importance = importance
        self.tags = tags
        self.origin = origin
    }
}

/// A claim an extractor proposes for storage, not yet reconciled against
/// what the store already holds.
///
/// A candidate is deliberately *not* a ``Fact``: it has no id, no
/// transaction time, and no supersession pointer, because those are
/// decided by the reconciler and the apply step. It carries only what the
/// evidence supports.
public struct FactCandidate: Sendable, Equatable {
    /// Thread the claim was learned in.
    public let threadID: String
    /// Who or what the claim is about.
    public let subject: String
    /// The relation being asserted.
    public let predicate: String
    /// The claim, verbatim from one of ``sourceMessageIDs``.
    public let text: String
    /// Trust level of the statement the claim came from.
    public let origin: MemoryOrigin
    /// Extraction confidence in `[0, 1]`.
    public let confidence: Double
    /// Importance in `1...10`.
    public let importance: Int
    /// Tags (`"core"`, `"preference"`, `"retraction"`, …).
    public let tags: Set<String>
    /// Ids of the messages the span was taken from, sorted ascending.
    public let sourceMessageIDs: [UUID]
    /// When the claim became true in the world.
    public let validFrom: Date
    /// Optional hard expiry to carry onto the stored record.
    public let expiresAt: Date?
    /// Name of the extractor that proposed the candidate.
    public let extractor: String

    /// The slot the candidate would occupy.
    public var slot: FactSlot {
        FactSlot(threadID: threadID, subject: subject, predicate: predicate)
    }

    /// The id the candidate would be stored under. Exposed because the
    /// reconciler's duplicate gate is exactly "does a live fact already
    /// have this id".
    public var derivedFactID: String {
        FactID.derive(threadID: threadID, subject: subject, predicate: predicate, text: text)
    }

    /// Creates a candidate.
    ///
    /// - Precondition: `confidence` is in `[0, 1]`, `importance` is in
    ///   `1...10`, `text` is non-empty, and `sourceMessageIDs` is
    ///   non-empty. The last one is the structural half of the verbatim
    ///   invariant: a claim with no evidence pointer can never be
    ///   re-checked against the transcript, so it is rejected at
    ///   construction rather than at storage time.
    public init(
        threadID: String,
        subject: String,
        predicate: String,
        text: String,
        origin: MemoryOrigin,
        confidence: Double,
        importance: Int,
        tags: Set<String> = [],
        sourceMessageIDs: [UUID],
        validFrom: Date,
        expiresAt: Date? = nil,
        extractor: String
    ) {
        precondition(confidence >= 0 && confidence <= 1, "confidence must be in [0, 1]")
        precondition(importance >= 1 && importance <= 10, "importance must be in 1...10")
        precondition(!text.isEmpty, "a fact candidate may not have empty text")
        precondition(!sourceMessageIDs.isEmpty, "a fact candidate must name at least one source message")
        self.threadID = threadID
        self.subject = subject
        self.predicate = predicate
        self.text = text
        self.origin = origin
        self.confidence = confidence
        self.importance = importance
        self.tags = tags
        self.sourceMessageIDs = sourceMessageIDs.sorted { $0.uuidString < $1.uuidString }
        self.validFrom = validFrom
        self.expiresAt = expiresAt
        self.extractor = extractor
    }

    /// Builds the ``Fact`` this candidate becomes when admitted.
    ///
    /// The record is always *new*: the id is derived from the thread,
    /// slot, and text, and `validUntil` and `invalidatedAt` are `nil`.
    /// Re-deriving rather than carrying an id is the whole point of the
    /// supersession model — different text is a different record, so a
    /// correction never mutates history in place.
    ///
    /// `supersedes` names the outgoing record when this candidate is
    /// replacing one, and defaults to `nil`. It is a *reconciliation*
    /// concept, not an extraction one: an extractor produces candidates
    /// with no knowledge of what is already stored and must always leave
    /// it `nil`. Only `Reconciliation.apply`, which decided which
    /// incumbent is being replaced, passes it. It lives here rather than
    /// in a parallel builder so there is exactly one definition of how a
    /// candidate becomes a record; a second copy could drift from this
    /// one field by field without any test noticing.
    ///
    /// `lastAccessedAt` starts at `recordedAt` and `accessCount` at zero,
    /// so a brand-new fact is maximally recent and has never been used —
    /// which is what ``SalienceScorer`` expects.
    ///
    /// This overload cannot check the verbatim invariant, because a
    /// candidate carries message *ids*, not message text. The check is
    /// enforced in three other places instead: the preconditions above,
    /// ``makeFact(recordedAt:verifiedAgainst:)`` for callers that hold the
    /// evidence, and `MemoryConsolidator`'s re-verification on the write
    /// path, which is the one that actually gates storage.
    public func makeFact(recordedAt: Date, supersedes: String? = nil) -> Fact {
        Fact(
            threadID: threadID,
            subject: subject,
            predicate: predicate,
            text: text,
            origin: origin,
            confidence: confidence,
            importance: importance,
            tags: tags,
            provenance: FactProvenance(
                threadID: threadID,
                messageIDs: sourceMessageIDs,
                extractor: extractor
            ),
            validFrom: validFrom,
            validUntil: nil,
            recordedAt: recordedAt,
            invalidatedAt: nil,
            expiresAt: expiresAt,
            supersedes: supersedes,
            lastAccessedAt: recordedAt,
            accessCount: 0
        )
    }

    /// Whether ``text`` is still a literal substring of one of the
    /// messages this candidate names as its evidence.
    ///
    /// Messages that are not named by ``sourceMessageIDs`` do not count:
    /// a span that happens to appear somewhere else in the transcript is
    /// not evidence for *this* record's provenance, and accepting it
    /// would make the provenance pointer decorative.
    public func isVerbatim(in messages: [ConversationMessage]) -> Bool {
        let named = Set(sourceMessageIDs)
        for message in messages where named.contains(message.id) {
            if MemoryText.isVerbatimSpan(text, of: message.content) { return true }
        }
        return false
    }

    /// Builds the ``Fact``, re-checking the verbatim invariant against
    /// the supplied evidence first.
    ///
    /// - Throws: ``MemoryError/invalidDecision(reason:)`` when ``text``
    ///   is not a literal substring of any named source message. This is
    ///   the guard a write path calls; it is a throw rather than a trap
    ///   because a model-selected span failing it is an expected runtime
    ///   event, not a programming error.
    public func makeFact(recordedAt: Date, verifiedAgainst messages: [ConversationMessage]) throws -> Fact {
        guard isVerbatim(in: messages) else {
            throw MemoryError.invalidDecision(
                reason: "candidate text is not a verbatim span of any source message (\(predicate)@\(subject))"
            )
        }
        return makeFact(recordedAt: recordedAt)
    }
}

/// Inputs an extractor needs that are not part of the turn itself.
///
/// `now` is injected rather than read, for the same reason it is injected
/// everywhere else in the memory layer: a candidate's `validFrom` is part
/// of the reconciler's total order, so an extractor that called `Date()`
/// would make reconciliation irreproducible and the evals
/// non-deterministic.
public struct ExtractionContext: Sendable {
    /// Thread the turn belongs to.
    public let threadID: String
    /// Instant the turn is being extracted "as of". Becomes every
    /// candidate's `validFrom`.
    public let now: Date
    /// Upper bound on candidates returned from one turn. Truncation
    /// keeps the *earliest* candidates, so a user who buries a fact under
    /// a wall of text loses the tail, not the opening.
    public let maxCandidates: Int
    /// Redactors applied as a **rejection filter**, not a transform.
    ///
    /// If any redactor changes a candidate's text, the candidate is
    /// dropped rather than stored redacted. Two reasons, both structural:
    /// a redacted span is no longer a verbatim span, so the invariant
    /// this whole file exists to enforce would be void; and a claim that
    /// contains a secret should not be persisted at all, in any form.
    /// `MemoryConsolidator` applies the same rule again on the write
    /// path — this copy makes a standalone extractor safe by itself.
    public let redactors: [any Redactor]

    /// Creates an extraction context.
    ///
    /// - Precondition: `maxCandidates` is non-negative.
    public init(
        threadID: String,
        now: Date,
        maxCandidates: Int = 8,
        redactors: [any Redactor] = []
    ) {
        precondition(maxCandidates >= 0, "maxCandidates must be non-negative")
        self.threadID = threadID
        self.now = now
        self.maxCandidates = maxCandidates
        self.redactors = redactors
    }
}

/// Turns a completed exchange into candidate claims.
///
/// Conformers must be **deterministic given their inputs** wherever the
/// underlying signal allows it: the same turn, the same context, and the
/// same `now` must produce the same candidates in the same order. The
/// reconciler's total order and the memory eval baseline both depend on
/// it, and a model-backed conformer that cannot guarantee it must fall
/// back to one that can (see ``ModelFactExtractor``).
public protocol FactExtracting: Sendable {
    /// Stable name recorded in every candidate's provenance.
    var name: String { get }
    /// Extracts candidates from `turn`.
    func extract(from turn: MemoryTurn, context: ExtractionContext) async throws -> [FactCandidate]
}
