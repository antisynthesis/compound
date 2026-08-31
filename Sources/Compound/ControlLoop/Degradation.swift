import Foundation

// Degradation is the answer to a question the rest of the framework
// deliberately refuses to answer: what should happen on the *fourth*
// consecutive guardrail violation, the *third* deadline blown in a row, the
// model that reports itself unavailable every time it is asked?
//
// The per-run layers — Budget, retry, deadlines, the error taxonomy — are
// all scoped to one run and have no memory. That is correct for them and
// insufficient for an app: a device whose on-device model is wedged will
// happily accept run after run, burning battery to produce the same typed
// failure. The ladder here is the cross-run memory: typed failure signals
// feed per-class circuit breakers, breaker state maps to a capability rung,
// and the session applies the rung *before* it builds the run.
//
// Everything in this file is deterministic and off-device. The clock is
// injected, so cooldown behavior is exercised in tests without sleeping,
// and no part of the ladder needs a model to make its decisions.

// MARK: - Ladder

/// One rung of the degradation ladder: how much capability a run is
/// allowed to use.
///
/// The rungs are **cumulative**, not independent. ``noTools`` also reduces
/// context, and ``deterministicOnly`` also does both, because a ladder
/// whose rungs each removed exactly one thing would let a badly degraded
/// system keep the expensive capability it was on the way down to lose.
/// Compare rungs with `<`: a higher rung is a more degraded run.
public enum DegradedMode: String, Sendable, Equatable, Codable, CaseIterable, Comparable {
    /// No degradation: the run uses the session's configuration as written.
    case full
    /// The assembled prompt is squeezed to a fraction of the normal
    /// watermark (see ``CompoundSession/Configuration/reducedContextFactor``),
    /// dropping the lowest-scoring retrieved sources first.
    case reducedContext
    /// Tools are not registered for the run — the model answers from the
    /// assembled context alone — and context is reduced.
    case noTools
    /// No model call happens at all. The run either returns the
    /// caller-supplied fallback or throws
    /// ``CompoundError/degraded(mode:reason:)``.
    case deterministicOnly

    /// Severity rank; higher is more degraded.
    public var rung: Int {
        switch self {
        case .full: return 0
        case .reducedContext: return 1
        case .noTools: return 2
        case .deterministicOnly: return 3
        }
    }

    /// Orders rungs by ``rung``.
    public static func < (lhs: DegradedMode, rhs: DegradedMode) -> Bool {
        lhs.rung < rhs.rung
    }

    /// `true` when the run may invoke the model at all.
    public var allowsModelCalls: Bool { self < .deterministicOnly }
    /// `true` when the run registers the session's tools.
    public var allowsTools: Bool { self < .noTools }
    /// `true` when the run's assembled prompt is squeezed.
    public var reducesContext: Bool { self >= .reducedContext }

    /// The next milder rung, or ``full`` when already there. Used for the
    /// half-open probe: a probe that kept the full open-state restriction
    /// could never produce the success that closes the breaker.
    public var milder: DegradedMode {
        switch self {
        case .full, .reducedContext: return .full
        case .noTools: return .reducedContext
        case .deterministicOnly: return .noTools
        }
    }
}

// MARK: - Signals

/// Class of typed failure the health monitor tracks.
///
/// Signal classes are deliberately coarse — one breaker per class, not one
/// per error case — because the response to "the safety system keeps
/// blocking this" is the same whichever guardrail fired, and a breaker per
/// error case would need far more evidence before any of them tripped.
public enum DegradationSignal: String, Sendable, Equatable, Codable, CaseIterable {
    /// ``CompoundError/guardrailViolation(context:)`` — the on-device
    /// safety system blocked the prompt or the generation.
    case guardrailViolation
    /// A deadline or wall-clock cap tripped: ``BudgetExhaustion/wallClock``,
    /// ``BudgetExhaustion/firstToken``, or ``BudgetExhaustion/interChunkGap``.
    case deadline
    /// ``CompoundError/modelUnavailable(reason:)`` — no usable on-device
    /// model.
    case modelUnavailable
    /// Context pressure: ``CompoundError/contextWindowExceeded(promptTokens:)``
    /// or a session ledger crossing its high watermark.
    case contextPressure

