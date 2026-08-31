import Foundation

/// One retrieval eval case: a query plus the ground truth it should
/// surface.
///
/// Ground truth is graded — a `[chunk id: gain]` table — with a binary
/// convenience initializer that assigns gain `1.0`. The ids must be the
/// deterministic ids ``DocumentChunker/chunkID(documentID:ordinal:content:)``
/// derives, so a stored suite keeps pointing at the same passages after
/// the corpus is re-chunked.
///
/// A case with no positive gains is an *abstention* case: the corpus
/// contains nothing that answers the query, and the correct behavior is to
/// return nothing (or only low-scoring results). See
/// ``RetrievalEvalReport/abstention(scoreFloor:)``.
///
/// Cases are inert data; ``RetrievalEvalRunner`` executes them.
public struct RetrievalEvalCase: Sendable, Codable, Equatable {
    /// Stable case identifier, unique within a suite.
    public let id: String
    /// Query handed to the retriever.
    public let query: String
    /// Ground-truth relevance grades keyed by chunk id. Ids may be present
    /// with gain `0.0` to record "assessed, not relevant".
    public let gains: [String: Double]
    /// Free-form tags used by ``RetrievalEvalSuite/filtered(tags:)`` and
    /// ``RetrievalEvalReport/aggregate(tags:)``.
    public let tags: Set<String>

    /// Creates a case with graded relevance.
    ///
    /// - Precondition: every gain is non-negative.
    public init(id: String, query: String, gains: [String: Double], tags: Set<String> = []) {
        precondition(gains.values.allSatisfy { $0 >= 0 }, "gains must be non-negative")
        self.id = id
        self.query = query
        self.gains = gains
        self.tags = tags
    }

    /// Creates a case with binary relevance: every id in `relevantIDs`
    /// gets gain `1.0`. Pass an empty set for an abstention case.
    public init(id: String, query: String, relevantIDs: Set<String>, tags: Set<String> = []) {
        self.init(id: id, query: query, gains: RetrievalMetrics.binaryGains(relevantIDs), tags: tags)
    }

    /// Ids with strictly positive gain.
    public var relevantIDs: Set<String> {
        Set(gains.filter { $0.value > 0 }.keys)
    }

    /// `true` when nothing in the corpus is relevant, i.e. the case tests
    /// that the retriever declines to answer.
    public var isAbstention: Bool {
        !gains.contains { $0.value > 0 }
    }
}

/// Named collection of ``RetrievalEvalCase``s.
public struct RetrievalEvalSuite: Sendable, Codable, Equatable {
    /// Suite name surfaced in ``RetrievalEvalReport``.
    public let name: String
    /// Cases in declaration order.
    public let cases: [RetrievalEvalCase]

    /// Creates a suite.
    public init(name: String, cases: [RetrievalEvalCase]) {
        self.name = name
        self.cases = cases
    }

    /// Returns a suite containing only cases whose tags overlap `tags`.
    public func filtered(tags: Set<String>) -> RetrievalEvalSuite {
        RetrievalEvalSuite(name: name, cases: cases.filter { !$0.tags.isDisjoint(with: tags) })
    }
}

/// Runs a ``RetrievalEvalSuite`` against any ``Retriever`` and produces a
/// ``RetrievalEvalReport``.
///
/// The runner is retriever-agnostic: BM25, dense, hybrid, or a reranking
/// composition all satisfy ``Retriever``, so the same suite measures each
/// and the reports are directly comparable.
public struct RetrievalEvalRunner: Sendable {
    /// Cutoff the metrics are reported at.
    public let k: Int
    /// Number of results requested from the retriever. Defaults to ``k``;
    /// set it higher to record a longer ranked list in the report (useful
    /// when diagnosing near-misses) while still scoring at ``k``.
    public let limit: Int
    /// Maximum cases evaluated in parallel.
    public let concurrency: Int

    /// Creates a runner.
    ///
    /// - Precondition: `k > 0`, `limit >= k` (a shorter list could not
    ///   support a metric at `k`), and `concurrency >= 1`.
    public init(k: Int = 10, limit: Int? = nil, concurrency: Int = 4) {
        let resolvedLimit = limit ?? k
        precondition(k >= 1, "k must be at least 1")
        precondition(resolvedLimit >= k, "limit must be at least k")
        precondition(concurrency >= 1, "concurrency must be at least 1")
        self.k = k
        self.limit = resolvedLimit
        self.concurrency = concurrency
    }

