import Foundation

/// Bounds a single Compound run on multiple dimensions so that an
/// otherwise unbounded propose-and-check loop is guaranteed to terminate.
///
/// Every Compound run carries a ``Budget``. The control loop consults it
/// at every step and stops the moment any one dimension is exhausted, at
/// which point ``CompoundError/budgetExhausted(_:_:)`` is thrown with the
/// dimension that tripped and the accumulated ``BudgetUsage``.
///
/// # Example
/// ```swift
/// let budget = Budget(maxTurns: 4, wallClock: .seconds(20))
/// let loop = ControlLoop(budget: budget, outputVerifier: chain)
/// ```
public struct Budget: Sendable, Equatable, Codable {
    /// Maximum number of control-loop turns (model invocations) per run.
    public var maxTurns: Int
    /// Maximum number of tool invocations per run.
    public var maxToolCalls: Int
    /// Maximum number of repair turns scheduled in response to verifier
    /// `.repair` verdicts.
    public var maxRepairAttempts: Int
    /// Maximum total elapsed wall-clock time for the run.
    public var wallClock: Duration
    /// Optional cap on how long a streaming turn may wait for its *first*
    /// chunk. `nil` (the default) disables the check; the run is then
    /// bounded only by ``wallClock``. Enforced by ``StreamingControlLoop``
    /// while the model call is in flight.
    public var firstToken: Duration?
    /// Optional cap on the gap between consecutive streamed chunks. A model
    /// that stalls mid-generation trips this instead of running out the
    /// whole ``wallClock``. `nil` (the default) disables the check.
    /// Enforced by ``StreamingControlLoop`` while the model call is in
    /// flight.
    public var interChunkGap: Duration?
    /// Optional cap on the cumulative approximate output-token count
    /// observed across all turns. `nil` disables the cap.
    public var maxTotalOutputTokens: Int?
    /// Optional cap on the number of **candidate samples** drawn across
    /// the run by ``SamplingStrategy/bestOf(n:selection:variation:)``.
    ///
    /// ``maxTurns`` bounds loop *iterations*, not model calls: a best-of-N
    /// turn issues up to `n` model calls, so `maxTurns × n` is the real
    /// upper bound on model invocations. `maxSamples` is the direct cap on
    /// that multiplied cost. `nil` (the default) leaves sampling bounded
    /// only by ``maxTurns``, ``wallClock``, and ``maxTotalOutputTokens``.
    ///
    /// Single-candidate runs never debit this dimension (see
    /// ``BudgetUsage/samples``), so a non-nil cap constrains best-of-N
    /// sampling and nothing else.
    public var maxSamples: Int?

    /// Creates a budget. Each numeric component is precondition-checked
    /// (positive for turns, non-negative for tool calls and repair
    /// attempts).
    public init(
        maxTurns: Int = 8,
        maxToolCalls: Int = 16,
        maxRepairAttempts: Int = 3,
        wallClock: Duration = .seconds(60),
        firstToken: Duration? = nil,
        interChunkGap: Duration? = nil,
        maxTotalOutputTokens: Int? = nil,
        maxSamples: Int? = nil
    ) {
        precondition(maxTurns > 0, "maxTurns must be positive")
        precondition(maxToolCalls >= 0, "maxToolCalls must be non-negative")
        precondition(maxRepairAttempts >= 0, "maxRepairAttempts must be non-negative")
        precondition(maxSamples.map { $0 >= 0 } ?? true, "maxSamples must be non-negative")
        self.maxTurns = maxTurns
        self.maxToolCalls = maxToolCalls
        self.maxRepairAttempts = maxRepairAttempts
        self.wallClock = wallClock
        self.firstToken = firstToken
        self.interChunkGap = interChunkGap
        self.maxTotalOutputTokens = maxTotalOutputTokens
        self.maxSamples = maxSamples
    }

    /// Conservative defaults intended for general-purpose interactive use.
    public static let `default` = Budget()

