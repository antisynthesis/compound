import Foundation
import Testing
@testable import Compound

/// CI gate over the memory eval suite (`Tests/CompoundTests/Memory/`).
///
/// Runs every memory case through ``MemoryEvalRunner`` against the
/// deterministic fixture world, normalizes the resulting
/// ``MemoryEvalReport``, and compares it to the committed baseline at
/// `Evals/memory-baseline.json` with ``EvalGate``. A behavior change that
/// flips any case fails the build and names the case.
///
/// ## Regenerating the baseline
///
/// ```
/// REGENERATE_MEMORY_BASELINE=1 swift test --filter MemoryGoldenGate
/// ```
///
/// and commit the resulting `Evals/memory-baseline.json` in the same change
/// that caused it.
///
/// ## Why the tolerance is not zero
///
/// ``GoldenGateTests`` gates at `passRateThreshold: 1.0, tolerance: 0.0`
/// because every golden case is a fake on a fixed script, so a red case is
/// a bug by definition. This suite is different in kind: it deliberately
/// contains adversarial families that deterministic memory systems are
/// *known* to fail — cross-lingual aliasing and identifier obfuscation,
/// where ForgetEval puts deterministic systems at 0/38 and at or below 5%
/// respectively. Those cases are in the suite so the weakness is visible in
/// the committed artifact instead of absent from it, and a threshold of 1.0
/// would make committing an honest baseline impossible.
///
/// So the gate is:
///
/// - ``EvalGate/passRateThreshold`` `0.75` — an absolute floor comfortably
///   below the current rate but well above what a system that stopped
///   forgetting would score. It is a floor on the *suite*, not a target: if
///   the known-failing families ever grow to a quarter of the suite this
///   number must be re-argued, not quietly lowered.
/// - ``EvalGate/tolerance`` `0.0` — no drop from the committed baseline is
///   tolerated. The threshold absorbs the *known* failures, which are
///   already recorded in the baseline as failing rows; it must not also
///   absorb a *new* one. Combined, the two mean "you may ship a suite with
///   documented gaps, but you may not widen them silently."
///
/// Regeneration refuses to write a baseline the gate itself would reject,
/// which is the same rule ``GoldenGateTests`` enforces with `passRate == 1`,
/// expressed against this suite's threshold rather than against perfection.
// Serialized so the gating test — which is also the regeneration path —
// runs before the tests that read the baseline back, and so a regeneration
// never has a reader observing the file mid-replacement.
@Suite("MemoryGoldenGate", .serialized)
struct MemoryGoldenGateTests {

    /// Environment variable that switches this suite from gating to
    /// regenerating.
    static let regenerateKey = "REGENERATE_MEMORY_BASELINE"

    /// `true` when this run is regenerating rather than gating. The tests
    /// that *read* the baseline back are disabled in that mode: during a
    /// regeneration the file on disk is mid-replacement.
    static var isRegenerating: Bool {
        ProcessInfo.processInfo.environment[regenerateKey] == "1"
    }

    /// Repository root, derived from this file's compile-time path:
    /// `<root>/Tests/CompoundTests/MemoryGoldenGateTests.swift`.
    static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The committed baseline. Sits beside `Evals/baseline.json` and
    /// outside any SwiftPM target directory, for the same reason: it is a
    /// repository artifact, not a bundled resource.
    static let baselineURL = repositoryRoot.appending(path: "Evals/memory-baseline.json")

    /// Gate configuration. See the type doc comment for why these numbers
    /// differ from the golden gate's.
    static let gate = EvalGate(passRateThreshold: 0.75, tolerance: 0.0)

    // MARK: - Gate

