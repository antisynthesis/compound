import Foundation

// Quality metrics answer "does retrieval find the right passage on a clean
// corpus?". Robustness asks the two questions that actually break RAG
// deployments: does the ranking survive near-duplicate noise, and does the
// retriever shut up when the corpus has no answer? Both are measurable
// off-device with seeded corpora and pure comparisons.

/// Helpers for the two retrieval robustness suites: distractor injection
/// and abstention.
public enum RetrievalRobustness {
    /// Marker token embedded in generated distractors so they are
    /// recognizable in a report and can never be confused with real corpus
    /// text.
    public static let distractorMarker = "compound-distractor"

    /// Generates `count` near-duplicate distractors for `chunk`.
    ///
    /// Each distractor repeats the source content verbatim and appends the
    /// marker plus its index, so it matches every query term the original
    /// matches — the hard case for a lexical retriever, since only length
    /// normalization and term saturation separate the gold passage from
    /// the copies. Ids are the usual deterministic
    /// ``DocumentChunker/chunkID(documentID:ordinal:content:)`` derivation
    /// over a distinct `documentID`, so distractors never collide with the
    /// gold chunk's id and a suite that indexes them stays reproducible.
    ///
    /// - Precondition: `count >= 0`.
    public static func nearDuplicates(
        of chunk: DocumentChunk,
        count: Int,
        documentIDSuffix: String = "-distractor",
        marker: String = distractorMarker,
        metadata: [String: String] = [:]
    ) -> [DocumentChunk] {
        precondition(count >= 0, "count must be non-negative")
        return (0..<count).map { index in
            DocumentChunk(
                documentID: chunk.documentID + documentIDSuffix,
                ordinal: index,
                content: "\(chunk.content) \(marker) \(index)",
                metadata: metadata
            )
        }
    }

    /// Compares two ranked id lists at cutoff `k`.
    ///
    /// `baseline` is the ranking over the clean corpus, `perturbed` the
    /// ranking after distractors were indexed. Both are de-duplicated and
    /// truncated to `k` by ``RetrievalMetrics/topK(_:k:)`` first.
    ///
    /// - Precondition: `k > 0`.
    public static func rankStability(baseline: [String], perturbed: [String], k: Int) -> RankStability {
        let a = RetrievalMetrics.topK(baseline, k: k)
        let b = RetrievalMetrics.topK(perturbed, k: k)
        let positionsB = Dictionary(uniqueKeysWithValues: b.enumerated().map { ($0.element, $0.offset) })
        let common = a.filter { positionsB[$0] != nil }

        let overlap: Double? = a.isEmpty ? nil : Double(common.count) / Double(a.count)
        var maxDisplacement: Int?
        for (rankA, id) in a.enumerated() {
            guard let rankB = positionsB[id] else { continue }
            maxDisplacement = max(maxDisplacement ?? 0, abs(rankB - rankA))
        }

        // Kendall tau over the ids present in both lists. No ties are
        // possible (both are strict orders over distinct ids), so the
        // denominator is the plain pair count.
        var tau: Double?
        if common.count >= 2 {
            var concordant = 0
            var discordant = 0
            for i in 0..<(common.count - 1) {
                for j in (i + 1)..<common.count {
                    // `common` is in baseline order, so i precedes j there
                    // by construction; only b's order can disagree.
                    let bI = positionsB[common[i]] ?? 0
                    let bJ = positionsB[common[j]] ?? 0
                    if bI < bJ { concordant += 1 } else { discordant += 1 }
                }
            }
            let pairs = Double(common.count * (common.count - 1)) / 2.0
            tau = (Double(concordant) - Double(discordant)) / pairs
        }

        return RankStability(
            k: k,
            overlap: overlap,
            topRankRetained: a.first == b.first,
            maxDisplacement: maxDisplacement,
            kendallTau: tau
        )
    }

    /// Runs `query` against a clean and a perturbed retriever and compares
    /// the two rankings.
    ///
    /// Both retrievers are asked for `k` results. Typical use: build one
    /// index over the gold corpus, a second over the gold corpus plus
    /// ``nearDuplicates(of:count:documentIDSuffix:marker:metadata:)``, and
    /// assert the gold passage still ranks first.
    public static func rankStability(
        query: String,
        baseline: any Retriever,
        perturbed: any Retriever,
        k: Int
    ) async throws -> RankStability {
        precondition(k > 0, "k must be positive")
        let before = try await baseline.retrieve(query: query, limit: k).map(\.id)
        let after = try await perturbed.retrieve(query: query, limit: k).map(\.id)
        return rankStability(baseline: before, perturbed: after, k: k)
    }
}

