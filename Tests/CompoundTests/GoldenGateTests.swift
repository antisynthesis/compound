import Foundation
import Testing
@testable import Compound

/// CI gate over the golden eval suite (`Tests/CompoundTests/Golden/`).
///
/// The suite runs every golden scenario through ``EvalRunner`` against
/// fakes, normalizes the resulting ``EvalReport``, and compares it to the
/// committed baseline at `Evals/baseline.json` with ``EvalGate``. A
/// behavior change that flips any case from pass to fail fails the build
/// and names the case.
///
/// ## Regenerating the baseline
///
/// The baseline is committed on purpose: reviewing its diff is how a
/// deliberate behavior change gets noticed. To regenerate after such a
/// change, run
///
/// ```
/// REGENERATE_EVAL_BASELINE=1 swift test --filter GoldenGate
/// ```
///
/// and commit the resulting `Evals/baseline.json` in the same change that
/// caused it. Regeneration refuses to write a report with any failing
/// case — a red baseline would gate nothing forever.
// Serialized so the gating test — which is also the regeneration path —
// runs before the tests that read the baseline back, and so a regeneration
// never has a reader observing the file mid-replacement.
@Suite("GoldenGate", .serialized)
struct GoldenGateTests {

    /// Environment variable that switches this suite from gating to
    /// regenerating.
    static let regenerateKey = "REGENERATE_EVAL_BASELINE"

    /// `true` when this run is regenerating the baseline rather than
    /// gating against it. The tests that *read* the baseline back are
    /// disabled in that mode: during a regeneration the file on disk is
    /// mid-replacement, and asserting against it would report the change
    /// being blessed as a failure.
    static var isRegenerating: Bool {
        ProcessInfo.processInfo.environment[regenerateKey] == "1"
    }

    /// Repository root, derived from this file's compile-time path:
    /// `<root>/Tests/CompoundTests/GoldenGateTests.swift`.
    static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The committed baseline. Deliberately outside any SwiftPM target
    /// directory: it is a repository artifact, not a bundled resource, and
    /// keeping it out of `Sources/`/`Tests/` avoids an unused-resource
    /// warning and a `Package.swift` change.
    static let baselineURL = repositoryRoot.appending(path: "Evals/baseline.json")

    /// Gate configuration: every golden case must pass, and no drop from
    /// the baseline is tolerated. These are fakes on a fixed script — a
    /// flaky golden case is a bug in the case, not a reason to loosen the
    /// gate.
    static let gate = EvalGate(passRateThreshold: 1.0, tolerance: 0.0)

    @Test("golden suite holds the committed baseline")
    func goldenSuiteHoldsBaseline() async throws {
        let candidate = try await GoldenSuite.runner
            .run(GoldenSuite.evalSuite, against: GoldenSuite.target)
            .normalizedForBaseline()

        if Self.isRegenerating {
            guard candidate.passRate == 1.0 else {
                Issue.record(
                    """
                    Refusing to regenerate \(Self.baselineURL.path): \
                    \(candidate.failed) case(s) failed. Fix them first.

                    \(candidate.detailedReport())
                    """
                )
                return
            }
            try FileManager.default.createDirectory(
                at: Self.baselineURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try candidate.jsonData().write(to: Self.baselineURL, options: .atomic)
        }

        let baseline = try Self.loadBaseline()
        let result = Self.gate.compare(baseline: baseline, candidate: candidate)

        for regression in result.regressions {
            Issue.record("golden regression — \(regression.caseID): \(regression.detail)")
        }
        #expect(
            result.passed,
            """
            \(result.reasons.joined(separator: "; "))

            \(candidate.detailedReport())
            """
        )
    }

    @Test("golden suite covers the same cases as the baseline", .enabled(if: !GoldenGateTests.isRegenerating))
    func caseSetMatchesBaseline() async throws {
        // The gate compares pass rates and per-case verdicts, so a case
        // that silently disappears from the suite would never trip it.
        // Deleting a golden case must be a baseline change too.
        let baseline = try Self.loadBaseline()
        let suiteIDs = GoldenSuite.cases.map(\.id)
        #expect(Set(suiteIDs).count == suiteIDs.count, "golden case ids must be unique")
        #expect(suiteIDs == baseline.cases.map(\.caseID))
    }

    @Test("baseline records the environment but the gate ignores it", .enabled(if: !GoldenGateTests.isRegenerating))
    func environmentIsRecordedButNotGated() async throws {
        let baseline = try Self.loadBaseline()
        let environment = try #require(
            baseline.environment,
            "the baseline should record which host produced it"
        )
        #expect(!environment.osVersion.isEmpty)
        #expect(!environment.modelAvailability.isEmpty)

        // A baseline captured on a host without the on-device model must
        // still gate a run on a host that has it, and vice versa.
        let elsewhere = EvalReport(
            suiteName: baseline.suiteName,
            started: baseline.started,
            finished: baseline.finished,
            cases: baseline.cases,
            environment: .init(osVersion: "Some Other OS 99.0", modelAvailability: "unavailable: deviceNotEligible")
        )
        #expect(Self.gate.compare(baseline: baseline, candidate: elsewhere).passed)
    }

    @Test("committed baseline carries no clock- or UUID-derived values", .enabled(if: !GoldenGateTests.isRegenerating))
    func baselineIsNormalized() throws {
        // If any of these drift, `normalizedForBaseline()` stopped covering
        // a field and every regeneration will produce a noisy diff.
        let baseline = try Self.loadBaseline()
        let epoch = Date(timeIntervalSince1970: 0)
        #expect(baseline.started == epoch)
        #expect(baseline.finished == epoch)
        for outcome in baseline.cases {
            #expect(outcome.runID == UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))
            switch outcome.result {
            case .completed(_, _, let elapsed):
                #expect(elapsed == .zero)
            case .errored(_, let elapsed), .timedOut(let elapsed):
                #expect(elapsed == .zero)
            }
        }
    }

    @Test("gate catches a regression in a golden case", .enabled(if: !GoldenGateTests.isRegenerating))
    func gateCatchesRegression() throws {
        // Proves the gate is wired to fail, not merely to run: flip one
        // baseline case to failing in the candidate and expect a verdict.
        let baseline = try Self.loadBaseline()
        let victim = try #require(baseline.cases.first)
        let regressed = EvalReport(
            suiteName: baseline.suiteName,
            started: baseline.started,
            finished: baseline.finished,
            cases: baseline.cases.map { c in
                guard c.caseID == victim.caseID else { return c }
                return EvalReport.CaseOutcome(
                    caseID: c.caseID,
                    prompt: c.prompt,
                    runID: c.runID,
                    result: .completed(
                        output: "regressed",
                        checks: [.init(name: "synthetic", check: .fail("synthetic regression"))],
                        elapsed: .zero
                    )
                )
            },
            environment: baseline.environment
        )
        let result = Self.gate.compare(baseline: baseline, candidate: regressed)
        #expect(!result.passed)
        #expect(result.regressions.map(\.caseID) == [victim.caseID])
    }

    // MARK: - Helpers

    private static func loadBaseline() throws -> EvalReport {
        guard FileManager.default.fileExists(atPath: baselineURL.path) else {
            throw BaselineMissing(path: baselineURL.path, key: regenerateKey)
        }
        return try EvalReport(jsonData: Data(contentsOf: baselineURL))
    }

    private struct BaselineMissing: Error, CustomStringConvertible {
        let path: String
        let key: String
        var description: String {
            "no golden baseline at \(path) — regenerate it with `\(key)=1 swift test --filter GoldenGate`"
        }
    }
}
