import Foundation

// The write path's decision vocabulary.
//
// The four operations are Mem0's ADD / UPDATE / DELETE / NOOP. What is
// *not* adopted is the two-model-calls-per-turn pipeline built around
// them: that design's extraction prompt is a rolling summary plus the
// last ten messages plus the new pair, which routinely exceeds a
// 4096-token on-device window before a single fact has been produced.
// Compound keeps the vocabulary and makes the routing deterministic, so
// the default configuration spends zero model calls deciding what to
// remember.

/// What the write path does with one candidate fact.
///
/// The set is deliberately closed and small. Anything a memory system
/// wants to do to a claim — assert it, correct it, retract it, or leave
/// the store alone — is one of these four, and keeping it that way is
/// what makes a model-backed router a bounded discrete choice rather
/// than open-ended generation.
public enum MemoryOperation: String, Sendable, Equatable, Codable, CaseIterable {
    /// Insert the candidate as a new record.
    case add
    /// Insert the candidate and supersede an existing record with it.
    case update
    /// Retire an existing record without inserting anything.
    case delete
    /// Leave the store unchanged (possibly touching a reconfirmed record).
    case noop
}

/// Why a ``MemoryDecision`` came out the way it did.
///
/// Every decision carries one. Without it, "why is this fact gone" is
/// unanswerable after the fact, and a memory layer that cannot answer
/// that question is one nobody can debug or trust. The values are also
/// aggregated into ``ReconciliationOutcome/byRationale`` so a trace can
/// report the *shape* of a consolidation pass, not just its counts.
public enum MemoryRationale: String, Sendable, Equatable, Codable, CaseIterable {
    /// Nothing comparable was already stored.
    case noSimilarFact
    /// An identical live record already exists; it was reconfirmed.
    case duplicateOfCurrent
    /// The slot already holds a conflicting record and nothing separated
    /// the two — the incumbent wins.
    case slotContradiction
    /// The candidate became true more recently than the incumbent.
    case newerWins
    /// The candidate became true *before* the incumbent; it is old news.
    case staleCandidate
    /// Same validity instant, decided on extraction confidence.
    case higherConfidenceWins
    /// Same validity instant and confidence, decided on origin trust.
    case higherTrustWins
    /// The user asked for something to be forgotten.
    case retractionRequested
    /// The candidate's origin was not trusted enough to write.
    case lowerTrustRejected
    /// The candidate's confidence was below the admission floor.
    case belowConfidenceFloor
    /// The candidate's text was not a verbatim span of its own sources.
    /// Recorded by the consolidator, not by the reconciler.
    case nonVerbatimSpan
    /// A redactor changed the candidate's text, so it is no longer a
    /// verbatim span and is rejected rather than stored redacted.
    /// Recorded by the consolidator, not by the reconciler.
    case redactionFired
    /// A model hook chose this route from a bounded option list.
    case modelRouted
    /// A model hook proposed a route that failed validation, or failed
    /// outright; the deterministic decision stands.
    case modelRejected
}

/// One resolved candidate: what to do, to what, and why.
///
/// A decision is inert — producing it changes nothing. ``Reconciliation``
/// applies a batch of them in a second, separate step, which is what
/// lets the routing logic be a pure function that tests can enumerate
/// without a store mutation in sight.
public struct MemoryDecision: Sendable, Equatable {
    /// The operation to perform.
    public let operation: MemoryOperation
    /// The candidate the decision is about.
    public let candidate: FactCandidate
    /// Existing record the operation targets. Required for ``MemoryOperation/update``
    /// and ``MemoryOperation/delete``; `nil` otherwise, except on a
    /// ``MemoryRationale/duplicateOfCurrent`` no-op, where it names the
    /// record to touch.
    public let targetFactID: String?
    /// Why this operation and not another.
    public let rationale: MemoryRationale
    /// Name of the component that decided (`"deterministic.v1"`,
    /// `"model-mutation.v1"`, …).
    public let decidedBy: String

    /// Creates a decision.
    public init(
        operation: MemoryOperation,
        candidate: FactCandidate,
        targetFactID: String? = nil,
        rationale: MemoryRationale,
        decidedBy: String
    ) {
        self.operation = operation
        self.candidate = candidate
        self.targetFactID = targetFactID
        self.rationale = rationale
        self.decidedBy = decidedBy
    }

    /// Returns a copy with a different rationale and decider, preserving
    /// the operation and target. Used when a model hook declines to
    /// override a deterministic decision but wants the trace to record
    /// that it looked.
    func relabeled(rationale: MemoryRationale, decidedBy: String) -> MemoryDecision {
        MemoryDecision(
            operation: operation,
            candidate: candidate,
            targetFactID: targetFactID,
            rationale: rationale,
            decidedBy: decidedBy
        )
    }
}

/// Routes candidate facts against what is already stored.
///
/// Conformers **must not mutate the store**. Reconciliation is a read
/// and a decision; ``Reconciliation/apply(_:to:now:)`` is the write. The
/// split exists for three reasons: a pure decision function can be
/// property-tested over sequences of candidates without a store rebuild
/// between runs, a batch can be applied atomically from a single
/// pre-batch snapshot, and a model-backed router can be layered on top
/// (see ``ModelMutationHook``) without ever being handed write access.
///
/// Conformers must also be **deterministic** given the same candidates,
/// the same store contents, and the same `now`. The eval harness and the
/// golden baseline both assume that re-running a consolidation over an
/// unchanged store reproduces the same decisions in the same order,
/// including the same rationales.
public protocol FactReconciling: Sendable {
    /// Stable identifier recorded in ``MemoryDecision/decidedBy``.
    var name: String { get }
    /// Returns one decision per candidate, in candidate order.
    func reconcile(candidates: [FactCandidate], against store: any MemoryStore, now: Date) async throws -> [MemoryDecision]
}
