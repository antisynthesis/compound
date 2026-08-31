import Foundation

/// Rules for retiring records that nothing contradicted.
///
/// ## What this is, honestly
///
/// TTLs, half-lives, and salience eviction are **engineering
/// convention, not validated cognitive science.** The 2026 agent-memory
/// survey calls the field's forgetting mechanisms crude and names
/// learned forgetting an open problem; nothing here closes it. A
/// half-life is a knob someone picked.
///
/// That is precisely why forgetting ships as an explicit, inspectable,
/// deterministically tested policy object rather than as behaviour
/// buried in a store. Every rule is a value the host application can
/// read, show a user, override, or turn off, and ``ForgettingSweep`` is
/// a pure function of the policy, the store contents, and an injected
/// `now`. An arbitrary rule that is visible and reproducible is
/// defensible; the same rule hidden inside an actor is not.
///
/// Every rule here **invalidates**. Nothing in this file can destroy a
/// record — see ``MemoryStore/purge(matching:)`` for the deliberately
/// separate compliance path.
public struct ForgettingPolicy: Sendable, Equatable, Codable {
    /// Lifetime applied to a record carrying no matching tag. `nil`
    /// means records do not expire on age alone.
    public var defaultTimeToLive: Duration?
    /// Per-tag lifetimes. When a record carries several matching tags the
    /// **smallest** lifetime wins, so tagging a fact `"ephemeral"` can
    /// only ever shorten its life, never extend it.
    public var timeToLiveByTag: [String: Duration]
    /// Lifetime for a ``MemoryOrigin/derived`` record measured from its
    /// last access rather than from when it was written.
    ///
    /// This is the survey's "expiration of unvalidated reflections" in
    /// its cheapest form: a claim the system inferred rather than heard,
    /// which nothing has since recalled or reconfirmed, is the exact
    /// shape self-reinforcing error takes, and letting it lapse costs
    /// nothing when the inference was worthless.
    public var unreconfirmedDerivedTimeToLive: Duration?
    /// Confidence below which a decayed record is retired.
    public var minimumRetainedConfidence: Double
    /// Cap on simultaneously live records per thread. `nil` means no cap.
    public var maxLiveFactsPerThread: Int?
    /// Half-life for confidence decay. `nil` disables decay entirely.
    public var confidenceDecayHalfLife: Duration?

    /// Creates a policy.
    public init(
        defaultTimeToLive: Duration? = nil,
        timeToLiveByTag: [String: Duration] = [:],
        unreconfirmedDerivedTimeToLive: Duration? = nil,
        minimumRetainedConfidence: Double = 0.2,
        maxLiveFactsPerThread: Int? = nil,
        confidenceDecayHalfLife: Duration? = nil
    ) {
        precondition(
            minimumRetainedConfidence >= 0 && minimumRetainedConfidence <= 1,
            "minimumRetainedConfidence must be in [0, 1]"
        )
        self.defaultTimeToLive = defaultTimeToLive
        self.timeToLiveByTag = timeToLiveByTag
        self.unreconfirmedDerivedTimeToLive = unreconfirmedDerivedTimeToLive
        self.minimumRetainedConfidence = minimumRetainedConfidence
        self.maxLiveFactsPerThread = maxLiveFactsPerThread
        self.confidenceDecayHalfLife = confidenceDecayHalfLife
    }

    /// The shipped default: conservative, and deliberately so.
    ///
    /// Nothing a user *said* ever expires on age alone — no
    /// `defaultTimeToLive`, no decay, no per-thread cap. The single
    /// active rule retires derived records that have gone thirty days
    /// without being recalled, because those are the ones with no human
    /// behind them. Turning on aggressive forgetting is a decision a host
    /// application makes on purpose, not one it inherits.
    public static let `default` = ForgettingPolicy(
        defaultTimeToLive: nil,
        timeToLiveByTag: [:],
        unreconfirmedDerivedTimeToLive: .seconds(30 * 24 * 3600),
        minimumRetainedConfidence: 0.2,
        maxLiveFactsPerThread: nil,
        confidenceDecayHalfLife: nil
    )