    /// Tight budget for latency-sensitive workloads (short runs, few repairs).
    public static let strict = Budget(
        maxTurns: 3,
        maxToolCalls: 4,
        maxRepairAttempts: 1,
        wallClock: .seconds(15)
    )

    /// Generous budget for long-running background runs.
    public static let permissive = Budget(
        maxTurns: 32,
        maxToolCalls: 64,
        maxRepairAttempts: 8,
        wallClock: .seconds(300)
    )
}

/// Running tally of resources consumed by a single Compound run, mutated
/// by the control loop and surfaced on ``LoopOutcome`` and
/// ``CompoundError/budgetExhausted(_:_:)``.
public struct BudgetUsage: Sendable, Equatable, Codable {
    /// Number of model turns begun. Turns are recorded check-then-record,
    /// so a turn refused by the budget is never counted.
    public var turns: Int = 0
    /// Number of tool invocations.
    public var toolCalls: Int = 0
    /// Number of repair turns scheduled.
    public var repairAttempts: Int = 0
    /// Wall-clock time elapsed since the run started.
    public var elapsed: Duration = .zero
    /// Approximate output tokens observed across all turns.
    public var outputTokens: Int = 0
    /// Number of candidate samples drawn by best-of-N sampling.
    ///
    /// Zero for every single-candidate run: this counter exists to make
    /// the *multiplied* cost of ``SamplingStrategy/bestOf(n:selection:variation:)``
    /// visible and cappable (``Budget/maxSamples``) without changing what
    /// ``turns`` has always meant. Every drawn candidate is counted,
    /// including the ones the selection policy discards.
    public var samples: Int = 0

    /// Creates a zeroed-out usage counter.
    public init() {}

    /// Increments the turn counter.
    public mutating func recordTurn() { turns += 1 }
    /// Increments the best-of-N candidate-sample counter.
    public mutating func recordSample() { samples += 1 }
    /// Increments the tool-call counter.
    public mutating func recordToolCall() { toolCalls += 1 }
    /// Increments the repair-attempt counter.
    public mutating func recordRepair() { repairAttempts += 1 }
    /// Adds `n` to the cumulative output-token estimate.
    public mutating func recordOutputTokens(_ n: Int) { outputTokens += n }
    /// Replaces the elapsed-time reading.
    public mutating func recordElapsed(_ d: Duration) { elapsed = d }
}

/// Identifies which dimension of a ``Budget`` was first exhausted during
/// a run. Returned by ``Budget/remaining(_:)`` and embedded in
/// ``CompoundError/budgetExhausted(_:_:)``.
public enum BudgetExhaustion: String, Sendable, Equatable, Codable {
    /// `maxTurns` was reached.
    case turns
    /// `maxToolCalls` was reached.
    case toolCalls
    /// `maxRepairAttempts` was reached.
    case repairAttempts
    /// `wallClock` elapsed.
    case wallClock
    /// A streaming turn's first chunk did not arrive within
    /// ``Budget/firstToken``. Tripped only mid-stream by
    /// ``StreamingControlLoop``; never returned by the between-turn checks.
    case firstToken
    /// The gap between consecutive streamed chunks exceeded
    /// ``Budget/interChunkGap``. Tripped only mid-stream by
    /// ``StreamingControlLoop``; never returned by the between-turn checks.
    case interChunkGap
    /// `maxTotalOutputTokens` was reached.
    case outputTokens
    /// ``Budget/maxSamples`` was reached while drawing best-of-N
    /// candidates. Only best-of-N runs can trip this dimension.
    case samples
}

// MARK: - Codable

