import Foundation

/// The leash on the unbounded loop. A model will propose forever if you
/// let it; this is the refusal to let it. ``Budget`` bounds a single
/// Compound run on multiple dimensions so an otherwise endless
/// propose-and-check loop is guaranteed to terminate.
///
/// Every Compound run carries a ``Budget``. The control loop consults it
/// at every step and stops the moment any one dimension is exhausted, at
/// which point ``CompoundError/budgetExhausted(_:_:)`` is thrown with the
/// dimension that tripped and the accumulated ``BudgetUsage``. The model
/// proposes; the system disposes.
///
/// # Example
/// ```swift
/// let budget = Budget(maxTurns: 4, wallClock: .seconds(20))
/// let loop = ControlLoop(budget: budget, outputVerifier: chain)
/// ```
public struct Budget: Sendable, Equatable {
    /// Maximum number of control-loop turns (model invocations) per run.
    public var maxTurns: Int
    /// Maximum number of tool invocations per run.
    public var maxToolCalls: Int
    /// Maximum number of repair turns scheduled in response to verifier
    /// `.repair` verdicts.
    public var maxRepairAttempts: Int
    /// Maximum total elapsed wall-clock time for the run.
    public var wallClock: Duration
    /// Optional cap on the cumulative approximate output-token count
    /// observed across all turns. `nil` disables the cap.
    public var maxTotalOutputTokens: Int?

    /// Creates a budget. Each numeric component is precondition-checked
    /// (positive for turns, non-negative for tool calls and repair
    /// attempts).
    public init(
        maxTurns: Int = 8,
        maxToolCalls: Int = 16,
        maxRepairAttempts: Int = 3,
        wallClock: Duration = .seconds(60),
        maxTotalOutputTokens: Int? = nil
    ) {
        precondition(maxTurns > 0, "maxTurns must be positive")
        precondition(maxToolCalls >= 0, "maxToolCalls must be non-negative")
        precondition(maxRepairAttempts >= 0, "maxRepairAttempts must be non-negative")
        self.maxTurns = maxTurns
        self.maxToolCalls = maxToolCalls
        self.maxRepairAttempts = maxRepairAttempts
        self.wallClock = wallClock
        self.maxTotalOutputTokens = maxTotalOutputTokens
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

/// What the run has spent so far, counted honestly. A running tally of
/// resources consumed by a single Compound run, mutated by the control
/// loop and surfaced on ``LoopOutcome`` and
/// ``CompoundError/budgetExhausted(_:_:)``.
public struct BudgetUsage: Sendable, Equatable {
    /// Number of completed (or attempted) model turns.
    public var turns: Int = 0
    /// Number of tool invocations.
    public var toolCalls: Int = 0
    /// Number of repair turns scheduled.
    public var repairAttempts: Int = 0
    /// Wall-clock time elapsed since the run started.
    public var elapsed: Duration = .zero
    /// Approximate output tokens observed across all turns.
    public var outputTokens: Int = 0

    /// Creates a zeroed-out usage counter.
    public init() {}

    /// Increments the turn counter.
    public mutating func recordTurn() { turns += 1 }
    /// Increments the tool-call counter.
    public mutating func recordToolCall() { toolCalls += 1 }
    /// Increments the repair-attempt counter.
    public mutating func recordRepair() { repairAttempts += 1 }
    /// Adds `n` to the cumulative output-token estimate.
    public mutating func recordOutputTokens(_ n: Int) { outputTokens += n }
    /// Replaces the elapsed-time reading.
    public mutating func recordElapsed(_ d: Duration) { elapsed = d }
}

/// Names the wall the run hit, exactly. Identifies which dimension of a
/// ``Budget`` was first exhausted during a run. Returned by
/// ``Budget/remaining(_:)`` and embedded in
/// ``CompoundError/budgetExhausted(_:_:)``.
public enum BudgetExhaustion: String, Sendable, Equatable {
    /// `maxTurns` was reached.
    case turns
    /// `maxToolCalls` was reached.
    case toolCalls
    /// `maxRepairAttempts` was reached.
    case repairAttempts
    /// `wallClock` elapsed.
    case wallClock
    /// `maxTotalOutputTokens` was reached.
    case outputTokens
}

extension Budget {
    /// Returns the dimension that has been exhausted by `usage`, or `nil`
    /// if every dimension still has headroom.
    ///
    /// - Parameter usage: The accumulated usage to test against this budget.
    /// - Returns: The first dimension that has met or exceeded its cap.
    public func remaining(_ usage: BudgetUsage) -> BudgetExhaustion? {
        if usage.turns >= maxTurns { return .turns }
        if usage.toolCalls >= maxToolCalls { return .toolCalls }
        if usage.repairAttempts >= maxRepairAttempts { return .repairAttempts }
        if usage.elapsed >= wallClock { return .wallClock }
        if let cap = maxTotalOutputTokens, usage.outputTokens >= cap { return .outputTokens }
        return nil
    }

    /// Rough heuristic token estimate (~4 bytes/token). Not a real tokenizer;
    /// sufficient for budget tracking until Apple exposes a token counter for
    /// the on-device model. Shared by the control-loop variants so they keep a
    /// single definition of "token".
    ///
    /// - Parameter text: UTF-8 string to estimate.
    /// - Returns: At least 1, otherwise `utf8.count / 4`.
    public static func approximateTokens(_ text: String) -> Int {
        max(1, text.utf8.count / 4)
    }
}
