import Foundation
import FoundationModels

// Best-of-N sampling. A small model gets a great deal more reliable when it
// is allowed several attempts and something *other than the model* picks the
// winner. The framework already owns that something: the output
// `VerifierChain`. Scoring each candidate by which verifiers it satisfies —
// weighted, so a schema check can outrank a style check — is strictly more
// informative than taking whichever candidate the model emitted first, and it
// is the reason the selection policies here are verifier-driven rather than
// model-driven.
//
// Everything in this file is deterministic and off-device except the model
// call itself, which is reached through `LoopCore.invokeModel` so retries,
// deadlines, and error mapping behave exactly as they do for a single-
// candidate turn.

// MARK: - Selection

/// How ``SamplingStrategy/bestOf(n:selection:variation:)`` picks a winner
/// from the candidates it drew.
///
/// The two policies **agree whenever any candidate passes the whole chain**:
/// a fully-passing candidate always earns the maximum score, and scoring
/// ties break toward the earliest candidate. They differ in two ways that
/// do matter:
///
/// - **Cost.** ``firstPassing`` draws lazily and stops the moment a
///   candidate passes, so a lucky first draw costs exactly one model call.
///   ``weightedVerifierScore(weights:)`` always draws all `n`.
/// - **Which candidate seeds the repair turn** when *no* candidate passes.
///   ``firstPassing`` falls back to the best-scoring candidate under uniform
///   weights; ``weightedVerifierScore(weights:)`` uses the caller's weights,
///   so the candidate that satisfied the verifiers the caller cares about
///   most is the one that gets repaired.
///
/// Because agreement-rate confidence needs at least two candidates,
/// ``firstPassing`` frequently reports no confidence at all (it stopped at
/// one). Callers who want the signal on every turn should use
/// ``weightedVerifierScore(weights:)``.
public enum SelectionPolicy: Sendable, Equatable {
    /// Draw candidates one at a time and take the first that passes every
    /// chain member. If none passes, take the highest-scoring candidate
    /// under uniform weights.
    case firstPassing
    /// Draw all `n` candidates, score each as the weighted fraction of
    /// chain members it satisfied, and take the highest score (ties break
    /// toward the earliest candidate).
    ///
    /// `weights` is keyed by ``Verifier/name``; a member with no entry
    /// weighs `1.0`, and negative weights are clamped to zero. An empty
    /// dictionary — the default — is uniform weighting.
    case weightedVerifierScore(weights: [String: Double] = [:])

    /// Weight applied to the chain member named `verifier`.
    func weight(for verifier: String) -> Double {
        switch self {
        case .firstPassing:
            return 1
        case .weightedVerifierScore(let weights):
            return max(0, weights[verifier] ?? 1)
        }
    }

    /// `true` when the policy is allowed to stop drawing early.
    var stopsAtFirstPass: Bool {
        if case .firstPassing = self { return true }
        return false
    }
}

// MARK: - Variation

/// How the base ``GenerationOptions`` are perturbed per candidate.
///
/// Best-of-N buys nothing if every sample is the same sample. The default
/// therefore *overrides* the run's temperature with an ascending ladder
/// rather than inheriting it: a caller who sets `temperature` for a
/// single-candidate run has expressed a preference about one draw, not
/// about the spread of a population. Pass ``fixed`` to leave the base
/// options untouched and rely on the model's own sampling nondeterminism.
///
/// A conformer that ignores ``GenerationOptions`` (a test fake, a one-shot
/// HTTP backend) simply returns whatever it returns; nothing here depends
/// on the variation actually taking effect.
public struct SampleVariation: Sendable, Equatable {
    /// Temperature for candidate 0. `nil` leaves the base options'
    /// temperature untouched for every candidate.
    public var baseTemperature: Double?
    /// Added to the temperature for each subsequent candidate.
    public var temperatureStep: Double
    /// Upper clamp applied to the derived temperature.
    public var maximumTemperature: Double
    /// When non-nil, candidate `i` is drawn with
    /// `SamplingMode.random(top:seed:)` at `seedBase &+ UInt64(i)`, making
    /// a whole best-of-N draw reproducible. `nil` leaves the base options'
    /// sampling mode alone.
    public var seedBase: UInt64?
    /// `top` k used with ``seedBase``.
    public var topK: Int