    /// Classifies a typed error into a signal class, or `nil` when the
    /// error says nothing about the *system's* health.
    ///
    /// Verifier rejections, policy denials, and tool failures are
    /// deliberately unclassified: they are statements about one prompt or
    /// one caller, and tripping a breaker on them would degrade a healthy
    /// device because a user asked for something the policy forbids.
    public init?(_ error: CompoundError) {
        switch error {
        case .guardrailViolation:
            self = .guardrailViolation
        case .modelUnavailable:
            self = .modelUnavailable
        case .contextWindowExceeded:
            self = .contextPressure
        case .budgetExhausted(let kind, _):
            switch kind {
            case .wallClock, .firstToken, .interChunkGap:
                self = .deadline
            case .turns, .toolCalls, .repairAttempts, .outputTokens, .samples:
                return nil
            }
        case .verifierRejected, .escalationRequired, .policyDenied, .toolUnavailable,
             .toolDecodeFailed, .toolArgumentRejected, .toolOutputRejected,
             .toolAlreadyRegistered, .refusal, .unsupportedLanguage, .modelRateLimited,
             .cancelled, .degraded, .underlying:
            return nil
        }
    }
}

/// State of one signal class's circuit breaker.
public enum BreakerState: String, Sendable, Equatable, Codable {
    /// Healthy: runs proceed at ``DegradedMode/full``.
    case closed
    /// Tripped: runs proceed at the policy's mode for the class until the
    /// cooldown elapses.
    case open
    /// Cooldown elapsed: the next run is a probe at one rung milder than
    /// the open mode. Success closes the breaker; failure re-opens it.
    case halfOpen
}

/// One observed breaker state change, emitted as
/// ``TraceEvent/breakerTransitioned(runID:signal:from:to:failures:)``.
public struct BreakerTransition: Sendable, Equatable {
    /// Signal class whose breaker moved.
    public let signal: DegradationSignal
    /// State before the change.
    public let from: BreakerState
    /// State after the change.
    public let to: BreakerState
    /// Consecutive failures recorded for the class at the moment of the
    /// change.
    public let failures: Int

    /// Creates a transition record.
    public init(signal: DegradationSignal, from: BreakerState, to: BreakerState, failures: Int) {
        self.signal = signal
        self.from = from
        self.to = to
        self.failures = failures
    }
}

// MARK: - Policy

/// Maps breaker state plus signal class onto a ``DegradedMode``.
///
/// The mapping is data, not code, so an adopter can decide that repeated
/// guardrail violations mean "stop calling the model" while repeated
/// deadlines only mean "stop giving it tools" — the framework has no way
/// to know which trade-off an app wants.
public struct DegradationPolicy: Sendable, Equatable {
    /// Consecutive failures of a class required to trip its breaker.
    /// Missing entries use ``defaultThreshold``.
    public var thresholds: [DegradationSignal: Int]
    /// Mode applied while a class's breaker is open. Missing entries use
    /// ``defaultOpenMode``.
    public var openModes: [DegradationSignal: DegradedMode]
    /// How long a breaker stays open before it half-opens for a probe.
    public var cooldown: Duration
    /// Threshold for classes with no ``thresholds`` entry.
    public var defaultThreshold: Int
    /// Open-state mode for classes with no ``openModes`` entry.
    public var defaultOpenMode: DegradedMode

    /// Creates a policy. `defaultThreshold` below 1 is clamped to 1 — a
    /// breaker that trips on zero failures would open before anything
    /// happened.
    public init(
        thresholds: [DegradationSignal: Int] = [:],
        openModes: [DegradationSignal: DegradedMode] = [:],
        cooldown: Duration = .seconds(30),
        defaultThreshold: Int = 3,
        defaultOpenMode: DegradedMode = .reducedContext
    ) {
        self.thresholds = thresholds
        self.openModes = openModes
        self.cooldown = cooldown
        self.defaultThreshold = max(1, defaultThreshold)
        self.defaultOpenMode = defaultOpenMode
    }