    /// Runs every case in `suite` against `retriever`.
    ///
    /// Cases run in parallel with a sliding window of width
    /// ``concurrency``; the report preserves declaration order regardless.
    /// A retriever that throws fails only its own case — the failure is
    /// recorded as ``RetrievalEvalReport/CaseOutcome/Result/errored(reason:elapsed:)``
    /// rather than being swallowed or scored as a zero-recall success.
    ///
    /// - Throws: ``EvalError/duplicateCaseID(_:)`` if two cases share an
    ///   id, or `CancellationError` if the calling task is cancelled
    ///   between case admissions.
    public func run(
        _ suite: RetrievalEvalSuite,
        against retriever: any Retriever
    ) async throws -> RetrievalEvalReport {
        var seen = Set<String>()
        for c in suite.cases where !seen.insert(c.id).inserted {
            throw EvalError.duplicateCaseID(c.id)
        }

        let started = Date()
        let cases = suite.cases
        let k = k
        let limit = limit
        var outcomes: [RetrievalEvalReport.CaseOutcome] = []
        outcomes.reserveCapacity(cases.count)

        try await withThrowingTaskGroup(of: RetrievalEvalReport.CaseOutcome.self) { group in
            var next = 0
            while next < min(concurrency, cases.count) {
                let c = cases[next]
                next += 1
                group.addTask { await Self.runOne(c, retriever: retriever, k: k, limit: limit) }
            }
            while let outcome = try await group.next() {
                outcomes.append(outcome)
                try Task.checkCancellation()
                if next < cases.count {
                    let c = cases[next]
                    next += 1
                    group.addTask { await Self.runOne(c, retriever: retriever, k: k, limit: limit) }
                }
            }
        }

        // Restore declaration order. Duplicate ids were rejected above;
        // `uniquingKeysWith` degrades a future regression to first-wins
        // instead of trapping.
        let byID = Dictionary(outcomes.map { ($0.caseID, $0) }, uniquingKeysWith: { first, _ in first })
        return RetrievalEvalReport(
            suiteName: suite.name,
            runID: UUID(),
            started: started,
            finished: Date(),
            k: k,
            cases: cases.compactMap { byID[$0.id] },
            environment: .current()
        )
    }

    private static func runOne(
        _ c: RetrievalEvalCase,
        retriever: any Retriever,
        k: Int,
        limit: Int
    ) async -> RetrievalEvalReport.CaseOutcome {
        let started = ContinuousClock.now
        do {
            let results = try await retriever.retrieve(query: c.query, limit: limit)
            let scores = RetrievalScores.compute(retrieved: results, gains: c.gains, k: k)
            let hits = results.map {
                RetrievalEvalReport.Hit(id: $0.id, score: $0.score, gain: c.gains[$0.id] ?? 0)
            }
            return RetrievalEvalReport.CaseOutcome(
                caseID: c.id,
                query: c.query,
                tags: c.tags.sorted(),
                relevantCount: c.relevantIDs.count,
                result: .completed(retrieved: hits, scores: scores, elapsed: ContinuousClock.now - started)
            )
        } catch {
            return RetrievalEvalReport.CaseOutcome(
                caseID: c.id,
                query: c.query,
                tags: c.tags.sorted(),
                relevantCount: c.relevantIDs.count,
                result: .errored(reason: String(describing: error), elapsed: ContinuousClock.now - started)
            )
        }
    }
}

/// Summarizes a ``RetrievalEvalRunner`` pass: the ranked list and metric
/// set per case, plus aggregates.
///
/// Shaped like ``EvalReport`` — `runID`, `started`/`finished`,
/// `environment`, ISO 8601 dates and integer-nanosecond durations in the
/// JSON encoding — so retrieval baselines live next to generation
/// baselines in CI and diff the same way.
///
/// Aggregates are computed, not stored, so a decoded report can never
/// disagree with its own case rows.
public struct RetrievalEvalReport: Sendable, Codable {
    /// Suite name.
    public let suiteName: String
    /// Identifier for this run, for correlating with logs and traces.
    public let runID: UUID
    /// Wall-clock instant the run started.
    public let started: Date
    /// Wall-clock instant the run finished.
    public let finished: Date
    /// Cutoff every ranked metric in this report was evaluated at.
    public let k: Int
    /// Per-case outcomes in declaration order.
    public let cases: [CaseOutcome]
    /// Snapshot of the machine the run executed on, if recorded. Reuses
    /// ``EvalReport/Environment`` so both report kinds record the host the
    /// same way.
    public let environment: EvalReport.Environment?