    /// Creates a variation. `temperatureStep` and `topK` are
    /// precondition-checked.
    public init(
        baseTemperature: Double? = 0.3,
        temperatureStep: Double = 0.25,
        maximumTemperature: Double = 1.0,
        seedBase: UInt64? = nil,
        topK: Int = 50
    ) {
        precondition(temperatureStep >= 0, "temperatureStep must be non-negative")
        precondition(topK > 0, "topK must be positive")
        self.baseTemperature = baseTemperature
        self.temperatureStep = temperatureStep
        self.maximumTemperature = maximumTemperature
        self.seedBase = seedBase
        self.topK = topK
    }

    /// Ascending temperature ladder 0.3, 0.55, 0.8, 1.0, 1.0… — enough
    /// spread to make candidates genuinely different without pushing the
    /// tail of the distribution into incoherence.
    public static let `default` = SampleVariation()

    /// No perturbation: every candidate is drawn with the run's own
    /// ``GenerationOptions``. Diversity then comes only from the model's
    /// sampling nondeterminism, which is zero under greedy decoding.
    public static let fixed = SampleVariation(
        baseTemperature: nil,
        temperatureStep: 0,
        maximumTemperature: 1.0,
        seedBase: nil,
        topK: 50
    )

    /// Temperature for candidate `index`, or `nil` to leave it untouched.
    func temperature(forSample index: Int) -> Double? {
        guard let baseTemperature else { return nil }
        let raw = baseTemperature + temperatureStep * Double(max(0, index))
        return min(max(0, raw), maximumTemperature)
    }

    /// Seed for candidate `index`, or `nil` to leave sampling mode alone.
    func seed(forSample index: Int) -> UInt64? {
        seedBase.map { $0 &+ UInt64(max(0, index)) }
    }
}

// MARK: - Strategy

/// How many candidates a control-loop turn draws, and how it chooses one.
///
/// ``single`` is the framework default and the historical behavior: one
/// model call per turn, gated by the output chain.
/// ``bestOf(n:selection:variation:)`` draws up to `n` candidates *per turn*,
/// scores each against the same chain, and hands exactly one to the normal
/// verdict disposition — so pass, repair, reject, and escalate all keep
/// their meanings.
///
/// **Best-of-N multiplies model calls.** ``Budget/maxTurns`` bounds loop
/// iterations, not invocations; a run with `maxTurns: 4` and `bestOf(n: 5)`
/// can issue twenty model calls. Cap the real cost with
/// ``Budget/maxSamples`` and watch ``BudgetUsage/samples``.
///
/// Only the free-form phase samples. Structured extraction is a
/// constrained-decoding pass over an already-settled reasoning text, and
/// streaming runs draw a single candidate — there is no useful way to
/// stream `n` alternatives and still emit one coherent chunk sequence.
public enum SamplingStrategy: Sendable, Equatable {
    /// One candidate per turn (the default).
    case single
    /// Up to `n` candidates per turn, selected by `selection` and
    /// perturbed by `variation`. `n` below 1 is treated as 1.
    case bestOf(
        n: Int,
        selection: SelectionPolicy = .weightedVerifierScore(),
        variation: SampleVariation = .default
    )

    /// Maximum number of candidates a single turn may draw.
    public var sampleCount: Int {
        switch self {
        case .single: return 1
        case .bestOf(let n, _, _): return max(1, n)
        }
    }

    /// `true` when this strategy routes turns through ``BestOfNSampler``.
    public var isBestOfN: Bool {
        if case .bestOf = self { return true }
        return false
    }
}

// MARK: - Draw results

/// One candidate drawn by a best-of-N turn, with the verifier evidence
/// that produced its score.
public struct SampledCandidate: Sendable, Equatable {
    /// One chain member's verdict on this candidate, with the weight the
    /// selection policy applied — enough to audit the score after the fact.
    public struct MemberVerdict: Sendable, Equatable {
        /// Name of the chain member.
        public let verifier: String
        /// Its verdict on this candidate.
        public let verdict: Verdict
        /// Weight the selection policy gave this member.
        public let weight: Double