/// How much a ranking moved between a clean and a perturbed corpus.
public struct RankStability: Sendable, Codable, Equatable {
    /// Cutoff the comparison was made at.
    public let k: Int
    /// Fraction of the baseline top-`k` still present in the perturbed
    /// top-`k`. `nil` when the baseline returned nothing.
    public let overlap: Double?
    /// `true` when both rankings have the same first result — including
    /// the degenerate case where both are empty.
    public let topRankRetained: Bool
    /// Largest absolute rank change among ids present in both top-`k`
    /// lists. `nil` when the lists share no id. Ids that fell out of the
    /// perturbed list entirely are not counted here — they show up in
    /// ``overlap``.
    public let maxDisplacement: Int?
    /// Kendall's tau over the ids common to both lists, in `[-1, 1]`:
    /// `1` means their relative order is untouched. `nil` when fewer than
    /// two ids are common (no pair to compare).
    public let kendallTau: Double?

    /// Creates a stability record.
    public init(k: Int, overlap: Double?, topRankRetained: Bool, maxDisplacement: Int?, kendallTau: Double?) {
        self.k = k
        self.overlap = overlap
        self.topRankRetained = topRankRetained
        self.maxDisplacement = maxDisplacement
        self.kendallTau = kendallTau
    }

    /// `true` when the top result is unchanged, every baseline result
    /// survived, and their relative order is intact — the assertion a
    /// distractor suite usually wants.
    public var isFullyStable: Bool {
        topRankRetained && (overlap ?? 1.0) >= 1.0 && (kendallTau ?? 1.0) >= 1.0
    }
}

/// One abstention case's behavior: did the retriever decline?
public struct AbstentionOutcome: Sendable, Codable, Equatable {
    /// Identifier of the case.
    public let caseID: String
    /// `true` when the retriever returned nothing, or returned only
    /// results scoring below the floor.
    public let abstained: Bool
    /// Number of results returned.
    public let returnedCount: Int
    /// Highest score returned, if the retriever reported scores.
    public let topScore: Double?

    /// Creates an outcome.
    public init(caseID: String, abstained: Bool, returnedCount: Int, topScore: Double?) {
        self.caseID = caseID
        self.abstained = abstained
        self.returnedCount = returnedCount
        self.topScore = topScore
    }
}

/// Aggregate over the abstention cases of a ``RetrievalEvalReport``.
public struct AbstentionSummary: Sendable, Codable, Equatable {
    /// Abstention cases that produced a ranked list.
    public let caseCount: Int
    /// How many of those abstained.
    public let abstainedCount: Int
    /// Abstention cases whose retriever threw. Reported separately rather
    /// than counted as an abstention: an error is not a decision.
    public let erroredCaseCount: Int
    /// Per-case detail in report order.
    public let outcomes: [AbstentionOutcome]

    /// Creates a summary.
    public init(caseCount: Int, abstainedCount: Int, erroredCaseCount: Int, outcomes: [AbstentionOutcome]) {
        self.caseCount = caseCount
        self.abstainedCount = abstainedCount
        self.erroredCaseCount = erroredCaseCount
        self.outcomes = outcomes
    }

    /// Fraction of scored abstention cases that abstained, or `0` when
    /// there were none.
    public var rate: Double {
        caseCount == 0 ? 0 : Double(abstainedCount) / Double(caseCount)
    }

    /// Cases that answered when they should have declined.
    public var violations: [AbstentionOutcome] {
        outcomes.filter { !$0.abstained }
    }
}

extension RetrievalEvalReport {
    /// Summarizes behavior on the report's abstention cases — those whose
    /// ground truth contains nothing relevant.
    ///
    /// - Parameter scoreFloor: When supplied, a case also counts as
    ///   abstaining if every returned result scores below the floor. This
    ///   is the realistic criterion for a retriever that always returns
    ///   its `limit` best guesses: the caller's job is then to threshold,
    ///   and the suite measures whether a threshold *could* work. With
    ///   `nil` (the default), only returning nothing counts.
    ///
    ///   A retriever that reports no scores at all cannot clear a floor,
    ///   so such a case abstains only by returning nothing.
    public func abstention(scoreFloor: Double? = nil) -> AbstentionSummary {
        var outcomes: [AbstentionOutcome] = []
        var errored = 0
        for c in cases where c.isAbstention {
            guard let scores = c.scores else {
                errored += 1
                continue
            }
            let abstained: Bool
            if scores.retrievedCount == 0 {
                abstained = true
            } else if let floor = scoreFloor, let top = scores.topScore {
                abstained = top < floor
            } else {
                abstained = false
            }
            outcomes.append(AbstentionOutcome(
                caseID: c.caseID,
                abstained: abstained,
                returnedCount: scores.retrievedCount,
                topScore: scores.topScore
            ))
        }
        return AbstentionSummary(
            caseCount: outcomes.count,
            abstainedCount: outcomes.count(where: { $0.abstained }),
            erroredCaseCount: errored,
            outcomes: outcomes
        )
    }
}