    /// One result row inside a completed case.
    public struct Hit: Sendable, Codable, Equatable {
        /// Chunk id returned by the retriever.
        public let id: String
        /// Retriever-reported score, if any.
        public let score: Double?
        /// Ground-truth gain of this id (`0` when not relevant), so a
        /// stored report shows *why* a case scored what it did without
        /// needing the suite alongside it.
        public let gain: Double

        /// Creates a hit row.
        public init(id: String, score: Double?, gain: Double) {
            self.id = id
            self.score = score
            self.gain = gain
        }
    }

    /// Outcome of one ``RetrievalEvalCase``.
    public struct CaseOutcome: Sendable, Codable, Equatable {
        /// Identifier of the originating case.
        public let caseID: String
        /// Query used.
        public let query: String
        /// Case tags, sorted for a stable encoding.
        public let tags: [String]
        /// Size of the ground-truth relevant set. Recorded on the outcome
        /// itself (not only inside ``RetrievalScores``) so an *errored*
        /// abstention case is still identifiable as an abstention case.
        public let relevantCount: Int
        /// Outcome.
        public let result: Result

        /// Creates a case outcome.
        public init(caseID: String, query: String, tags: [String], relevantCount: Int, result: Result) {
            self.caseID = caseID
            self.query = query
            self.tags = tags
            self.relevantCount = relevantCount
            self.result = result
        }

        /// A scored case, or a retriever failure.
        public enum Result: Sendable, Codable, Equatable {
            /// The retriever returned `retrieved`, scored as `scores`.
            case completed(retrieved: [Hit], scores: RetrievalScores, elapsed: Duration)
            /// The retriever threw `reason`.
            case errored(reason: String, elapsed: Duration)

            private enum CodingKeys: String, CodingKey {
                case kind, retrieved, scores, reason, elapsedNanoseconds
            }

            private enum Kind: String, Codable {
                case completed, errored
            }

            public init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                let kind = try container.decode(Kind.self, forKey: .kind)
                let elapsed = Duration.nanoseconds(try container.decode(Int64.self, forKey: .elapsedNanoseconds))
                switch kind {
                case .completed:
                    self = .completed(
                        retrieved: try container.decode([Hit].self, forKey: .retrieved),
                        scores: try container.decode(RetrievalScores.self, forKey: .scores),
                        elapsed: elapsed
                    )
                case .errored:
                    self = .errored(
                        reason: try container.decode(String.self, forKey: .reason),
                        elapsed: elapsed
                    )
                }
            }