        /// Creates a member verdict.
        public init(verifier: String, verdict: Verdict, weight: Double) {
            self.verifier = verifier
            self.verdict = verdict
            self.weight = weight
        }
    }

    /// 0-based draw order within the turn.
    public let index: Int
    /// The model's output for this candidate.
    public let output: String
    /// Per-member verdicts, in chain order. Shorter than the chain when a
    /// terminal verdict stopped the evaluation early.
    public let memberVerdicts: [MemberVerdict]
    /// Weighted fraction of the chain this candidate satisfied, in
    /// `[0, 1]`. Members never reached (because a terminal verdict stopped
    /// the evaluation) count as unsatisfied. An empty chain scores `1`.
    public let score: Double
    /// Chain-level verdict, folded exactly as
    /// ``VerifierChain/Mode/collectAll(maxDiagnostics:)`` would fold it.
    public let verdict: Verdict
    /// Individual repair diagnostics gathered for this candidate, or the
    /// single terminating diagnostic when ``isDisqualified``.
    public let diagnostics: [Diagnostic]
    /// `true` when a chain member returned ``Verdict/reject(_:)`` or
    /// ``Verdict/escalate(_:)``. A disqualified candidate is never selected
    /// while any other candidate survives — one poisoned sample must not be
    /// able to fail a run that also produced a clean one.
    public let isDisqualified: Bool

    /// Creates a candidate record.
    public init(
        index: Int,
        output: String,
        memberVerdicts: [MemberVerdict],
        score: Double,
        verdict: Verdict,
        diagnostics: [Diagnostic],
        isDisqualified: Bool
    ) {
        self.index = index
        self.output = output
        self.memberVerdicts = memberVerdicts
        self.score = score
        self.verdict = verdict
        self.diagnostics = diagnostics
        self.isDisqualified = isDisqualified
    }

    /// `true` when every chain member passed.
    public var passed: Bool { verdict.isPass }
}

/// Everything one best-of-N turn produced: the candidates, the winner, and
/// the agreement-rate confidence signal.
public struct BestOfNDraw: Sendable, Equatable {
    /// Candidates in draw order. Never empty.
    public let candidates: [SampledCandidate]
    /// Index into ``candidates`` of the selected candidate.
    public let selectedIndex: Int
    /// Mean pairwise ``AgreementRate`` across every drawn candidate, or
    /// `nil` when fewer than two candidates were drawn (a single sample has
    /// no one to agree with). High agreement among independently drawn
    /// candidates is evidence the model is confident; near-zero agreement
    /// is evidence it is guessing.
    public let agreement: Double?

    /// Creates a draw result.
    public init(candidates: [SampledCandidate], selectedIndex: Int, agreement: Double?) {
        precondition(!candidates.isEmpty, "a draw must contain at least one candidate")
        precondition(candidates.indices.contains(selectedIndex), "selectedIndex out of range")
        self.candidates = candidates
        self.selectedIndex = selectedIndex
        self.agreement = agreement
    }

    /// The selected candidate.
    public var selected: SampledCandidate { candidates[selectedIndex] }

    /// Every candidate's score, in draw order — the payload of
    /// ``TraceEvent/bestOfNSampled(runID:candidates:scores:agreement:selectedIndex:)``.
    public var scores: [Double] { candidates.map(\.score) }
}

// MARK: - Agreement rate