/// Wire representation for `Duration` shared by every ``Codable`` type in
/// the framework: whole nanoseconds as an `Int64`.
///
/// `Duration`'s stdlib conformance encodes an opaque high/low pair, which
/// round-trips but is unreadable in an exported trace. Nanoseconds are
/// exact for every duration Compound produces (millisecond and second
/// literals, clock measurements) and saturate rather than trap on the
/// astronomically large values `Duration` can otherwise represent.
enum DurationCoding {
    /// Whole nanoseconds in `duration`, saturating at `Int64` bounds.
    static func nanoseconds(_ duration: Duration) -> Int64 {
        let parts = duration.components
        let saturated: Int64 = parts.seconds < 0 ? .min : .max
        let (scaled, overflowedScale) = parts.seconds.multipliedReportingOverflow(by: 1_000_000_000)
        if overflowedScale { return saturated }
        let (total, overflowedSum) = scaled.addingReportingOverflow(parts.attoseconds / 1_000_000_000)
        return overflowedSum ? saturated : total
    }

    /// Inverse of ``nanoseconds(_:)``.
    static func duration(nanoseconds: Int64) -> Duration {
        .nanoseconds(nanoseconds)
    }
}

extension Budget {
    /// Wire keys. Durations are suffixed `_ns` to make the unit explicit
    /// in exported traces.
    enum CodingKeys: String, CodingKey, CaseIterable {
        case maxTurns = "max_turns"
        case maxToolCalls = "max_tool_calls"
        case maxRepairAttempts = "max_repair_attempts"
        case wallClock = "wall_clock_ns"
        case firstToken = "first_token_ns"
        case interChunkGap = "inter_chunk_gap_ns"
        case maxTotalOutputTokens = "max_total_output_tokens"
        case maxSamples = "max_samples"
    }

    /// Encodes every dimension, durations as whole nanoseconds.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(maxTurns, forKey: .maxTurns)
        try container.encode(maxToolCalls, forKey: .maxToolCalls)
        try container.encode(maxRepairAttempts, forKey: .maxRepairAttempts)
        try container.encode(DurationCoding.nanoseconds(wallClock), forKey: .wallClock)
        try container.encodeIfPresent(firstToken.map(DurationCoding.nanoseconds), forKey: .firstToken)
        try container.encodeIfPresent(interChunkGap.map(DurationCoding.nanoseconds), forKey: .interChunkGap)
        try container.encodeIfPresent(maxTotalOutputTokens, forKey: .maxTotalOutputTokens)
        try container.encodeIfPresent(maxSamples, forKey: .maxSamples)
    }

    /// Decodes a budget, *validating* the same invariants the memberwise
    /// initializer preconditions on. A corrupt or hostile trace file must
    /// surface a `DecodingError` rather than trap the process, so the
    /// checks are throwing rather than `precondition`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let turns = try container.decode(Int.self, forKey: .maxTurns)
        let toolCalls = try container.decode(Int.self, forKey: .maxToolCalls)
        let repairs = try container.decode(Int.self, forKey: .maxRepairAttempts)
        guard turns > 0 else {
            throw DecodingError.dataCorruptedError(forKey: .maxTurns, in: container, debugDescription: "maxTurns must be positive")
        }
        guard toolCalls >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .maxToolCalls, in: container, debugDescription: "maxToolCalls must be non-negative")
        }
        guard repairs >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .maxRepairAttempts, in: container, debugDescription: "maxRepairAttempts must be non-negative")
        }
        let samples = try container.decodeIfPresent(Int.self, forKey: .maxSamples)
        guard samples.map({ $0 >= 0 }) ?? true else {
            throw DecodingError.dataCorruptedError(forKey: .maxSamples, in: container, debugDescription: "maxSamples must be non-negative")
        }
        self.init(
            maxTurns: turns,
            maxToolCalls: toolCalls,
            maxRepairAttempts: repairs,
            wallClock: DurationCoding.duration(nanoseconds: try container.decode(Int64.self, forKey: .wallClock)),
            firstToken: try container.decodeIfPresent(Int64.self, forKey: .firstToken).map(DurationCoding.duration(nanoseconds:)),
            interChunkGap: try container.decodeIfPresent(Int64.self, forKey: .interChunkGap).map(DurationCoding.duration(nanoseconds:)),
            maxTotalOutputTokens: try container.decodeIfPresent(Int.self, forKey: .maxTotalOutputTokens),
            maxSamples: samples
        )
    }
}

