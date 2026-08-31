import Foundation

/// Where a ``Fact`` came from, in enough detail to re-read the original
/// words.
///
/// Provenance is required, not optional. The 2026 agent-memory survey
/// names self-reinforcing error as the central risk of any memory that
/// writes derived claims, and the cheapest testable mitigation is a hard
/// requirement that every record points back at the messages it was
/// taken from. Both id arrays are stored sorted so the encoded form is
/// stable and two provenances built from the same evidence compare
/// equal regardless of discovery order.
public struct FactProvenance: Sendable, Equatable, Hashable, Codable {
    /// Thread the evidence lives in.
    public let threadID: String
    /// Ids of the ``ConversationMessage``s the span was taken from,
    /// sorted ascending by `uuidString`.
    public let messageIDs: [UUID]
    /// Ids of any archival rounds that also carry the evidence, sorted
    /// ascending. Populated once the source messages age out of the
    /// working window.
    public let archivalChunkIDs: [String]
    /// Name of the extractor that produced the record
    /// (`"deterministic.v1"`, `"model.v1"`, …).
    public let extractor: String

    /// Creates a provenance record, sorting both id arrays.
    public init(threadID: String, messageIDs: [UUID], archivalChunkIDs: [String] = [], extractor: String) {
        self.threadID = threadID
        self.messageIDs = messageIDs.sorted { $0.uuidString < $1.uuidString }
        self.archivalChunkIDs = archivalChunkIDs.sorted()
        self.extractor = extractor
    }
}

/// Deterministic identifier derivation for ``Fact``.
///
/// Fact ids share the 32-hex-character id space of ``DocumentChunk`` but
/// occupy a **disjoint region** of it: the derivation runs through
/// ``DocumentChunker/chunkID(documentID:ordinal:content:)`` with a
/// `documentID` that always carries the ``domain`` prefix, so no fact id
/// can collide with a chunk id for the same text. That matters because
/// ``HybridRetriever`` fuses by id — overlapping id spaces would let one
/// piece of content be credited twice in an RRF pool.
///
/// Ids are never minted from `UUID()`. The whole write path has to be
/// idempotent under a deferred background retry, which is only possible
/// if re-deriving from the same inputs reproduces the same id.
public enum FactID {
    /// Domain-separation tag mixed into every derived fact id. Bump the
    /// suffix if the derivation changes, so stored records can detect a
    /// mismatch instead of silently failing to join.
    public static let domain = "compound.memory.fact.v1"

    /// Derives the identifier for a fact.
    ///
    /// The address (`threadID`, subject, predicate) is folded into the
    /// `documentID` and the claim text into the content, both through
    /// ``MemoryText/normalize(_:)``. Consequences worth stating
    /// explicitly:
    ///
    /// - Restating the same claim with different case, spacing, or
    ///   Unicode normalization lands on the same id, so the reconciler
    ///   sees a duplicate rather than a contradiction.
    /// - Changing the claim text changes the id, so a correction is a
    ///   *new* record that supersedes the old one rather than an
    ///   in-place edit — which is what makes the bi-temporal history
    ///   answerable.
    public static func derive(threadID: String, subject: String, predicate: String, text: String) -> String {
        let documentID = [
            domain,
            threadID,
            MemoryText.normalize(subject),
            MemoryText.normalize(predicate),
        ].joined(separator: "|")
        return DocumentChunker.chunkID(
            documentID: documentID,
            ordinal: 0,
            content: MemoryText.normalize(text)
        )
    }
}

/// One small, structured, bi-temporal remembered claim.
///
/// The four dates are Zep's bi-temporal shape with the knowledge graph
/// deliberately left out:
///
/// - ``validFrom`` — when the claim became true in the world.
/// - ``validUntil`` — when it stopped being true (`nil` while it holds).
/// - ``recordedAt`` — when this system wrote it down.
/// - ``invalidatedAt`` — when this system retired it (`nil` while live).
///
/// Splitting world time from system time is what lets the store answer
/// "what did I believe in March" (see ``MemoryQuery/asOf``) instead of
/// only "what do I believe now". Supersession therefore *invalidates*
/// rather than deletes; the only destructive path in the whole layer is
/// ``MemoryStore/purge(ids:)`` and its predicate form.
///
/// `text` is always a verbatim span of a real message (see
/// ``MemoryText/isVerbatimSpan(_:of:)``). Nothing in the write path is
/// permitted to author claim text.
public struct Fact: Sendable, Equatable, Hashable, Identifiable, Codable {
    /// Deterministic identifier, derived by ``FactID/derive(threadID:subject:predicate:text:)``.
    public let id: String
    /// Thread the fact was learned in.
    public let threadID: String
    /// Who or what the claim is about.
    public let subject: String
    /// The relation being asserted.
    public let predicate: String
    /// The claim, verbatim from a source message.
    public let text: String
    /// Where the claim came from.
    public let origin: MemoryOrigin
    /// Extraction confidence in `[0, 1]`.
    public let confidence: Double
    /// Importance in `1...10`, Generative-Agents scale.
    public let importance: Int
    /// Free-form tags (`"core"`, `"preference"`, `"retraction"`, …).
    public let tags: Set<String>
    /// Pointer back to the evidence.
    public let provenance: FactProvenance
    /// When the claim became true.
    public let validFrom: Date
    /// When the claim stopped being true, `nil` while it holds.
    public let validUntil: Date?
    /// When the system wrote the record.
    public let recordedAt: Date
    /// When the system retired the record, `nil` while live.
    public let invalidatedAt: Date?
    /// Optional hard expiry independent of invalidation.
    public let expiresAt: Date?
    /// Id of the fact this one replaced, if any.
    public let supersedes: String?
    /// Last time the record was recalled or reconfirmed. Drives the
    /// recency term in ``SalienceScorer`` so salience reflects *use*,
    /// not only creation.
    public let lastAccessedAt: Date
    /// Number of times the record has been touched.
    public let accessCount: Int

