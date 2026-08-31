import Foundation

// Memory quality is measured the way ForgetEval measures it: as a pure set
// predicate over the text a retriever actually surfaced. No model reads the
// output, no judge scores it, nothing here touches a clock or a network.
//
// That choice is not austerity for its own sake. A committed golden
// baseline is only worth committing if re-running it a year later on a
// different model build produces the same verdicts; an LLM judge makes the
// baseline a function of the judge's weights, and the first judge upgrade
// silently invalidates every number in the file. A subset/disjointness
// check over normalized text is reproducible by construction.

/// One memory eval case: a query plus what the retrieved evidence must and
/// must not say.
///
/// The criterion is deliberately coarse — a case passes iff every
/// ``mustContain`` term appears in the top-`k` blob **and** no
/// ``mustNotContain`` term does. It measures whether the right thing
/// reached the prompt and the wrong thing did not, which is the only
/// question a forgetting control plane can be held to without a judge.
///
/// The absence half carries most of the weight. Recall is easy to fake by
/// returning everything; a system that never forgets scores perfectly on
/// ``mustContain`` and fails every supersession, decay, amnesia, purge, and
/// drift case. ``mustNotContain`` is what makes those families gradeable.
///
/// Cases are inert data; ``MemoryEvalRunner`` executes them.
public struct MemoryEvalCase: Sendable, Codable, Equatable {
    /// Stable case identifier, unique within a suite.
    public let id: String
    /// Query handed to the retriever.
    public let query: String
    /// Terms that must all appear in the top-`k` blob.
    public let mustContain: Set<String>
    /// Terms that must appear nowhere in the top-`k` blob.
    public let mustNotContain: Set<String>
    /// Cutoff the blob is built at.
    public let k: Int
    /// Free-form tags naming the forgetting family — `supersession`,
    /// `decay`, `amnesia`, `purge`, `drift`, and so on. Used by
    /// ``MemoryEvalSuite/filtered(tags:)`` and
    /// ``MemoryEvalReport/aggregate(tags:)``.
    public let tags: Set<String>

    /// Creates a case.
    ///
    /// - Precondition: `k >= 1`, and no term is empty (an empty
    ///   `mustContain` term is trivially present and an empty
    ///   `mustNotContain` term is trivially violated, so either is a
    ///   suite bug rather than a measurement).
    public init(
        id: String,
        query: String,
        mustContain: Set<String> = [],
        mustNotContain: Set<String> = [],
        k: Int = 10,
        tags: Set<String> = []
    ) {
        precondition(k >= 1, "k must be at least 1")
        precondition(
            mustContain.allSatisfy { !MemoryEvalBlob.normalize($0).isEmpty },
            "mustContain terms must be non-empty after normalization"
        )
        precondition(
            mustNotContain.allSatisfy { !MemoryEvalBlob.normalize($0).isEmpty },
            "mustNotContain terms must be non-empty after normalization"
        )
        self.id = id
        self.query = query
        self.mustContain = mustContain
        self.mustNotContain = mustNotContain
        self.k = k
        self.tags = tags
    }
}

/// Named collection of ``MemoryEvalCase``s.
public struct MemoryEvalSuite: Sendable, Codable, Equatable {
    /// Suite name surfaced in ``MemoryEvalReport``.
    public let name: String
    /// Cases in declaration order.
    public let cases: [MemoryEvalCase]

    /// Creates a suite.
    public init(name: String, cases: [MemoryEvalCase]) {
        self.name = name
        self.cases = cases
    }

    /// Returns a suite containing only cases whose tags overlap `tags`.
    public func filtered(tags: Set<String>) -> MemoryEvalSuite {
        MemoryEvalSuite(name: name, cases: cases.filter { !$0.tags.isDisjoint(with: tags) })
    }
}

/// Builds and grades the top-`k` evidence blob a ``MemoryEvalCase`` is
/// judged against.
///
/// Both halves — construction and normalization — are pure functions, so a
/// stored ``MemoryEvalReport`` can be re-derived from the same retriever
/// output byte for byte.
public enum MemoryEvalBlob {
    /// Normalizes text for matching: NFC, lowercased, whitespace runs
    /// collapsed to a single space, trimmed.
    ///
    /// Delegates to ``MemoryText/normalize(_:)`` rather than reimplementing
    /// the rule. "Same fact restated" has exactly one definition in this
    /// package and the eval must not acquire a second one — an eval whose
    /// notion of sameness drifts from the store's would start grading a
    /// system other than the one that shipped.
    public static func normalize(_ text: String) -> String {
        MemoryText.normalize(text)
    }

    /// Concatenates `title + "\n" + content` over the first `k` distinct
    /// sources and normalizes the result.
    ///
    /// The title is included on purpose: for archival hits it is the
    /// provenance channel (`thread … round … [timestamp]`), so a case can
    /// assert that a round arrived *with* its attribution rather than as
    /// anonymous text. Duplicate ids are dropped keeping the earliest
    /// occurrence, matching ``RetrievalMetrics/topK(_:k:)`` — a retriever
    /// must not consume a rank slot with its own duplicate.
    public static func build(from sources: [RetrievedSource], k: Int) -> String {
        precondition(k >= 1, "k must be at least 1")
        var seen = Set<String>()
        var parts: [String] = []
        for source in sources {
            guard seen.insert(source.id).inserted else { continue }
            parts.append(source.title + "\n" + source.content)
            if parts.count == k { break }
        }
        return normalize(parts.joined(separator: "\n"))
    }

    /// Grades `sources` against `evalCase`.
    ///
    /// Returns the verdict plus the terms responsible for it, so a failing
    /// case in a stored report explains itself without the suite alongside.
    /// `missing` and `forbidden` come back sorted for a stable encoding.
    public static func grade(
        _ evalCase: MemoryEvalCase,
        sources: [RetrievedSource]
    ) -> (passed: Bool, missing: [String], forbidden: [String]) {
        let blob = build(from: sources, k: evalCase.k)
        let missing = evalCase.mustContain
            .filter { !blob.contains(normalize($0)) }
            .sorted()
        let forbidden = evalCase.mustNotContain
            .filter { blob.contains(normalize($0)) }
            .sorted()
        return (missing.isEmpty && forbidden.isEmpty, missing, forbidden)
    }
}