/// Deterministic, off-device self-consistency measure over a set of
/// candidate texts.
///
/// Agreement is the mean pairwise Jaccard overlap of normalized token sets.
/// It is deliberately *not* semantic: an embedding-based measure would need
/// a model call per candidate, would be non-deterministic across OS
/// versions, and would make the confidence signal unavailable in tests and
/// on unsupported devices. Token overlap is coarse but honest, cheap, and
/// reproducible — which is what a routing signal needs.
///
/// The type is public because the next layer up (model routing) consumes
/// the same measure over candidates it gathered itself.
public enum AgreementRate {
    /// Lowercased alphanumeric tokens of `text`, de-duplicated.
    ///
    /// Splitting on "not a letter and not a number" folds punctuation,
    /// whitespace, and markup away, so two candidates that differ only in
    /// formatting agree completely — the intent is to measure whether the
    /// model said the same *thing* twice.
    public static func tokens(_ text: String) -> Set<String> {
        var out: Set<String> = []
        var current = ""
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                out.insert(current)
                current = ""
            }
        }
        if !current.isEmpty { out.insert(current) }
        return out
    }

    /// Jaccard overlap of two texts' token sets, in `[0, 1]`.
    ///
    /// Two texts with no tokens at all (empty, or pure punctuation) agree
    /// perfectly — they are the same text as far as this measure can see.
    /// One empty against one non-empty agrees not at all.
    public static func jaccard(_ lhs: String, _ rhs: String) -> Double {
        similarity(tokens(lhs), tokens(rhs))
    }

    /// Jaccard overlap of two pre-computed token sets.
    public static func similarity(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        if lhs.isEmpty && rhs.isEmpty { return 1 }
        let union = lhs.union(rhs)
        guard !union.isEmpty else { return 1 }
        return Double(lhs.intersection(rhs).count) / Double(union.count)
    }

    /// Mean pairwise ``jaccard(_:_:)`` over `texts`, or `nil` when there
    /// are fewer than two texts to compare.
    public static func meanPairwise(_ texts: [String]) -> Double? {
        guard texts.count > 1 else { return nil }
        let sets = texts.map(tokens)
        var total = 0.0
        var pairs = 0
        for i in sets.indices {
            for j in sets.index(after: i)..<sets.endIndex {
                total += similarity(sets[i], sets[j])
                pairs += 1
            }
        }
        guard pairs > 0 else { return nil }
        return total / Double(pairs)
    }
}

// MARK: - Sampler

/// Draws and scores the candidates for one best-of-N turn.
///
/// The sampler owns *generation and selection only*. Budget enforcement,
/// retry, deadlines, and verdict disposition stay in ``LoopCore``, which is
/// what keeps a best-of-N turn and a single-candidate turn observably
/// identical from the run's point of view: same trace events per model
/// call, same verifier events per evaluation, same repair path.
struct BestOfNSampler: Sendable {
    /// Candidate count requested for the turn.
    let sampleCount: Int
    /// Winner-picking policy.
    let selection: SelectionPolicy
    /// Per-candidate ``GenerationOptions`` perturbation.
    let variation: SampleVariation
    /// The run's output chain, applied to every candidate.
    let chain: VerifierChain<String>
    /// Options the run was configured with, before per-candidate variation.
    let baseOptions: GenerationOptions

    /// Diagnostic cap applied when the chain is configured
    /// ``VerifierChain/Mode/shortCircuit``. Best-of-N always evaluates every
    /// member (a per-verifier score is undefined otherwise), so it needs a
    /// cap of its own for chains that never specified one.
    static let defaultDiagnosticCap = 8

    /// Draws candidates for one turn and returns the selection.
    ///
    /// Each candidate debits ``BudgetExhaustion/samples`` check-then-record
    /// and runs through ``LoopCore/invokeModel(usage:started:runContext:body:)``,
    /// so per-sample retry and the remaining-wall-clock deadline apply to
    /// every draw individually. Output tokens are recorded for *every*
    /// candidate, discarded ones included — they were generated and they
    /// cost what they cost.
    ///
    /// Running out of budget mid-draw is only fatal before the first
    /// candidate exists; after that the draw stops early and selects from
    /// what it has, leaving the next ``LoopCore/beginTurn(usage:started:runContext:)``
    /// to end the run. Throwing instead would discard finished work that
    /// might already pass the chain.
    func draw(
        prompt: String,
        modelClient: any ModelResponding,
        core: LoopCore,
        usage: inout BudgetUsage,
        started: ContinuousClock.Instant,
        runContext: RunContext
    ) async throws -> BestOfNDraw {
        var candidates: [SampledCandidate] = []

        for index in 0..<max(1, sampleCount) {
            try Task.checkCancellation()
            usage.recordElapsed(ContinuousClock.now - started)
            usage.toolCalls = await runContext.toolCallMeter.count
            if let exhaustion = core.budget.exhaustion(afterAdding: .samples, to: usage) {
                if candidates.isEmpty {
                    throw await core.exhausted(exhaustion, usage: usage, runContext: runContext)
                }
                break
            }
            usage.recordSample()

            let options = baseOptions.varied(forSample: index, by: variation)
            let output = try await core.invokeModel(
                usage: &usage,
                started: started,
                runContext: runContext
            ) {
                try await modelClient.respond(to: prompt, options: options)
            }
            try Task.checkCancellation()
            usage.recordOutputTokens(Budget.approximateTokens(output))

            let memberVerdicts = try await core.evaluateMembers(
                chain: chain,
                input: output,
                runContext: runContext,
                weight: selection.weight(for:)
            )
            let candidate = score(index: index, output: output, memberVerdicts: memberVerdicts)
            candidates.append(candidate)
            if selection.stopsAtFirstPass, candidate.passed { break }
        }

        let selectedIndex = select(from: candidates)
        let draw = BestOfNDraw(
            candidates: candidates,
            selectedIndex: selectedIndex,
            agreement: AgreementRate.meanPairwise(candidates.map(\.output))
        )
        await runContext.tracer.record(
            .bestOfNSampled(
                runID: runContext.runID,
                candidates: draw.candidates.count,
                scores: draw.scores,
                agreement: draw.agreement,
                selectedIndex: draw.selectedIndex
            )
        )
        return draw
    }