    /// The lifetime that applies to `fact`: the smallest matching tag
    /// lifetime, otherwise ``defaultTimeToLive``.
    func resolvedTimeToLive(for fact: Fact) -> Duration? {
        var smallest: Duration?
        for tag in fact.tags.sorted() {
            guard let candidate = timeToLiveByTag[tag] else { continue }
            if let current = smallest {
                if candidate < current { smallest = candidate }
            } else {
                smallest = candidate
            }
        }
        return smallest ?? defaultTimeToLive
    }
}

/// What one ``ForgettingSweep`` retired, split by cause.
///
/// The three lists are disjoint and each is sorted by id ascending, so a
/// sweep's result is directly comparable across runs.
public struct SweepOutcome: Sendable, Equatable {
    /// Retired by an explicit expiry, a TTL, or an unreconfirmed-derived
    /// lifetime.
    public let expired: [String]
    /// Retired by the per-thread live cap.
    public let evicted: [String]
    /// Retired because decayed confidence fell below the retention floor.
    public let decayed: [String]

    /// Creates an outcome.
    public init(expired: [String], evicted: [String], decayed: [String]) {
        self.expired = expired
        self.evicted = evicted
        self.decayed = decayed
    }

    /// A sweep that retired nothing.
    public static let empty = SweepOutcome(expired: [], evicted: [], decayed: [])

    /// Whether anything was retired.
    public var isEmpty: Bool { expired.isEmpty && evicted.isEmpty && decayed.isEmpty }

    /// Every retired id, sorted ascending.
    public var allIDs: [String] { (expired + evicted + decayed).sorted() }
}

/// Runs a ``ForgettingPolicy`` over a store.
///
/// The sweep is a pure function of the policy, the store contents, and
/// the injected `now`, and it is **idempotent**: running it twice with
/// the same `now` retires the same set the first time and nothing the
/// second, because everything it touched is already invalidated and
/// ``MemoryStore/invalidate(ids:validUntil:at:reason:)`` skips retired
/// records. That property is what makes it safe to run from
/// ``BackgroundCompoundActivity``, whose deferral semantics re-run a
/// deferred body from the top.
public struct ForgettingSweep: Sendable {
    /// The rules being applied.
    public let policy: ForgettingPolicy

    /// Creates a sweep.
    public init(policy: ForgettingPolicy = .default) {
        self.policy = policy
    }