    /// Framework defaults.
    ///
    /// Guardrail violations and model unavailability stop model calls
    /// outright: both are terminal per ``CompoundError/severity``, so a
    /// fourth attempt buys nothing but battery. Deadlines drop tools
    /// (tool round-trips are the usual reason a run runs long) and context
    /// pressure squeezes the prompt, which is the direct remedy.
    public static let `default` = DegradationPolicy(
        thresholds: [
            .guardrailViolation: 3,
            .deadline: 3,
            .modelUnavailable: 2,
            .contextPressure: 3
        ],
        openModes: [
            .guardrailViolation: .deterministicOnly,
            .deadline: .noTools,
            .modelUnavailable: .deterministicOnly,
            .contextPressure: .reducedContext
        ],
        cooldown: .seconds(30)
    )

    /// Consecutive-failure threshold for `signal`.
    public func threshold(for signal: DegradationSignal) -> Int {
        max(1, thresholds[signal] ?? defaultThreshold)
    }

    /// Mode applied while `signal`'s breaker is open.
    public func openMode(for signal: DegradationSignal) -> DegradedMode {
        openModes[signal] ?? defaultOpenMode
    }

    /// Mode implied by one breaker's state.
    ///
    /// A half-open breaker probes one rung milder than its open mode, so
    /// the probe is a genuine test of the capability that was withdrawn:
    /// a ``DegradedMode/deterministicOnly`` breaker probes with a real
    /// (tool-less) model call, which is the only way it can ever close.
    public func mode(for state: BreakerState, signal: DegradationSignal) -> DegradedMode {
        switch state {
        case .closed: return .full
        case .open: return openMode(for: signal)
        case .halfOpen: return openMode(for: signal).milder
        }
    }
}

// MARK: - Assessment

/// Snapshot of the ladder at the moment a run was about to start.
public struct HealthAssessment: Sendable, Equatable {
    /// Effective rung for the run.
    public let mode: DegradedMode
    /// Why that rung: the dominant open breaker, a manual override, or
    /// "healthy".
    public let reason: String
    /// Signal class that produced ``mode``, or `nil` when the mode came
    /// from a manual override or nothing is degraded.
    public let signal: DegradationSignal?
    /// Every breaker's state at assessment time.
    public let states: [DegradationSignal: BreakerState]

    /// Creates an assessment.
    public init(
        mode: DegradedMode,
        reason: String,
        signal: DegradationSignal?,
        states: [DegradationSignal: BreakerState]
    ) {
        self.mode = mode
        self.reason = reason
        self.signal = signal
        self.states = states
    }

    /// `true` when the run will not use the full configuration.
    public var isDegraded: Bool { mode != .full }
}

// MARK: - Monitor

