import Foundation

/// Cross-cutting bundle threaded through every layer of a single Compound
/// execution: identity for governance, the ``Tracer`` for observability, a
/// ``ProgressReporter`` for UI binding, and tagging metadata for downstream
/// filtering.
///
/// `RunContext` carries no business state — that lives in the model's
/// `Transcript`. Treat instances as immutable; ``with(metadata:)`` returns
/// a copy with merged tags.
public struct RunContext: Sendable {
    /// Stable identifier for the run; appears in every emitted
    /// ``TraceEvent`` and ``ProgressEvent``.
    public let runID: UUID
    /// Identity and scopes available for ``Policy`` decisions.
    public let auth: AuthContext
    /// Sink for structured trace events.
    public let tracer: any Tracer
    /// Sink for high-frequency UI-facing progress events.
    public let progress: any ProgressReporter
    /// Free-form tags propagated for downstream filtering/correlation.
    public let metadata: [String: String]
    /// Wall-clock instant the run was constructed.
    public let startedAt: Date
    /// Shared per-run tool-invocation counter. ``VerifiedTool`` records every
    /// invocation here (throwing mid-turn when the cap trips) and the control
    /// loop folds its count into ``BudgetUsage`` each turn. Defaults to an
    /// unlimited meter; pass `ToolCallMeter(limit: budget.maxToolCalls)` to
    /// enforce ``Budget/maxToolCalls``.
    public let toolCallMeter: ToolCallMeter

    /// Creates a run context. Every parameter has a safe default so call
    /// sites can spin up an anonymous, untraced run in one line.
    public init(
        runID: UUID = UUID(),
        auth: AuthContext = .anonymous,
        tracer: any Tracer = NullTracer(),
        progress: any ProgressReporter = NullProgressReporter(),
        metadata: [String: String] = [:],
        startedAt: Date = Date(),
        toolCallMeter: ToolCallMeter = ToolCallMeter()
    ) {
        self.runID = runID
        self.auth = auth
        self.tracer = tracer
        self.progress = progress
        self.metadata = metadata
        self.startedAt = startedAt
        self.toolCallMeter = toolCallMeter
    }

    /// Returns a copy of this context with additional metadata merged in.
    /// Keys in `extra` overwrite existing values.
    public func with(metadata extra: [String: String]) -> RunContext {
        var merged = metadata
        for (k, v) in extra { merged[k] = v }
        return RunContext(
            runID: runID,
            auth: auth,
            tracer: tracer,
            progress: progress,
            metadata: merged,
            startedAt: startedAt,
            toolCallMeter: toolCallMeter
        )
    }
}