            public func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                case .completed(let retrieved, let scores, let elapsed):
                    try container.encode(Kind.completed, forKey: .kind)
                    try container.encode(retrieved, forKey: .retrieved)
                    try container.encode(scores, forKey: .scores)
                    try container.encode(Self.nanoseconds(of: elapsed), forKey: .elapsedNanoseconds)
                case .errored(let reason, let elapsed):
                    try container.encode(Kind.errored, forKey: .kind)
                    try container.encode(reason, forKey: .reason)
                    try container.encode(Self.nanoseconds(of: elapsed), forKey: .elapsedNanoseconds)
                }
            }

            private static func nanoseconds(of duration: Duration) -> Int64 {
                let (seconds, attoseconds) = duration.components
                return seconds * 1_000_000_000 &+ attoseconds / 1_000_000_000
            }
        }

        /// Metric set, or `nil` if the case errored.
        public var scores: RetrievalScores? {
            switch result {
            case .completed(_, let scores, _): return scores
            case .errored: return nil
            }
        }

        /// Ranked ids returned, or `[]` if the case errored.
        public var retrievedIDs: [String] {
            switch result {
            case .completed(let hits, _, _): return hits.map(\.id)
            case .errored: return []
            }
        }

        /// `true` when the case's ground truth contains nothing relevant.
        public var isAbstention: Bool { relevantCount == 0 }
    }

    /// Suite-level aggregates. Means skip cases where a metric is
    /// undefined (see ``RetrievalMetrics``), so abstention cases do not
    /// drag mean recall to zero.
    public struct Aggregate: Sendable, Codable, Equatable {
        /// Cases considered.
        public let caseCount: Int
        /// Cases that produced a ranked list.
        public let completedCaseCount: Int
        /// Cases whose retriever threw.
        public let erroredCaseCount: Int
        /// Mean recall@k over cases where recall is defined.
        public let recallAtK: Double?
        /// Mean precision@k over cases where precision is defined.
        public let precisionAtK: Double?
        /// Mean nDCG@k over cases where nDCG is defined.
        public let ndcgAtK: Double?
        /// Mean reciprocal rank — MRR — over cases where it is defined.
        public let meanReciprocalRank: Double?

        /// Creates an aggregate.
        public init(
            caseCount: Int,
            completedCaseCount: Int,
            erroredCaseCount: Int,
            recallAtK: Double?,
            precisionAtK: Double?,
            ndcgAtK: Double?,
            meanReciprocalRank: Double?
        ) {
            self.caseCount = caseCount
            self.completedCaseCount = completedCaseCount
            self.erroredCaseCount = erroredCaseCount
            self.recallAtK = recallAtK
            self.precisionAtK = precisionAtK
            self.ndcgAtK = ndcgAtK
            self.meanReciprocalRank = meanReciprocalRank
        }
    }

    /// Creates a report.
    public init(
        suiteName: String,
        runID: UUID = UUID(),
        started: Date,
        finished: Date,
        k: Int,
        cases: [CaseOutcome],
        environment: EvalReport.Environment? = nil
    ) {
        self.suiteName = suiteName
        self.runID = runID
        self.started = started
        self.finished = finished
        self.k = k
        self.cases = cases
        self.environment = environment
    }

    /// Aggregates over every case.
    public var aggregate: Aggregate { Self.aggregate(of: cases) }

    /// Aggregates over the cases whose tags overlap `tags` — the same
    /// suite can then report a headline number and a per-slice breakdown
    /// (`["distractor"]`, `["abstention"]`, a domain tag) without a second
    /// run.
    public func aggregate(tags: Set<String>) -> Aggregate {
        Self.aggregate(of: cases.filter { !Set($0.tags).isDisjoint(with: tags) })
    }

    private static func aggregate(of cases: [CaseOutcome]) -> Aggregate {
        let scores = cases.compactMap(\.scores)
        return Aggregate(
            caseCount: cases.count,
            completedCaseCount: scores.count,
            erroredCaseCount: cases.count - scores.count,
            recallAtK: RetrievalMetrics.mean(scores.map(\.recall)),
            precisionAtK: RetrievalMetrics.mean(scores.map(\.precision)),
            ndcgAtK: RetrievalMetrics.mean(scores.map(\.ndcg)),
            meanReciprocalRank: RetrievalMetrics.mean(scores.map(\.reciprocalRank))
        )
    }

    /// Wall-clock duration of the run.
    public var elapsed: Duration { .seconds(finished.timeIntervalSince(started)) }

    /// Encodes the report as JSON with ISO 8601 dates and sorted keys, so
    /// stored baselines diff cleanly.
    ///
    /// ISO 8601 is whole-second, so ``started`` and ``finished`` round-trip
    /// at second granularity. Per-case timings are carried separately as
    /// integer nanoseconds and are exact.
    public func jsonData(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Decodes a report previously produced by ``jsonData(prettyPrinted:)``.
    public init(jsonData: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self = try decoder.decode(RetrievalEvalReport.self, from: jsonData)
    }

    /// Human-readable single-line summary suitable for CI logs. Programs
    /// should inspect ``aggregate`` instead.
    public func summary() -> String {
        let a = aggregate
        func fmt(_ value: Double?) -> String {
            value.map { String(format: "%.3f", $0) } ?? "n/a"
        }
        var line = "[\(suiteName)] \(a.caseCount) cases"
        line += " recall@\(k)=\(fmt(a.recallAtK))"
        line += " precision@\(k)=\(fmt(a.precisionAtK))"
        line += " ndcg@\(k)=\(fmt(a.ndcgAtK))"
        line += " mrr=\(fmt(a.meanReciprocalRank))"
        if a.erroredCaseCount > 0 { line += " errors=\(a.erroredCaseCount)" }
        return line
    }
}