extension BudgetUsage {
    /// Wire keys; `elapsed` is whole nanoseconds.
    enum CodingKeys: String, CodingKey, CaseIterable {
        case turns
        case toolCalls = "tool_calls"
        case repairAttempts = "repair_attempts"
        case elapsed = "elapsed_ns"
        case outputTokens = "output_tokens"
        case samples
    }

    /// Encodes the accumulated counters.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(turns, forKey: .turns)
        try container.encode(toolCalls, forKey: .toolCalls)
        try container.encode(repairAttempts, forKey: .repairAttempts)
        try container.encode(DurationCoding.nanoseconds(elapsed), forKey: .elapsed)
        try container.encode(outputTokens, forKey: .outputTokens)
        try container.encode(samples, forKey: .samples)
    }

    /// Decodes counters, tolerating absent keys so older trace files keep
    /// reading as the struct grows dimensions.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        turns = try container.decodeIfPresent(Int.self, forKey: .turns) ?? 0
        toolCalls = try container.decodeIfPresent(Int.self, forKey: .toolCalls) ?? 0
        repairAttempts = try container.decodeIfPresent(Int.self, forKey: .repairAttempts) ?? 0
        elapsed = DurationCoding.duration(
            nanoseconds: try container.decodeIfPresent(Int64.self, forKey: .elapsed) ?? 0
        )
        outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        samples = try container.decodeIfPresent(Int.self, forKey: .samples) ?? 0
    }
}

extension Budget {
    /// The budget semantic, stated once: **each cap is the number of allowed
    /// occurrences**. `maxTurns: 1` permits exactly one model call,
    /// `maxRepairAttempts: 1` permits exactly one repair, and
    /// `maxToolCalls: 2` permits exactly two tool invocations — it is the
    /// occurrence *after* the cap that is refused. Enforcement is therefore
    /// check-then-record: project the next occurrence with this method and
    /// only record it when no dimension trips.
    ///
    /// Discrete dimensions (`turns`, `toolCalls`, `repairAttempts`) trip only
    /// when the projected count *exceeds* their cap, so a cap of `0` merely
    /// forbids consuming that dimension — it does not fail runs that never
    /// touch it. Continuous dimensions (`wallClock`, `outputTokens`) trip the
    /// moment they are reached, regardless of which `dimension` is being
    /// added.
    ///
    /// - Parameters:
    ///   - dimension: The discrete dimension about to be consumed.
    ///   - usage: Usage accumulated so far, *before* recording the occurrence.
    /// - Returns: The first dimension that would be exhausted by consuming
    ///   one more `dimension`, or `nil` if the occurrence fits the budget.
    public func exhaustion(
        afterAdding dimension: BudgetExhaustion,
        to usage: BudgetUsage
    ) -> BudgetExhaustion? {
        var projected = usage
        switch dimension {
        case .turns: projected.recordTurn()
        case .toolCalls: projected.recordToolCall()
        case .repairAttempts: projected.recordRepair()
        case .samples: projected.recordSample()
        // Continuous dimensions have no per-occurrence projection, and the
        // stream-stall dimensions are tripped only mid-stream by the
        // streaming loop's watchdog — never by this between-turn check.
        case .wallClock, .outputTokens, .firstToken, .interChunkGap: break
        }
        if projected.turns > maxTurns { return .turns }
        if projected.toolCalls > maxToolCalls { return .toolCalls }
        if projected.repairAttempts > maxRepairAttempts { return .repairAttempts }
        if let cap = maxSamples, projected.samples > cap { return .samples }
        if projected.elapsed >= wallClock { return .wallClock }
        if let cap = maxTotalOutputTokens, projected.outputTokens >= cap { return .outputTokens }
        return nil
    }