    /// The (thread, subject, predicate) address this fact occupies.
    public var slot: FactSlot {
        FactSlot(threadID: threadID, subject: subject, predicate: predicate)
    }

    /// Whether the record is believed at `instant`.
    ///
    /// Live means: never retired, still inside its validity window, not
    /// expired, and already in effect. The window comparisons are strict
    /// (`validUntil > instant`, `expiresAt > instant`) so a fact that
    /// stops being true *at* `instant` is already gone at `instant` —
    /// the same half-open convention supersession uses when it sets the
    /// outgoing record's `validUntil` to the incoming record's
    /// `validFrom`, which keeps the two from being simultaneously live
    /// for one instant.
    public func isLive(at instant: Date) -> Bool {
        guard invalidatedAt == nil else { return false }
        return wasValid(at: instant)
    }

    /// Whether the claim was **true in the world** at `instant`,
    /// ignoring whether the system has since retired the record.
    ///
    /// This is the validity-time half of ``isLive(at:)`` on its own, and
    /// it is what ``MemoryQuery/asOf`` evaluates. The distinction is the
    /// entire point of keeping two time axes: `invalidatedAt` is
    /// transaction time — *when this system stopped asserting the
    /// record* — so folding it into a validity-time question would make
    /// "what did I believe in March" return nothing at all the moment a
    /// claim was ever superseded, which is exactly the history the
    /// bi-temporal shape exists to preserve.
    ///
    /// A record retired without a `validUntil` (a plain retraction)
    /// therefore still answers "yes" for instants inside its window. That
    /// is the correct answer to the validity-time question: the user did
    /// believe it then, and later asked to forget it.
    public func wasValid(at instant: Date) -> Bool {
        if let validUntil, validUntil <= instant { return false }
        if let expiresAt, expiresAt <= instant { return false }
        return validFrom <= instant
    }

    /// Creates a fact.
    ///
    /// - Parameter id: Explicit identifier. When `nil` (the default) it
    ///   is derived from the thread, slot, and text, which is what every
    ///   in-tree caller does. Pass a value only when re-hydrating a
    ///   record whose id was derived by an older revision.
    /// - Precondition: `confidence` is in `[0, 1]` and `importance` is
    ///   in `1...10`.
    public init(
        id: String? = nil,
        threadID: String,
        subject: String,
        predicate: String,
        text: String,
        origin: MemoryOrigin,
        confidence: Double,
        importance: Int,
        tags: Set<String> = [],
        provenance: FactProvenance,
        validFrom: Date,
        validUntil: Date? = nil,
        recordedAt: Date,
        invalidatedAt: Date? = nil,
        expiresAt: Date? = nil,
        supersedes: String? = nil,
        lastAccessedAt: Date,
        accessCount: Int = 0
    ) {
        precondition(confidence >= 0 && confidence <= 1, "confidence must be in [0, 1]")
        precondition(importance >= 1 && importance <= 10, "importance must be in 1...10")
        self.id = id ?? FactID.derive(threadID: threadID, subject: subject, predicate: predicate, text: text)
        self.threadID = threadID
        self.subject = subject
        self.predicate = predicate
        self.text = text
        self.origin = origin
        self.confidence = confidence
        self.importance = importance
        self.tags = tags
        self.provenance = provenance
        self.validFrom = validFrom
        self.validUntil = validUntil
        self.recordedAt = recordedAt
        self.invalidatedAt = invalidatedAt
        self.expiresAt = expiresAt
        self.supersedes = supersedes
        self.lastAccessedAt = lastAccessedAt
        self.accessCount = accessCount
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, threadID, subject, predicate, text, origin, confidence, importance
        case tags, provenance, validFrom, validUntil, recordedAt, invalidatedAt
        case expiresAt, supersedes, lastAccessedAt, accessCount
    }