    @Test("memory suite holds the committed baseline")
    func memorySuiteHoldsBaseline() async throws {
        let candidate = try await Self.runCandidate()

        if Self.isRegenerating {
            guard candidate.passRate >= Self.gate.passRateThreshold else {
                Issue.record(
                    """
                    Refusing to regenerate \(Self.baselineURL.path): pass rate \
                    \(candidate.passRate) is below the gate's own threshold \
                    \(Self.gate.passRateThreshold). A baseline the gate would \
                    reject gates nothing.

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
        let result = Self.gate.compare(
            baseline: baseline.evalReport(),
            candidate: candidate.evalReport()
        )

        for regression in result.regressions {
            Issue.record("memory regression — \(regression.caseID): \(regression.detail)")
        }
        #expect(
            result.passed,
            """
            \(result.reasons.joined(separator: "; "))

            \(candidate.detailedReport())
            """
        )
    }

    // MARK: - Structural checks

    @Test("memory suite covers the same cases as the baseline", .enabled(if: !MemoryGoldenGateTests.isRegenerating))
    func caseSetMatchesBaseline() throws {
        // The gate compares pass rates and per-case verdicts, so a case that
        // silently disappears from the suite would never trip it. Deleting a
        // memory case — especially one of the known-failing adversarial ones,
        // which would *raise* the pass rate — must be a baseline change too.
        let baseline = try Self.loadBaseline()
        let suiteIDs = MemoryEvalCases.all.map(\.id)
        #expect(Set(suiteIDs).count == suiteIDs.count, "memory case ids must be unique")
        #expect(suiteIDs == baseline.cases.map(\.caseID))
    }

    @Test("baseline records the environment but the gate ignores it", .enabled(if: !MemoryGoldenGateTests.isRegenerating))
    func environmentIsRecordedButNotGated() throws {
        let baseline = try Self.loadBaseline()
        let environment = try #require(
            baseline.environment,
            "the baseline should record which host produced it"
        )
        #expect(!environment.osVersion.isEmpty)
        #expect(!environment.modelAvailability.isEmpty)

        // A baseline captured on a host without the on-device model must
        // still gate a run on a host that has it, and vice versa.
        let elsewhere = MemoryEvalReport(
            suiteName: baseline.suiteName,
            runID: baseline.runID,
            started: baseline.started,
            finished: baseline.finished,
            cases: baseline.cases,
            environment: .init(osVersion: "Some Other OS 99.0", modelAvailability: "unavailable: deviceNotEligible"),
            provenance: baseline.provenance,
            writePath: baseline.writePath
        )
        #expect(Self.gate.compare(baseline: baseline.evalReport(), candidate: elsewhere.evalReport()).passed)
    }

    @Test("baseline records its provenance", .enabled(if: !MemoryGoldenGateTests.isRegenerating))
    func baselineRecordsProvenance() throws {
        // MemDelta's lesson made mechanical: a memory number without its
        // confounds is not evidence. If the embedder, extractor, or
        // reconciler behind this baseline ever changes, that line moving in
        // the diff is the reviewer's cue that the pass rates below it are
        // measuring a different system.
        let baseline = try Self.loadBaseline()
        #expect(baseline.provenance.embedder == MemoryEvalHashEmbedder.identity)
        #expect(baseline.provenance.extractor == MemoryEvalFixtures.extractorIdentity)
        #expect(baseline.provenance.reconciler == MemoryEvalFixtures.reconcilerIdentity)
        #expect(baseline.provenance.promptVersion == "none")
        // The suite is model-free end to end. A baseline claiming otherwise
        // means a model-backed hook was enabled without anyone noticing.
        #expect(baseline.writePath.modelCalls == 0)
    }

    @Test("committed baseline carries no clock- or UUID-derived values", .enabled(if: !MemoryGoldenGateTests.isRegenerating))
    func baselineIsNormalized() throws {
        // If any of these drift, `normalizedForBaseline()` stopped covering
        // a field and every regeneration will produce a noisy diff.
        let baseline = try Self.loadBaseline()
        let epoch = Date(timeIntervalSince1970: 0)
        #expect(baseline.started == epoch)
        #expect(baseline.finished == epoch)
        #expect(baseline.runID == UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))
        #expect(baseline.writePath.wallClockNanoseconds == 0)
        for outcome in baseline.cases {
            #expect(outcome.elapsed == .zero)
        }
    }

    @Test("baseline records the known-failing adversarial families", .enabled(if: !MemoryGoldenGateTests.isRegenerating))
    func knownWeaknessIsVisible() throws {
        // The point of shipping a case the system fails is that the failure
        // is legible. If someone deletes the obfuscation family to make the
        // number look better, this fails; if someone actually fixes alias
        // resolution, this fails too and asks them to update the claim.
        let baseline = try Self.loadBaseline()
        let obfuscation = baseline.cases.filter { $0.tags.contains("obfuscation") }
        #expect(!obfuscation.isEmpty, "the obfuscation family must stay in the suite")
        #expect(
            obfuscation.allSatisfy { !$0.passed },
            """
            An obfuscation case now passes. That is good news, but the doc \
            comments in MemoryEvalSuite.swift and this suite claim the \
            category is unsolved — update them along with this expectation.
            """
        )
    }

    @Test("gate catches a regression in a memory case", .enabled(if: !MemoryGoldenGateTests.isRegenerating))
    func gateCatchesRegression() throws {
        // Proves the gate is wired to fail, not merely to run: flip one
        // passing baseline case to failing in the candidate and expect a
        // verdict naming it.
        let baseline = try Self.loadBaseline()
        let passing = baseline.cases.filter(\.passed)
        let victim = try #require(passing.first)
        let regressed = MemoryEvalReport(
            suiteName: baseline.suiteName,
            runID: baseline.runID,
            started: baseline.started,
            finished: baseline.finished,
            cases: baseline.cases.map { c in
                guard c.caseID == victim.caseID else { return c }
                return MemoryEvalReport.CaseOutcome(
                    caseID: c.caseID,
                    query: c.query,
                    tags: c.tags,
                    passed: false,
                    missing: ["synthetic regression"],
                    forbidden: [],
                    retrievedIDs: c.retrievedIDs,
                    elapsed: .zero
                )
            },
            environment: baseline.environment,
            provenance: baseline.provenance,
            writePath: baseline.writePath
        )
        let result = Self.gate.compare(baseline: baseline.evalReport(), candidate: regressed.evalReport())
        #expect(!result.passed)
        #expect(result.regressions.map(\.caseID) == [victim.caseID])
    }

    // MARK: - Helpers

    /// Runs the suite against the fixture world and normalizes the result.
    static func runCandidate() async throws -> MemoryEvalReport {
        let world = try await MemoryEvalFixtures.make()
        // The write path here is fully deterministic — the fixture seeds its
        // facts directly and no model-backed hook is wired — so measuring
        // through a tracer that saw the whole setup is the honest way to
        // report zero, rather than hardcoding it.
        let tracer = InMemoryTracer()
        return try await MemoryEvalCases.runner
            .run(
                MemoryEvalCases.suite,
                against: world.memoryRetriever,
                provenance: MemoryEvalFixtures.provenance,
                writePath: await MemoryEvalReport.WritePathCost.measure(tracer: tracer)
            )
            .normalizedForBaseline()
    }

    private static func loadBaseline() throws -> MemoryEvalReport {
        guard FileManager.default.fileExists(atPath: baselineURL.path) else {
            throw BaselineMissing(path: baselineURL.path, key: regenerateKey)
        }
        return try MemoryEvalReport(jsonData: Data(contentsOf: baselineURL))
    }

    private struct BaselineMissing: Error, CustomStringConvertible {
        let path: String
        let key: String
        var description: String {
            "no memory baseline at \(path) — regenerate it with `\(key)=1 swift test --filter MemoryGoldenGate`"
        }
    }
}
