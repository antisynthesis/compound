import Foundation

/// The ledger of a run of an ``EvalSuite`` — what passed, what failed, and
/// what refused to even run.
///
/// Each case is either `completed` (the model produced an output and the
/// predicates judged it) or `errored` (the run itself threw — model
/// unavailable, budget exhausted, and so on). Both are surfaced in full.
/// The harness never swallows a failure to make the number look kinder.
public struct EvalReport: Sendable {
    /// Suite name (from ``EvalSuite/name``).
    public let suiteName: String
    /// Wall-clock instant the run started.
    public let started: Date
    /// Wall-clock instant the run finished.
    public let finished: Date
    /// Per-case outcomes in evaluation order.
    public let cases: [CaseOutcome]

    /// The full record of what one ``EvalCase`` did when it was made to prove
    /// itself — output, checks, errors, all of it, none of it sanded down.
    public struct CaseOutcome: Sendable {
        /// Identifier of the originating case.
        public let caseID: String
        /// Prompt used.
        public let prompt: String
        /// Outcome.
        public let result: Result

        /// Two honest endings and no third: the case completed and the
        /// predicates judged it, or the run itself threw before it could
        /// produce anything. A crash is not a pass.
        public enum Result: Sendable {
            /// The run produced `output`; `checks` are predicate outcomes.
            case completed(output: String, checks: [PredicateOutcome], elapsed: Duration)
            /// The run threw `reason` before producing an output.
            case errored(reason: String, elapsed: Duration)
        }

        /// One predicate's contribution to a `completed` outcome.
        public struct PredicateOutcome: Sendable {
            /// Predicate name.
            public let name: String
            /// Result of the predicate.
            public let check: EvalCheck
        }

        /// `true` if the case completed and every predicate passed.
        public var passed: Bool {
            switch result {
            case .completed(_, let checks, _):
                return checks.allSatisfy { $0.check.passed }
            case .errored:
                return false
            }
        }
    }

    /// Number of passing cases.
    public var passed: Int { cases.filter(\.passed).count }
    /// Number of failing cases.
    public var failed: Int { cases.count - passed }
    /// Passing fraction in `[0.0, 1.0]`.
    public var passRate: Double { cases.isEmpty ? 0 : Double(passed) / Double(cases.count) }
    /// Wall-clock duration of the run.
    public var elapsed: Duration { .seconds(finished.timeIntervalSince(started)) }

    /// Creates a report.
    public init(suiteName: String, started: Date, finished: Date, cases: [CaseOutcome]) {
        self.suiteName = suiteName
        self.started = started
        self.finished = finished
        self.cases = cases
    }

    /// Human-readable single-line summary suitable for CI logs.
    /// Programs should inspect the structured ``cases`` array instead.
    public func summary() -> String {
        let rate = (passRate * 100).rounded()
        return "[\(suiteName)] \(passed)/\(cases.count) passed (\(Int(rate))%)"
    }

    /// Verbose multi-line report listing every case and its checks.
    /// Useful when investigating a regression locally; CI typically
    /// prefers a JSON encoding.
    public func detailedReport() -> String {
        var out = summary() + "\n"
        for c in cases {
            switch c.result {
            case .completed(_, let checks, _):
                let mark = c.passed ? "ok" : "FAIL"
                out += "  \(mark) \(c.caseID)\n"
                if !c.passed {
                    for p in checks where !p.check.passed {
                        out += "    - \(p.name): \(p.check.message ?? "failed")\n"
                    }
                }
            case .errored(let reason, _):
                out += "  ERR \(c.caseID): \(reason)\n"
            }
        }
        return out
    }
}