    /// Encodes the record. `tags` is written as a **sorted** array
    /// rather than the synthesized set encoding, because `Set` iteration
    /// order is unspecified and a durable snapshot has to be
    /// byte-stable: an unsorted tag array would make an otherwise
    /// unchanged store produce a different file on every rewrite.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(threadID, forKey: .threadID)
        try c.encode(subject, forKey: .subject)
        try c.encode(predicate, forKey: .predicate)
        try c.encode(text, forKey: .text)
        try c.encode(origin, forKey: .origin)
        try c.encode(confidence, forKey: .confidence)
        try c.encode(importance, forKey: .importance)
        try c.encode(tags.sorted(), forKey: .tags)
        try c.encode(provenance, forKey: .provenance)
        try c.encode(validFrom, forKey: .validFrom)
        try c.encodeIfPresent(validUntil, forKey: .validUntil)
        try c.encode(recordedAt, forKey: .recordedAt)
        try c.encodeIfPresent(invalidatedAt, forKey: .invalidatedAt)
        try c.encodeIfPresent(expiresAt, forKey: .expiresAt)
        try c.encodeIfPresent(supersedes, forKey: .supersedes)
        try c.encode(lastAccessedAt, forKey: .lastAccessedAt)
        try c.encode(accessCount, forKey: .accessCount)
    }

    /// Decodes a record.
    ///
    /// Range violations on `confidence` and `importance` are thrown as
    /// `DecodingError.dataCorruptedError` rather than trapped: a
    /// hand-edited or truncated file is a recoverable storage fault that
    /// ``FileFactStore`` reports as ``MemoryError/corruptStore(path:detail:)``,
    /// and trapping would take the host process down over someone else's
    /// bad bytes. The in-memory `init` still traps, because a
    /// programming error deserves a trap.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        threadID = try c.decode(String.self, forKey: .threadID)
        subject = try c.decode(String.self, forKey: .subject)
        predicate = try c.decode(String.self, forKey: .predicate)
        text = try c.decode(String.self, forKey: .text)
        origin = try c.decode(MemoryOrigin.self, forKey: .origin)
        let confidence = try c.decode(Double.self, forKey: .confidence)
        guard confidence >= 0, confidence <= 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .confidence, in: c,
                debugDescription: "confidence \(confidence) is outside [0, 1]"
            )
        }
        self.confidence = confidence
        let importance = try c.decode(Int.self, forKey: .importance)
        guard importance >= 1, importance <= 10 else {
            throw DecodingError.dataCorruptedError(
                forKey: .importance, in: c,
                debugDescription: "importance \(importance) is outside 1...10"
            )
        }
        self.importance = importance
        tags = Set(try c.decodeIfPresent([String].self, forKey: .tags) ?? [])
        provenance = try c.decode(FactProvenance.self, forKey: .provenance)
        validFrom = try c.decode(Date.self, forKey: .validFrom)
        validUntil = try c.decodeIfPresent(Date.self, forKey: .validUntil)
        recordedAt = try c.decode(Date.self, forKey: .recordedAt)
        invalidatedAt = try c.decodeIfPresent(Date.self, forKey: .invalidatedAt)
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
        supersedes = try c.decodeIfPresent(String.self, forKey: .supersedes)
        lastAccessedAt = try c.decode(Date.self, forKey: .lastAccessedAt)
        accessCount = try c.decode(Int.self, forKey: .accessCount)
    }

    // MARK: - Derivation helpers

    /// Returns a copy with the supplied fields replaced. Used by the
    /// stores for `touch` and `invalidate`; `Fact` is otherwise
    /// immutable so a record can never be mutated in place behind a
    /// caller's back.
    ///
    /// The id is carried over verbatim: none of the fields this helper
    /// can change participate in id derivation, so re-deriving would be
    /// a no-op — but carrying it explicitly documents that a lifecycle
    /// update never renames a record.
    func with(
        validUntil: Date?? = nil,
        invalidatedAt: Date?? = nil,
        expiresAt: Date?? = nil,
        confidence: Double? = nil,
        lastAccessedAt: Date? = nil,
        accessCount: Int? = nil
    ) -> Fact {
        Fact(
            id: id,
            threadID: threadID,
            subject: subject,
            predicate: predicate,
            text: text,
            origin: origin,
            confidence: confidence ?? self.confidence,
            importance: importance,
            tags: tags,
            provenance: provenance,
            validFrom: validFrom,
            validUntil: validUntil ?? self.validUntil,
            recordedAt: recordedAt,
            invalidatedAt: invalidatedAt ?? self.invalidatedAt,
            expiresAt: expiresAt ?? self.expiresAt,
            supersedes: supersedes,
            lastAccessedAt: lastAccessedAt ?? self.lastAccessedAt,
            accessCount: accessCount ?? self.accessCount
        )
    }
}
