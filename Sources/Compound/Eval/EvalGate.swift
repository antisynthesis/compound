import Foundation

/// CI gate over ``EvalReport``s: an absolute pass-rate floor plus a
/// regression check against a stored baseline report.
///
/// The gate fails when either
/// - the candidate's pass rate is below ``passRateThreshold``, or
/// - the candidate's pass rate dropped more than ``tolerance`` below the
///   baseline's pass rate.
///
/// Independently of the pass/fail verdict, ``compare(baseline:candidate:)``
/// lists every per-case regression (a case that passed in the baseline but
/// not in the candidate), so CI logs show *which* behavior changed, not
/// just that a number moved.
public struct EvalGate: Sendable, Codable, Equatable {
    /// Minimum acceptable candidate pass rate in `[0.0, 1.0]`.
    public let passRateThreshold: Double
    /// Maximum acceptable drop in pass rate relative to the baseline.
    /// `0.0` means the candidate may never score below the baseline.
    public let tolerance: Double

    /// Creates a gate.
    public init(passRateThreshold: Double = 1.0, tolerance: Double = 0.0) {
        precondition((0.0...1.0).contains(passRateThreshold), "passRateThreshold must be in [0, 1]")
        precondition(tolerance >= 0.0, "tolerance must be non-negative")
        self.passRateThreshold = passRateThreshold
        self.tolerance = tolerance
    }

    /// One case that passed in the baseline but not in the candidate.
    public struct CaseRegression: Sendable, Codable, Equatable {
        /// Identifier of the regressed case.
        public let caseID: String
        /// Short description of the candidate's failure (failed
        /// predicates, error reason, or timeout).
        public let detail: String
    }

    /// Verdict of ``compare(baseline:candidate:)``.
    public struct GateResult: Sendable, Codable, Equatable {
        /// `true` when the candidate clears both the absolute threshold
        /// and the baseline tolerance.
        public let passed: Bool
        /// Baseline pass rate.
        public let baselinePassRate: Double
        /// Candidate pass rate.
        public let candidatePassRate: Double
        /// Cases that passed in the baseline but not in the candidate.
        public let regressions: [CaseRegression]
        /// Human-readable reasons the gate failed; empty when `passed`.
        public let reasons: [String]
    }

    /// Compares `candidate` against `baseline` and returns the gate
    /// verdict. Regressions are matched by ``EvalCase/id``; cases present
    /// in only one report are ignored for regression purposes (they still
    /// affect the pass rates).
    public func compare(baseline: EvalReport, candidate: EvalReport) -> GateResult {
        let baselineByID = Dictionary(
            baseline.cases.map { ($0.caseID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var regressions: [CaseRegression] = []
        for c in candidate.cases {
            guard let base = baselineByID[c.caseID], base.passed, !c.passed else { continue }
            regressions.append(CaseRegression(caseID: c.caseID, detail: Self.failureDetail(of: c)))
        }

        var reasons: [String] = []
        if candidate.passRate < passRateThreshold {
            reasons.append(
                "pass rate \(Self.percent(candidate.passRate)) is below threshold \(Self.percent(passRateThreshold))"
            )
        }
        if candidate.passRate < baseline.passRate - tolerance {
            reasons.append(
                "pass rate \(Self.percent(candidate.passRate)) regressed more than \(Self.percent(tolerance)) below baseline \(Self.percent(baseline.passRate))"
            )
        }

        return GateResult(
            passed: reasons.isEmpty,
            baselinePassRate: baseline.passRate,
            candidatePassRate: candidate.passRate,
            regressions: regressions,
            reasons: reasons
        )
    }

    private static func failureDetail(of outcome: EvalReport.CaseOutcome) -> String {
        switch outcome.result {
        case .completed(_, let checks, _):
            let failed = checks
                .filter { !$0.check.passed }
                .map { "\($0.name): \($0.check.message ?? "failed")" }
            return failed.isEmpty ? "failed" : failed.joined(separator: "; ")
        case .errored(let reason, _):
            return "errored: \(reason)"
        case .timedOut(let elapsed):
            return "timed out after \(elapsed)"
        }
    }

    private static func percent(_ rate: Double) -> String {
        String(format: "%.1f%%", rate * 100)
    }
}