    /// Folds one candidate's per-member verdicts into a chain verdict, a
    /// diagnostic list, and a weighted score.
    ///
    /// The chain verdict is folded exactly as
    /// ``VerifierChain/Mode/collectAll(maxDiagnostics:)`` folds it, so a
    /// best-of-N repair prompt carries the same evidence a single-candidate
    /// repair prompt would.
    func score(
        index: Int,
        output: String,
        memberVerdicts: [SampledCandidate.MemberVerdict]
    ) -> SampledCandidate {
        var totalWeight = 0.0
        var earnedWeight = 0.0
        for member in chain.members {
            totalWeight += selection.weight(for: member.name)
        }
        var repairs: [Diagnostic] = []
        var terminal: Verdict?
        for member in memberVerdicts {
            switch member.verdict {
            case .pass:
                earnedWeight += member.weight
            case .repair(let diagnostic):
                if repairs.count < diagnosticCap { repairs.append(diagnostic) }
            case .reject, .escalate:
                terminal = member.verdict
            }
        }

        let score = totalWeight > 0 ? earnedWeight / totalWeight : 1
        if let terminal {
            return SampledCandidate(
                index: index,
                output: output,
                memberVerdicts: memberVerdicts,
                score: score,
                verdict: terminal,
                diagnostics: [terminal.diagnostic].compactMap { $0 },
                isDisqualified: true
            )
        }
        guard !repairs.isEmpty else {
            return SampledCandidate(
                index: index,
                output: output,
                memberVerdicts: memberVerdicts,
                score: score,
                verdict: .pass,
                diagnostics: [],
                isDisqualified: false
            )
        }
        return SampledCandidate(
            index: index,
            output: output,
            memberVerdicts: memberVerdicts,
            score: score,
            verdict: .repair(.combined(repairs, verifier: chain.name)),
            diagnostics: repairs,
            isDisqualified: false
        )
    }

    /// Picks the winning candidate index.
    ///
    /// Disqualified candidates are excluded while any candidate survives.
    /// If *every* candidate was terminally rejected or escalated, the first
    /// one is selected so the run fails with a real verdict rather than
    /// pretending nothing happened.
    func select(from candidates: [SampledCandidate]) -> Int {
        let eligible = candidates.filter { !$0.isDisqualified }
        guard !eligible.isEmpty else { return 0 }
        if selection.stopsAtFirstPass, let first = eligible.first(where: \.passed) {
            return first.index
        }
        var best = eligible[0]
        for candidate in eligible.dropFirst() where candidate.score > best.score {
            best = candidate
        }
        return best.index
    }

    /// Repair diagnostics retained per candidate.
    private var diagnosticCap: Int {
        switch chain.mode {
        case .shortCircuit: return Self.defaultDiagnosticCap
        case .collectAll(let maxDiagnostics): return max(1, maxDiagnostics)
        }
    }
}