/// Cross-run health tracker: one classic circuit breaker per
/// ``DegradationSignal``, plus the manual override and inspection surface
/// the facade exposes.
///
/// The monitor is an actor because it outlives any single run and is read
/// and written from every run concurrently. It is deliberately *fed* by
/// explicit ``record(_:runID:)`` / ``recordSuccess(runID:)`` calls from
/// ``CompoundSession`` rather than by hooks inside ``LoopCore``: the loop's
/// job is to bound one run, and threading long-lived health state through
/// it would make every loop path depend on state no single run owns.
///
/// # Example
/// ```swift
/// let health = HealthMonitor(policy: .default, tracer: tracer)
/// let session = CompoundSession(.init(assembler: assembler, health: health))
/// let mode = await session.currentDegradedMode()
/// ```
public actor HealthMonitor {
    /// State-to-mode mapping and breaker thresholds.
    public let policy: DegradationPolicy

    private let tracer: any Tracer
    private let now: @Sendable () -> ContinuousClock.Instant
    private var breakers: [DegradationSignal: Breaker] = [:]
    private var manualOverride: DegradedMode?

    /// Run identifier used when a transition is observed outside a run
    /// (a manual override, an inspection that crossed a cooldown).
    public static let unattributedRunID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    /// Creates a monitor.
    ///
    /// - Parameters:
    ///   - policy: Thresholds, cooldown, and state-to-mode mapping.
    ///   - tracer: Sink for ``TraceEvent/breakerTransitioned(runID:signal:from:to:failures:)``.
    ///   - now: Clock reading used for cooldown arithmetic. Injected so
    ///     tests exercise half-open transitions without sleeping.
    public init(
        policy: DegradationPolicy = .default,
        tracer: any Tracer = NullTracer(),
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.policy = policy
        self.tracer = tracer
        self.now = now
    }

    /// One signal class's breaker.
    private struct Breaker {
        var state: BreakerState = .closed
        var failures = 0
        var openedAt: ContinuousClock.Instant?
    }

    /// Records one typed failure signal.
    ///
    /// Closed breakers trip once ``DegradationPolicy/threshold(for:)``
    /// consecutive failures land. An open breaker's cooldown restarts —
    /// a system still failing has not earned a probe yet — and a failure
    /// during a half-open probe re-opens immediately, which is the whole
    /// point of the probe.
    public func record(_ signal: DegradationSignal, runID: UUID = HealthMonitor.unattributedRunID) async {
        var breaker = breakers[signal] ?? Breaker()
        breaker.failures += 1
        let from = breaker.state
        switch breaker.state {
        case .closed:
            if breaker.failures >= policy.threshold(for: signal) {
                breaker.state = .open
                breaker.openedAt = now()
            }
        case .halfOpen, .open:
            breaker.state = .open
            breaker.openedAt = now()
        }
        breakers[signal] = breaker
        if breaker.state != from {
            await emit(BreakerTransition(signal: signal, from: from, to: breaker.state, failures: breaker.failures), runID: runID)
        }
    }

    /// Classifies `error` and records it when it carries health
    /// information.
    ///
    /// - Returns: The signal class recorded, or `nil` when the error says
    ///   nothing about system health.
    @discardableResult
    public func record(_ error: CompoundError, runID: UUID = HealthMonitor.unattributedRunID) async -> DegradationSignal? {
        guard let signal = DegradationSignal(error) else { return nil }
        await record(signal, runID: runID)
        return signal
    }

    /// Records a successful run: half-open breakers close (the probe
    /// worked) and closed breakers forget their failure streak.
    ///
    /// Open breakers are untouched. A success recorded while a breaker is
    /// open came from a *degraded* run — evidence that the fallback rung
    /// works, not that the withdrawn capability is healthy again — and
    /// only a half-open probe can supply that evidence.
    public func recordSuccess(runID: UUID = HealthMonitor.unattributedRunID) async {
        for (signal, var breaker) in breakers {
            switch breaker.state {
            case .halfOpen:
                let from = breaker.state
                breaker.state = .closed
                breaker.failures = 0
                breaker.openedAt = nil
                breakers[signal] = breaker
                await emit(BreakerTransition(signal: signal, from: from, to: .closed, failures: 0), runID: runID)
            case .closed:
                breaker.failures = 0
                breakers[signal] = breaker
            case .open:
                continue
            }
        }
    }

    /// Advances any breaker whose cooldown has elapsed to
    /// ``BreakerState/halfOpen`` and returns the rung the next run should
    /// use.
    ///
    /// The most degraded open (or half-open) breaker wins: capability is
    /// withdrawn by whichever subsystem is sickest. A manual override
    /// replaces the computed rung outright — including overriding *down*
    /// to ``DegradedMode/full``, which is how an operator says "I know,
    /// run it anyway".
    public func assess(runID: UUID = HealthMonitor.unattributedRunID) async -> HealthAssessment {
        await expireCooldowns(runID: runID)

        var states: [DegradationSignal: BreakerState] = [:]
        var worst: (signal: DegradationSignal, mode: DegradedMode, failures: Int)?
        for signal in DegradationSignal.allCases {
            let breaker = breakers[signal] ?? Breaker()
            states[signal] = breaker.state
            let mode = policy.mode(for: breaker.state, signal: signal)
            guard mode != .full else { continue }
            if let current = worst, current.mode >= mode { continue }
            worst = (signal, mode, breaker.failures)
        }

        if let manualOverride {
            return HealthAssessment(
                mode: manualOverride,
                reason: "manual override",
                signal: nil,
                states: states
            )
        }
        guard let worst else {
            return HealthAssessment(mode: .full, reason: "healthy", signal: nil, states: states)
        }
        let state = states[worst.signal] ?? .closed
        return HealthAssessment(
            mode: worst.mode,
            reason: "breaker \(state.rawValue) for \(worst.signal.rawValue) after \(worst.failures) consecutive failures",
            signal: worst.signal,
            states: states
        )
    }

    /// Forces every run to a rung regardless of breaker state, or clears a
    /// previous override with `nil`.
    public func setOverride(_ mode: DegradedMode?) {
        manualOverride = mode
    }

    /// The active manual override, if any.
    public func override() -> DegradedMode? { manualOverride }

    /// Current state of one class's breaker, without advancing cooldowns.
    public func state(for signal: DegradationSignal) -> BreakerState {
        breakers[signal]?.state ?? .closed
    }

    /// Consecutive failures recorded for one class since it last closed.
    public func failures(for signal: DegradationSignal) -> Int {
        breakers[signal]?.failures ?? 0
    }

    /// Clears every breaker and the manual override.
    public func reset() {
        breakers.removeAll()
        manualOverride = nil
    }

    /// Moves breakers whose cooldown has elapsed from open to half-open.
    private func expireCooldowns(runID: UUID) async {
        for (signal, var breaker) in breakers where breaker.state == .open {
            guard let openedAt = breaker.openedAt, now() - openedAt >= policy.cooldown else { continue }
            breaker.state = .halfOpen
            breakers[signal] = breaker
            await emit(
                BreakerTransition(signal: signal, from: .open, to: .halfOpen, failures: breaker.failures),
                runID: runID
            )
        }
    }

    private func emit(_ transition: BreakerTransition, runID: UUID) async {
        await tracer.record(
            .breakerTransitioned(
                runID: runID,
                signal: transition.signal,
                from: transition.from,
                to: transition.to,
                failures: transition.failures
            )
        )
    }
}