    /// Returns the dimension whose cap `usage` has met or exceeded (zero
    /// headroom), or `nil` if every dimension still has headroom.
    ///
    /// This is a plain headroom probe for telemetry and callers that inspect
    /// accumulated usage. The control loops enforce the budget with
    /// ``exhaustion(afterAdding:to:)`` instead, which implements the
    /// check-then-record semantic.
    ///
    /// - Parameter usage: The accumulated usage to test against this budget.
    /// - Returns: The first dimension that has met or exceeded its cap.
    public func remaining(_ usage: BudgetUsage) -> BudgetExhaustion? {
        if usage.turns >= maxTurns { return .turns }
        if usage.toolCalls >= maxToolCalls { return .toolCalls }
        if usage.repairAttempts >= maxRepairAttempts { return .repairAttempts }
        if let cap = maxSamples, usage.samples >= cap { return .samples }
        if usage.elapsed >= wallClock { return .wallClock }
        if let cap = maxTotalOutputTokens, usage.outputTokens >= cap { return .outputTokens }
        return nil
    }

    /// Rough heuristic token estimate (~4 bytes/token). Not a real tokenizer;
    /// sufficient for budget tracking wherever a measured count is not
    /// available. Shared by the control-loop variants so they keep a single
    /// definition of "token". ``HeuristicTokenCounter`` delegates here so the
    /// heuristic has exactly one implementation; inject a
    /// ``TokenCounting`` conformer (e.g. `SystemModelTokenCounter`) where
    /// real counts matter.
    ///
    /// - Parameter text: UTF-8 string to estimate.
    /// - Returns: At least 1, otherwise `utf8.count / 4`.
    public static func approximateTokens(_ text: String) -> Int {
        max(1, text.utf8.count / 4)
    }
}

// MARK: - Token counting

/// Measures text in model tokens for budget accounting.
///
/// The framework defaults to ``HeuristicTokenCounter`` everywhere (byte
/// heuristic, safe off-device and in tests); on-device callers inject
/// `SystemModelTokenCounter`, which asks the system model's real tokenizer
/// (26.4+) and reports the model's actual context window.
///
/// `count(_:)` is `async` because the real tokenizer is; heuristic
/// conformers simply return synchronously.
public protocol TokenCounting: Sendable {
    /// Returns the number of tokens `text` occupies. May be approximate;
    /// implementations should err on the side of overcounting.
    func count(_ text: String) async -> Int
    /// Size of the target model's context window, in tokens.
    var contextSize: Int { get }
}

/// Default ``TokenCounting``: the framework's bytes-per-token heuristic
/// (see ``Budget/approximateTokens(_:)``). Deterministic, allocation-free,
/// and available off-device — the default for tests and for every seam
/// until a real counter is injected.
public struct HeuristicTokenCounter: TokenCounting, Equatable {
    /// Heuristic bytes-per-token divisor.
    public let charsPerToken: Int
    /// Assumed context window. Defaults to 4096, the documented floor of
    /// the on-device system model's window.
    public let contextSize: Int

    /// Creates a counter. Inputs are precondition-checked.
    public init(charsPerToken: Int = 4, contextSize: Int = 4096) {
        precondition(charsPerToken > 0, "charsPerToken must be positive")
        precondition(contextSize > 0, "contextSize must be positive")
        self.charsPerToken = charsPerToken
        self.contextSize = contextSize
    }

    /// `max(1, utf8.count / charsPerToken)` — identical to
    /// ``Budget/approximateTokens(_:)`` at the default divisor.
    public func count(_ text: String) async -> Int {
        max(1, text.utf8.count / charsPerToken)
    }
}

