import Foundation

/// What a batch of decisions actually did to the store.
///
/// Returned by ``Reconciliation/apply(_:to:now:)`` and folded into the
/// consolidation trace. The rationale histogram is the part worth
/// keeping: raw counts say a pass wrote three facts, the histogram says
/// whether it wrote them because they were new or because a
/// low-confidence extractor kept losing coin flips.
public struct ReconciliationOutcome: Sendable, Equatable {
    /// Records inserted, in decision order.
    public let added: [Fact]
    /// Ids retired by a supersession.
    public let superseded: [String]
    /// Ids retired by a retraction.
    public let deleted: [String]
    /// Decisions that changed nothing (a touch is still a no-op).
    public let noops: Int
    /// How many decisions carried each rationale.
    public let byRationale: [MemoryRationale: Int]

    /// Creates an outcome.
    public init(
        added: [Fact],
        superseded: [String],
        deleted: [String],
        noops: Int,
        byRationale: [MemoryRationale: Int]
    ) {
        self.added = added
        self.superseded = superseded
        self.deleted = deleted
        self.noops = noops
        self.byRationale = byRationale
    }

    /// An outcome that did nothing.
    public static let empty = ReconciliationOutcome(
        added: [], superseded: [], deleted: [], noops: 0, byRationale: [:]
    )
}

/// Applies decisions to a store, and reads supersession history back out.
///
/// ## Why apply is separate from decide
///
/// ``FactReconciling`` conformers never write. Splitting the write out
/// here means every decision in a batch is computed against the same
/// pre-batch snapshot, so two candidates that both target the same
/// incumbent cannot chain-invalidate each other in an order that depends
/// on how the extractor happened to emit them.
///
/// ## Apply never purges
///
/// This is a hard rule, not a default. Contradiction handling and
/// compliance deletion do not share a code path: everything here
/// *invalidates*, which is recoverable and keeps provenance readable
/// through ``MemoryQuery/includeInvalidated`` and ``MemoryQuery/asOf``.
/// The only route to destruction is an explicit
/// ``MemoryStore/purge(ids:)`` or ``MemoryStore/purge(matching:)`` call
/// made by a user or a compliance action. A reconciler that could reach
/// `purge` would mean a mis-extracted correction could destroy history
/// that the bi-temporal shape exists to preserve.
public enum Reconciliation {
    /// Applies `decisions` and returns what changed.
    ///
    /// Write order, fixed and observable through a spy store:
    ///
    /// 1. Every new record (from `add` and `update`) is upserted in one
    ///    call, in decision order.
    /// 2. Supersession invalidations are issued, grouped by the
    ///    `validUntil` they carry, in first-appearance order.
    /// 3. Retraction invalidations are issued.
    /// 4. Reconfirmed duplicates are touched.
    ///
    /// Inserting before invalidating matters for crash safety rather than
    /// for semantics: if the process dies between the two, the store holds
    /// both the old and the new record — a visible, repairable
    /// contradiction — rather than a slot with nothing live in it.
    ///
    /// - Note: `update` sets the outgoing record's ``Fact/validUntil`` to
    ///   the incoming record's ``Fact/validFrom``. That is the rule that
    ///   makes "what did I believe in March" answerable: the two records'
    ///   validity windows abut exactly, with no gap and no instant where
    ///   both are live (the window comparison is strict).
    @discardableResult
    public static func apply(
        _ decisions: [MemoryDecision],
        to store: any MemoryStore,
        now: Date
    ) async throws -> ReconciliationOutcome {
        var inserts: [Fact] = []
        var added: [Fact] = []
        // Grouped by the `validUntil` each supersession imposes, keyed in
        // first-appearance order so the emitted call sequence is a
        // function of the decision list.
        var supersessionBoundary: [String: Date] = [:]
        var superseded: [String] = []
        var deletes: [String] = []
        var touches: [String] = []
        var noops = 0
        var byRationale: [MemoryRationale: Int] = [:]
        var insertedIDs: Set<String> = []

        for decision in decisions {
            byRationale[decision.rationale, default: 0] += 1
            switch decision.operation {
            case .add:
                let fact = decision.candidate.makeFact(recordedAt: now)
                if insertedIDs.insert(fact.id).inserted {
                    inserts.append(fact)
                    added.append(fact)
                }
            case .update:
                guard let targetID = decision.targetFactID else {
                    throw MemoryError.invalidDecision(reason: "update decision carries no targetFactID")
                }
                let fact = decision.candidate.makeFact(recordedAt: now, supersedes: targetID)
                if insertedIDs.insert(fact.id).inserted {
                    inserts.append(fact)
                    added.append(fact)
                }
                // A record is superseded at most once per batch, at the
                // *earliest* boundary any decision named — the instant it
                // genuinely stopped being the current belief. Taking the
                // minimum rather than the first-seen value makes the
                // result independent of the order the extractor happened
                // to emit two corrections in.
                let boundary = decision.candidate.validFrom
                if let existing = supersessionBoundary[targetID] {
                    supersessionBoundary[targetID] = min(existing, boundary)
                } else {
                    supersessionBoundary[targetID] = boundary
                    superseded.append(targetID)
                }
            case .delete:
                guard let targetID = decision.targetFactID else {
                    throw MemoryError.invalidDecision(reason: "delete decision carries no targetFactID")
                }
                if !deletes.contains(targetID) { deletes.append(targetID) }
            case .noop:
                noops += 1
                if decision.rationale == .duplicateOfCurrent, let targetID = decision.targetFactID,
                   !touches.contains(targetID) {
                    touches.append(targetID)
                }
            }
        }

        if !inserts.isEmpty {
            try await store.upsert(inserts)
        }
        // Grouped by boundary so a batch that retires several records at
        // the same instant issues one call, and emitted in the order the
        // targets first appeared so the call sequence is a function of
        // the decision list rather than of dictionary iteration.
        var emittedBoundaries: Set<Date> = []
        for targetID in superseded {
            guard let boundary = supersessionBoundary[targetID],
                  emittedBoundaries.insert(boundary).inserted else { continue }
            let ids = superseded.filter { supersessionBoundary[$0] == boundary }
            try await store.invalidate(ids: ids, validUntil: boundary, at: now, reason: .superseded)
        }
        if !deletes.isEmpty {
            // A retraction leaves the world-time window alone: the user is
            // saying "stop telling me this", not "this was never true".
            // Passing `nil` keeps `validUntil` untouched, so an `asOf`
            // query inside the original window still answers honestly.
            try await store.invalidate(ids: deletes, validUntil: nil, at: now, reason: .retracted)
        }
        if !touches.isEmpty {
            try await store.touch(ids: touches, at: now)
        }

        return ReconciliationOutcome(
            added: added,
            superseded: superseded,
            deleted: deletes,
            noops: noops,
            byRationale: byRationale
        )
    }