// MARK: - Cascade router

/// One rung of the confidence cascade: a bundle of strategy changes that
/// makes the next attempt more thorough than the last.
///
/// Every knob here is feasible on-device and costs model calls, not model
/// *size* — there is no bigger model to route to. Escalation therefore
/// means drawing more samples, selecting among them more carefully, and
/// gating the result harder.
public struct EscalationStep: Sendable {
    /// Short label for traces and ``RoutedOutcome/appliedSteps``.
    public var label: String
    /// Candidate count for the attempt. `nil` keeps the current count.
    public var samples: Int?
    /// Selection policy for the attempt. `nil` keeps the current policy.
    public var selection: SelectionPolicy?
    /// Per-candidate ``GenerationOptions`` perturbation. `nil` keeps the
    /// current variation.
    public var variation: SampleVariation?
    /// Chain mode for the attempt — ``VerifierChain/Mode/collectAll(maxDiagnostics:)``
    /// surfaces every defect in one repair round. `nil` keeps the chain's
    /// mode.
    public var verifierMode: VerifierChain<String>.Mode?
    /// Verifiers appended to the output chain for the attempt. The chain
    /// re-sorts by `(cost, name)`, so an added verifier still runs in
    /// cheapest-first order.
    public var additionalVerifiers: [AnyVerifier<String>]

    /// Creates a step.
    public init(
        label: String,
        samples: Int? = nil,
        selection: SelectionPolicy? = nil,
        variation: SampleVariation? = nil,
        verifierMode: VerifierChain<String>.Mode? = nil,
        additionalVerifiers: [AnyVerifier<String>] = []
    ) {
        self.label = label
        self.samples = samples
        self.selection = selection
        self.variation = variation
        self.verifierMode = verifierMode
        self.additionalVerifiers = additionalVerifiers
    }

    /// Step that draws `n` candidates and scores them all — the cheapest
    /// way to get an agreement signal where there was none.
    public static func samples(_ n: Int) -> EscalationStep {
        EscalationStep(label: "samples-\(max(1, n))", samples: max(1, n), selection: .weightedVerifierScore())
    }

    /// Step that switches the selection policy without changing the draw.
    public static func selecting(_ policy: SelectionPolicy) -> EscalationStep {
        EscalationStep(label: "selection", selection: policy)
    }

    /// Step that tightens the gate: collect-all mode plus extra verifiers.
    public static func tightenVerifiers(
        _ verifiers: [AnyVerifier<String>],
        maxDiagnostics: Int = 8
    ) -> EscalationStep {
        EscalationStep(
            label: "tighten-verifiers",
            verifierMode: .collectAll(maxDiagnostics: maxDiagnostics),
            additionalVerifiers: verifiers
        )
    }