    /// Applies the policy and returns what was retired.
    ///
    /// Stages run in a fixed order — expiry, unreconfirmed-derived
    /// expiry, decay, eviction — and each stage only considers records
    /// no earlier stage retired. The order matters: eviction is the only
    /// stage that can retire a record for a reason unrelated to that
    /// record's own content, so it runs last, against a live set the
    /// cheaper rules have already pruned. A cap of 20 should not evict a
    /// good fact to make room for one that was about to expire anyway.
    ///
    /// - Parameters:
    ///   - store: Store to sweep.
    ///   - threadID: Restrict to one thread. `nil` sweeps every thread;
    ///     the per-thread cap is then applied per thread, not globally.
    ///   - now: The caller's clock instant. Every comparison is against
    ///     this value; nothing here reads the system clock.
    ///   - scorer: Salience scorer used for eviction ranking. Relevance
    ///     is uniformly zero — there is no query at sweep time — so the
    ///     ranking reduces to recency × importance.
    @discardableResult
    public func sweep(
        store: any MemoryStore,
        threadID: String?,
        now: Date,
        scorer: SalienceScorer = SalienceScorer()
    ) async throws -> SweepOutcome {
        // `includeInvalidated: true` is required, not incidental: a record
        // whose `expiresAt` has passed is already excluded from a live
        // query, yet it still carries no `invalidatedAt` and so has never
        // actually been retired. Sweeping only the live set would leave
        // those in limbo forever.
        let all = try await store.query(MemoryQuery(
            now: now,
            threadID: threadID,
            includeInvalidated: true,
            limit: Int.max,
            order: .idAscending
        ))
        var remaining = all.filter { $0.invalidatedAt == nil }

        // (a) explicit expiry and TTL
        var expired: [String] = []
        remaining = remaining.filter { fact in
            if let expiresAt = fact.expiresAt, expiresAt <= now {
                expired.append(fact.id)
                return false
            }
            if let ttl = policy.resolvedTimeToLive(for: fact),
               fact.recordedAt.addingTimeInterval(ForgettingSweep.seconds(ttl)) <= now {
                expired.append(fact.id)
                return false
            }
            return true
        }

        // (b) unreconfirmed derived reflections. Measured from
        // `lastAccessedAt` rather than `recordedAt` because a recall or a
        // reconfirmation *is* the confirming evidence whose absence the
        // rule is about.
        if let derivedTTL = policy.unreconfirmedDerivedTimeToLive {
            let window = ForgettingSweep.seconds(derivedTTL)
            remaining = remaining.filter { fact in
                guard fact.origin == .derived else { return true }
                guard fact.lastAccessedAt.addingTimeInterval(window) <= now else { return true }
                expired.append(fact.id)
                return false
            }
        }

        // (c) confidence decay.
        //
        // The decayed value is computed, never written back. Persisting
        // it would require a "confidence as of" timestamp to decay from
        // on the next pass, and without one a second sweep at the same
        // `now` would decay an already-decayed number and retire records
        // the first pass kept — the sweep would stop being idempotent,
        // which is the one property a deferred background job cannot do
        // without. Confidence stays the extractor's original assessment;
        // decay is a *view* of it at an instant.
        var decayed: [String] = []
        if let halfLife = policy.confidenceDecayHalfLife {
            let halfLifeSeconds = ForgettingSweep.seconds(halfLife)
            if halfLifeSeconds > 0 {
                remaining = remaining.filter { fact in
                    let elapsed = max(0, now.timeIntervalSince(fact.lastAccessedAt))
                    let value = fact.confidence * pow(0.5, elapsed / halfLifeSeconds)
                    guard value < policy.minimumRetainedConfidence else { return true }
                    decayed.append(fact.id)
                    return false
                }
            }
        }

        // (d) per-thread live cap.
        var evicted: [String] = []
        if let cap = policy.maxLiveFactsPerThread, cap >= 0 {
            var byThread: [String: [Fact]] = [:]
            for fact in remaining where fact.isLive(at: now) {
                byThread[fact.threadID, default: []].append(fact)
            }
            for thread in byThread.keys.sorted() {
                let facts = byThread[thread] ?? []
                guard facts.count > cap else { continue }
                // `score` returns best-first with ties broken on id
                // ascending, so keeping the first `cap` keeps the most
                // salient records and, among indistinguishable ones, the
                // lexicographically smaller id.
                let ranked = scorer.score(facts, relevance: [:], now: now).map(\.fact)
                evicted.append(contentsOf: ranked.dropFirst(cap).map(\.id))
            }
        }

        expired.sort()
        decayed.sort()
        evicted.sort()

        if !expired.isEmpty {
            // `validUntil` is left alone. An expiry says the system stops
            // asserting the record, not that the claim was retroactively
            // false, so a historical `asOf` query inside the original
            // window still answers honestly.
            try await store.invalidate(ids: expired, validUntil: nil, at: now, reason: .expired)
        }
        if !decayed.isEmpty {
            try await store.invalidate(ids: decayed, validUntil: nil, at: now, reason: .expired)
        }
        if !evicted.isEmpty {
            try await store.invalidate(ids: evicted, validUntil: nil, at: now, reason: .evicted)
        }

        return SweepOutcome(expired: expired, evicted: evicted, decayed: decayed)
    }

    /// `Duration` as seconds. Attoseconds are folded in so a sub-second
    /// policy is not silently truncated to zero.
    static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) * 1e-18
    }
}