/// Running estimate of how full a model session's context window is,
/// updated once per turn — from measured `response.usage` where the OS
/// provides it, otherwise from ``TokenCounting`` estimates.
///
/// The ledger exposes a configurable **high watermark** (default 80% of
/// the context window). ``record(promptTokens:outputTokens:)`` and
/// ``reconcile(measuredTokens:)`` return `true` exactly when the update
/// *crosses* the watermark from below, so the caller can compact the
/// session proactively — before the window blows and the model throws
/// ``CompoundError/contextWindowExceeded(promptTokens:)``.
public actor SessionTokenLedger {
    /// Context window capacity, in tokens.
    public nonisolated let contextSize: Int
    /// Fraction of ``contextSize`` at which the watermark sits.
    public nonisolated let highWatermarkFraction: Double
    /// Current occupancy estimate, in tokens.
    public private(set) var estimatedTokens = 0
    private var crossed = false

    /// Creates a ledger. Inputs are precondition-checked.
    ///
    /// - Parameters:
    ///   - contextSize: The model's context window, in tokens.
    ///   - highWatermarkFraction: Watermark position as a fraction of the
    ///     window; defaults to 0.8.
    public init(contextSize: Int, highWatermarkFraction: Double = 0.8) {
        precondition(contextSize > 0, "contextSize must be positive")
        precondition(
            highWatermarkFraction > 0 && highWatermarkFraction <= 1,
            "highWatermarkFraction must be in (0, 1]"
        )
        self.contextSize = contextSize
        self.highWatermarkFraction = highWatermarkFraction
    }

    /// Occupancy (in tokens) at which the watermark trips.
    public nonisolated var highWatermark: Int {
        max(1, Int((Double(contextSize) * highWatermarkFraction).rounded(.down)))
    }

    /// True while the current estimate sits at or above the watermark.
    public var isAboveWatermark: Bool { estimatedTokens >= highWatermark }

    /// Adds one turn's estimated tokens to the occupancy.
    ///
    /// - Returns: `true` iff this update crossed the watermark from below.
    @discardableResult
    public func record(promptTokens: Int, outputTokens: Int) -> Bool {
        advance(to: estimatedTokens + max(0, promptTokens) + max(0, outputTokens))
    }

    /// Replaces the estimate with a measured occupancy (e.g. from
    /// `response.usage`). Moving *below* the watermark re-arms crossing
    /// detection.
    ///
    /// - Returns: `true` iff this update crossed the watermark from below.
    @discardableResult
    public func reconcile(measuredTokens: Int) -> Bool {
        advance(to: max(0, measuredTokens))
    }

    /// Resets the occupancy — after compaction, pass the estimated size of
    /// the seeded replacement transcript.
    public func reset(to tokens: Int = 0) {
        estimatedTokens = max(0, tokens)
        crossed = estimatedTokens >= highWatermark
    }

    private func advance(to newValue: Int) -> Bool {
        estimatedTokens = newValue
        let above = estimatedTokens >= highWatermark
        defer { crossed = above }
        return above && !crossed
    }
}

/// Actor-backed counter enforcing ``Budget/maxToolCalls`` for a single run.
///
/// One meter is attached to each ``RunContext`` and shared by every
/// ``VerifiedTool`` instantiated for that run, so the cap is enforced
/// *mid-turn* — the moment the model requests one tool call too many —
/// rather than only between turns. The control loop folds ``count`` into
/// its ``BudgetUsage`` once per turn so outcomes and errors report the
/// tool calls actually made.
public actor ToolCallMeter {
    /// Number of allowed tool invocations, or `nil` for unlimited (the
    /// default for contexts constructed without a budget).
    public let limit: Int?
    /// Tool invocations recorded so far.
    public private(set) var count = 0

    /// Creates a meter. Pass ``Budget/maxToolCalls`` as `limit` to enforce
    /// the cap; `nil` disables it.
    public init(limit: Int? = nil) {
        self.limit = limit
    }

    /// Records one tool invocation with check-then-record semantics: with
    /// `limit == N`, exactly N calls succeed and call N+1 throws without
    /// being counted.
    ///
    /// - Returns: The new cumulative count.
    /// - Throws: ``CompoundError/budgetExhausted(_:_:)`` with
    ///   ``BudgetExhaustion/toolCalls`` when the cap would be exceeded. The
    ///   attached ``BudgetUsage`` carries only the tool-call count — the
    ///   loop's full usage is not visible mid-turn.
    @discardableResult
    public func record() throws -> Int {
        if let limit, count + 1 > limit {
            var usage = BudgetUsage()
            usage.toolCalls = count
            throw CompoundError.budgetExhausted(.toolCalls, usage)
        }
        count += 1
        return count
    }
}