    /// Returns the supersession chain containing `id`, oldest first.
    ///
    /// A chain `A ← B ← C` (each record naming its predecessor in
    /// ``Fact/supersedes``) leaves exactly one live record, `C`; `A` and
    /// `B` remain readable only through ``MemoryQuery/includeInvalidated``
    /// or a ``MemoryQuery/asOf`` inside their windows. This helper walks
    /// the links in both directions so a debugger — or a drift eval — can
    /// see the whole history of one claim without reconstructing it from
    /// raw ids.
    ///
    /// Cycles are impossible through the normal write path (a record's
    /// predecessor always predates it), but the walk guards against them
    /// anyway: a hand-edited or migrated store must not be able to hang a
    /// diagnostic call.
    public static func chain(of id: String, in store: any MemoryStore) async throws -> [Fact] {
        guard let seed = try await store.fact(id: id) else { return [] }
        var seen: Set<String> = [seed.id]

        var ancestors: [Fact] = []
        var cursor = seed
        while let parentID = cursor.supersedes,
              !seen.contains(parentID),
              let parent = try await store.fact(id: parentID) {
            ancestors.append(parent)
            seen.insert(parentID)
            cursor = parent
        }

        // Successors are found by scan: `supersedes` points backwards
        // only, and adding a forward pointer would mean mutating a record
        // after it was written — which the immutable `Fact` shape and the
        // deterministic id derivation both exist to avoid.
        var successorsOf: [String: [Fact]] = [:]
        for factID in try await store.allIDs() {
            guard let fact = try await store.fact(id: factID), let parent = fact.supersedes else { continue }
            successorsOf[parent, default: []].append(fact)
        }
        var descendants: [Fact] = []
        var current = seed
        while let next = successorsOf[current.id]?.sorted(by: { $0.id < $1.id }).first,
              !seen.contains(next.id) {
            descendants.append(next)
            seen.insert(next.id)
            current = next
        }

        return ancestors.reversed() + [seed] + descendants
    }
}