    /// Applies this step's sampling changes on top of `current`.
    ///
    /// Steps compose: each one starts from the strategy the previous
    /// attempt used, so a ladder can raise `n` once and then keep raising
    /// it without restating the selection policy every time.
    public func applied(to current: SamplingStrategy) -> SamplingStrategy {
        var count = current.sampleCount
        var currentSelection: SelectionPolicy = .weightedVerifierScore()
        var currentVariation: SampleVariation = .default
        if case .bestOf(_, let selection, let variation) = current {
            currentSelection = selection
            currentVariation = variation
        }
        if let samples { count = max(1, samples) }
        let resolvedSelection = selection ?? currentSelection
        let resolvedVariation = variation ?? currentVariation
        guard count > 1 else { return .single }
        return .bestOf(n: count, selection: resolvedSelection, variation: resolvedVariation)
    }

    /// Applies this step's verifier changes on top of `current`.
    public func applied(to current: VerifierChain<String>) -> VerifierChain<String> {
        guard !additionalVerifiers.isEmpty || verifierMode != nil else { return current }
        return VerifierChain(
            name: current.name,
            mode: verifierMode ?? current.mode,
            current.members + additionalVerifiers
        )
    }
}

/// When to escalate a turn that the model does not seem confident about,
/// and how far.
///
/// The signal is ``LoopOutcome/confidence`` — the agreement rate across a
/// best-of-N turn's candidates. It is not a probability of correctness; it
/// is evidence about whether the model said the same thing twice. Routing
/// on it is worthwhile precisely because it is cheap and deterministic:
/// no judge model, no embedding, no network.
public struct RoutingPolicy: Sendable {
    /// Confidence at or above which an outcome is accepted as-is.
    public var minConfidence: Double
    /// Ladder of strategy escalations, applied in order and cumulatively.
    /// Its count bounds how many extra runs a routed call may issue.
    public var escalation: [EscalationStep]
    /// Whether a `nil` confidence counts as low.
    ///
    /// Defaults to `true`: a ``SamplingStrategy/single`` base run reports
    /// no agreement at all, and the natural first escalation is to draw
    /// enough candidates to *have* a signal. Set `false` when the base
    /// configuration already samples and a missing signal should be
    /// accepted rather than escalated.
    public var escalatesOnMissingConfidence: Bool

    /// Creates a routing policy. `minConfidence` is clamped to `[0, 1]`.
    public init(
        minConfidence: Double,
        escalation: [EscalationStep],
        escalatesOnMissingConfidence: Bool = true
    ) {
        self.minConfidence = min(max(0, minConfidence), 1)
        self.escalation = escalation
        self.escalatesOnMissingConfidence = escalatesOnMissingConfidence
    }

    /// `true` when `confidence` fails the bar and another rung should run.
    public func isLowConfidence(_ confidence: Double?) -> Bool {
        guard let confidence else { return escalatesOnMissingConfidence }
        return confidence < minConfidence
    }
}

/// Result of ``CompoundSession/respondRouted(to:auth:progress:metadata:)``:
/// the final run's outcome plus the routing evidence around it.
///
/// The `lowConfidence` flag is the whole point. A cascade that quietly
/// returned its last attempt would hide the case that matters — the one
/// where every rung was spent and the model still disagreed with itself,
/// which is exactly when a human should look at the answer.
public struct RoutedOutcome: Sendable {
    /// Outcome of the final attempt.
    public let outcome: LoopOutcome
    /// Labels of the escalation steps that ran, in order. Empty when the
    /// first attempt cleared the bar.
    public let appliedSteps: [String]
    /// `true` when the final attempt still failed
    /// ``RoutingPolicy/minConfidence`` — the ladder is spent and the
    /// answer is unvouched-for.
    public let lowConfidence: Bool

    /// Creates a routed outcome.
    public init(outcome: LoopOutcome, appliedSteps: [String], lowConfidence: Bool) {
        self.outcome = outcome
        self.appliedSteps = appliedSteps
        self.lowConfidence = lowConfidence
    }

    /// Final model output.
    public var output: String { outcome.output }
    /// Agreement-rate confidence of the final attempt.
    public var confidence: Double? { outcome.confidence }
    /// Resource accounting for the final attempt.
    public var usage: BudgetUsage { outcome.usage }
    /// Identifier of the final attempt's run.
    public var runID: UUID { outcome.runID }
}
