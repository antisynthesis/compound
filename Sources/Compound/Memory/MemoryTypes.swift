import Foundation

/// Where a remembered claim came from, and how far it is trusted.
///
/// Provenance is the memory layer's first line of defence. Reported
/// memory-poisoning success rates against agent memory sit in the
/// 34–67% range, and the most vulnerable configuration is the one that
/// injects recalled content into the prompt with no notion of who said
/// it. Binding every ``Fact`` to an origin lets the write path hold
/// non-user statements to a higher confidence bar.
///
/// This is defence in depth and debuggability, **not** a validated
/// mitigation: an attacker who can make the user type a sentence still
/// gets ``userStated`` trust. Treat the rank as a cheap prior, not a
/// security boundary.
public enum MemoryOrigin: String, Sendable, Codable, CaseIterable, Equatable {
    /// The user said it in their own turn.
    case userStated
    /// The assistant said it.
    case assistantStated
    /// It came out of a tool result.
    case toolOutput
    /// It came out of a retrieved document.
    case retrievedDocument
    /// The system inferred it (reflection, summarization, aggregation).
    case derived

    /// Ordinal trust rank, higher is more trusted. Comparisons in the
    /// reconciler and in ``MemoryQuery/minimumOrigin`` are on this value,
    /// never on the case order of the enum, so adding a case later
    /// cannot silently reorder existing policy.
    public var trustRank: Int {
        switch self {
        case .userStated: 4
        case .assistantStated: 3
        case .toolOutput: 2
        case .retrievedDocument: 1
        case .derived: 0
        }
    }
}

/// The (thread, subject, predicate) address a ``Fact`` occupies.
///
/// A slot is the unit of contradiction: two live facts in the same slot
/// with different text are, by definition, a disagreement the reconciler
/// has to resolve. Subject and predicate are normalized through
/// ``MemoryText/normalize(_:)`` at construction, so "Work Email",
/// "work  email", and "work email" all name one slot.
public struct FactSlot: Sendable, Hashable, Codable {
    /// Conversation thread the slot belongs to. Threads are scoped
    /// through `RunContext.metadata`, not through `ConversationStore`.
    public let threadID: String
    /// Normalized subject ("user", "project-atlas", …).
    public let subject: String
    /// Normalized predicate ("name", "prefers", "location", …).
    public let predicate: String

    /// Creates a slot, normalizing `subject` and `predicate`.
    public init(threadID: String, subject: String, predicate: String) {
        self.threadID = threadID
        self.subject = MemoryText.normalize(subject)
        self.predicate = MemoryText.normalize(predicate)
    }
}

/// One completed user/assistant exchange, handed to the write path.
///
/// The turn carries both messages verbatim because the write path's
/// central invariant is that every stored span is a literal substring of
/// one of these messages. `recent` is optional surrounding context for
/// extractors that need it; it is never treated as a source of spans
/// unless an extractor says so explicitly.
public struct MemoryTurn: Sendable, Equatable {
    /// Thread the exchange belongs to.
    public let threadID: String
    /// The user's message.
    public let userMessage: ConversationMessage
    /// The assistant's reply.
    public let assistantMessage: ConversationMessage
    /// Recent preceding messages, oldest first.
    public let recent: [ConversationMessage]

    /// Creates a turn.
    public init(
        threadID: String,
        userMessage: ConversationMessage,
        assistantMessage: ConversationMessage,
        recent: [ConversationMessage] = []
    ) {
        self.threadID = threadID
        self.userMessage = userMessage
        self.assistantMessage = assistantMessage
        self.recent = recent
    }

    /// The messages a candidate span may legitimately have come from:
    /// the two turn messages plus `recent`, in a stable order.
    public var sourceMessages: [ConversationMessage] {
        recent + [userMessage, assistantMessage]
    }
}

/// Text canonicalization shared by every part of the memory layer.
///
/// ``normalize(_:)`` is the single definition of "the same thing
/// restated". Every id derivation, every slot address, and every
/// exact-match purge routes through it, so there is exactly one place to
/// look when two records that should have merged did not.
public enum MemoryText {
    /// Canonical form: NFC, lowercased, internal whitespace runs
    /// collapsed to a single space, leading/trailing whitespace trimmed.
    ///
    /// NFC comes first (via `precomposedStringWithCanonicalMapping`) so
    /// decomposed input from an IME lands on the same bytes as
    /// precomposed input from a keyboard — the same normalization
    /// ``DocumentChunker/chunkID(documentID:ordinal:content:)`` and
    /// ``BM25Retriever/defaultTokenize`` apply.
    ///
    /// Lowercasing is unconditional and locale-independent (`lowercased()`
    /// with no locale) because a locale-sensitive fold would make stored
    /// ids depend on the device's region settings.
    public static func normalize(_ s: String) -> String {
        let folded = s.precomposedStringWithCanonicalMapping.lowercased()
        var out = ""
        out.reserveCapacity(folded.count)
        var pendingSpace = false
        var wroteAny = false
        for scalar in folded.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                pendingSpace = wroteAny
                continue
            }
            if pendingSpace {
                out.unicodeScalars.append(" ")
                pendingSpace = false
            }
            out.unicodeScalars.append(scalar)
            wroteAny = true
        }
        return out
    }

    /// Reports whether `span` occurs literally inside `message`.
    ///
    /// This is the guard that makes the write path extractive rather
    /// than generative: a model may *select* a span but may never author
    /// one, so a clean decode is never mistaken for a correct claim.
    /// Only Unicode normalization is applied (both sides are folded to
    /// NFC); case and whitespace are **not** normalized, because a span
    /// that differs in case or spacing from the message is no longer
    /// verbatim.
    ///
    /// An empty span is never a verbatim span — the empty string is a
    /// substring of everything, which would make the guard vacuous.
    public static func isVerbatimSpan(_ span: String, of message: String) -> Bool {
        guard !span.isEmpty else { return false }
        let needle = span.precomposedStringWithCanonicalMapping
        let haystack = message.precomposedStringWithCanonicalMapping
        return haystack.contains(needle)
    }
}

/// Failures the memory layer surfaces to callers.
///
/// Deliberately separate from ``CompoundError``: these are storage- and
/// schema-level faults that a host application handles differently from
/// a run failure (a corrupt store is a migration/repair problem, not a
/// retryable model problem).
public enum MemoryError: Error, Sendable, Equatable, CustomStringConvertible {
    /// A durable store exists on disk but could not be decoded.
    case corruptStore(path: String, detail: String)
    /// A durable store carries a schema version this build cannot read.
    case schemaVersionUnsupported(found: Int, supported: Int)
    /// An operation named a fact id the store does not hold.
    case unknownFact(id: String)
    /// A model-supplied or caller-supplied decision failed validation.
    case invalidDecision(reason: String)
    /// Archival removal reached some indexes but not others; the listed
    /// chunk ids remain retrievable through the failed indexes and are
    /// queued for retry.
    case partialRemoval(chunkIDs: [String], failedIndexes: [String])

    /// Human-readable description.
    public var description: String {
        switch self {
        case let .corruptStore(path, detail):
            "memory store at \(path) could not be decoded: \(detail)"
        case let .schemaVersionUnsupported(found, supported):
            "memory store schema version \(found) is not supported (this build reads \(supported))"
        case let .unknownFact(id):
            "no fact with id \(id)"
        case let .invalidDecision(reason):
            "invalid memory decision: \(reason)"
        case let .partialRemoval(chunkIDs, failedIndexes):
            "removal of \(chunkIDs.count) chunk(s) failed on indexes: \(failedIndexes.joined(separator: ", "))"
        }
    }
}
