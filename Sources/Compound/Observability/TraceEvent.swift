import Foundation

/// Structured log of everything that happens in a Compound run.
///
/// Every model call, every tool invocation, every verifier verdict, and
/// every control-loop decision is captured here with enough fidelity to
/// reconstruct the run after the fact. `TraceEvent` is the substrate of
/// governance, audit, and post-incident analysis.
///
/// Evolution policy: `TraceEvent` is intended to grow over time. To
/// avoid source-breaking every consumer when a new case is introduced,
/// the enum carries an open-ended ``unknown(runID:label:payload:)``
/// case. New events should land as proper cases inside Compound;
/// out-of-tree producers (or older consumers) can route through
/// `.unknown`. Consumers that do not switch exhaustively should match a
/// `default:` arm to remain forward-compatible. ``TraceEventVisitor`` is
/// the preferred shape for extension-friendly consumers — its default
/// methods let you handle only the cases you care about.
public enum TraceEvent: Sendable {
    /// A new run started.
    case runStarted(runID: UUID, prompt: String, budget: Budget, auth: String)
    /// A run ended (success or failure).
    case runEnded(runID: UUID, success: Bool, usage: BudgetUsage)

    /// Model call started (turn index, prompt size in bytes).
    case modelInvocationStarted(runID: UUID, turn: Int, promptBytes: Int)
    /// Model call completed (output size in bytes, wall-clock elapsed).
    case modelInvocationCompleted(runID: UUID, turn: Int, outputBytes: Int, elapsed: Duration)
    /// Model call threw.
    case modelInvocationFailed(runID: UUID, turn: Int, reason: String)

    /// The model requested a tool invocation.
    case toolInvocationRequested(runID: UUID, tool: String)
    /// A tool invocation finished.
    case toolInvocationCompleted(runID: UUID, tool: String, elapsed: Duration, succeeded: Bool)
    /// A tool invocation was blocked by ``Policy``.
    case toolPolicyDenied(runID: UUID, tool: String, reason: String)
    /// A tool invocation's decoded arguments were rejected by the tool's
    /// argument verifier chain before the tool executed.
    case toolArgumentRejected(runID: UUID, tool: String, diagnostic: Diagnostic)
    /// A tool's returned output was rejected by the tool's output
    /// verifier chain and withheld from the model's context.
    case toolOutputRejected(runID: UUID, tool: String, diagnostic: Diagnostic)

    /// A verifier produced a verdict.
    case verifierEvaluated(runID: UUID, verifier: String, cost: VerifierCost, verdict: Verdict, elapsed: Duration)

    /// The control loop scheduled a repair turn from a `.repair` verdict.
    case repairScheduled(runID: UUID, attempt: Int, diagnostic: Diagnostic)
    /// A budget dimension was exhausted.
    case budgetExhausted(runID: UUID, kind: BudgetExhaustion)
    /// A verifier returned `.escalate`.
    case escalation(runID: UUID, reason: String)
    /// Free-form structured info from any layer.
    case info(runID: UUID, category: String, message: String)

    /// Open-ended escape hatch for future or out-of-tree events. The
    /// `runID` is the nil UUID when none is meaningful. Consumers should
    /// switch with a `default:` arm (or implement
    /// ``TraceEventVisitor``) to stay forward-compatible.
    case unknown(runID: UUID, label: String, payload: [String: String])

    /// Run identifier embedded in the event payload.
    public var runID: UUID {
        switch self {
        case .runStarted(let id, _, _, _),
             .runEnded(let id, _, _),
             .modelInvocationStarted(let id, _, _),
             .modelInvocationCompleted(let id, _, _, _),
             .modelInvocationFailed(let id, _, _),
             .toolInvocationRequested(let id, _),
             .toolInvocationCompleted(let id, _, _, _),
             .toolPolicyDenied(let id, _, _),
             .toolArgumentRejected(let id, _, _),
             .toolOutputRejected(let id, _, _),
             .verifierEvaluated(let id, _, _, _, _),
             .repairScheduled(let id, _, _),
             .budgetExhausted(let id, _),
             .escalation(let id, _),
             .info(let id, _, _),
             .unknown(let id, _, _):
            return id
        }
    }

    /// Stable, dot-separated event label suitable for log aggregation.
    public var label: String {
        switch self {
        case .runStarted: return "run.started"
        case .runEnded: return "run.ended"
        case .modelInvocationStarted: return "model.started"
        case .modelInvocationCompleted: return "model.completed"
        case .modelInvocationFailed: return "model.failed"
        case .toolInvocationRequested: return "tool.requested"
        case .toolInvocationCompleted: return "tool.completed"
        case .toolPolicyDenied: return "tool.denied"
        case .toolArgumentRejected: return "tool.argument.rejected"
        case .toolOutputRejected: return "tool.output.rejected"
        case .verifierEvaluated: return "verifier.evaluated"
        case .repairScheduled: return "repair.scheduled"
        case .budgetExhausted: return "budget.exhausted"
        case .escalation: return "escalation"
        case .info: return "info"
        case .unknown(_, let label, _): return label
        }
    }
}

/// Lets consumers handle only the ``TraceEvent`` cases they care about
/// while remaining source-stable as new cases are added. Each method
/// has a no-op default; override only what you need.
///
/// Dispatch happens through ``TraceEvent/accept(_:)``. New cases added
/// to ``TraceEvent`` must be wired into `accept(_:)` here, but visitor
/// adopters inherit a no-op default for free.
public protocol TraceEventVisitor: Sendable {
    func visitRunStarted(runID: UUID, prompt: String, budget: Budget, auth: String) async
    func visitRunEnded(runID: UUID, success: Bool, usage: BudgetUsage) async
    func visitModelInvocationStarted(runID: UUID, turn: Int, promptBytes: Int) async
    func visitModelInvocationCompleted(runID: UUID, turn: Int, outputBytes: Int, elapsed: Duration) async
    func visitModelInvocationFailed(runID: UUID, turn: Int, reason: String) async
    func visitToolInvocationRequested(runID: UUID, tool: String) async
    func visitToolInvocationCompleted(runID: UUID, tool: String, elapsed: Duration, succeeded: Bool) async
    func visitToolPolicyDenied(runID: UUID, tool: String, reason: String) async
    func visitToolArgumentRejected(runID: UUID, tool: String, diagnostic: Diagnostic) async
    func visitToolOutputRejected(runID: UUID, tool: String, diagnostic: Diagnostic) async
    func visitVerifierEvaluated(runID: UUID, verifier: String, cost: VerifierCost, verdict: Verdict, elapsed: Duration) async
    func visitRepairScheduled(runID: UUID, attempt: Int, diagnostic: Diagnostic) async
    func visitBudgetExhausted(runID: UUID, kind: BudgetExhaustion) async
    func visitEscalation(runID: UUID, reason: String) async
    func visitInfo(runID: UUID, category: String, message: String) async
    func visitUnknown(runID: UUID, label: String, payload: [String: String]) async
}

public extension TraceEventVisitor {
    func visitRunStarted(runID _: UUID, prompt _: String, budget _: Budget, auth _: String) async {}
    func visitRunEnded(runID _: UUID, success _: Bool, usage _: BudgetUsage) async {}
    func visitModelInvocationStarted(runID _: UUID, turn _: Int, promptBytes _: Int) async {}
    func visitModelInvocationCompleted(runID _: UUID, turn _: Int, outputBytes _: Int, elapsed _: Duration) async {}
    func visitModelInvocationFailed(runID _: UUID, turn _: Int, reason _: String) async {}
    func visitToolInvocationRequested(runID _: UUID, tool _: String) async {}
    func visitToolInvocationCompleted(runID _: UUID, tool _: String, elapsed _: Duration, succeeded _: Bool) async {}
    func visitToolPolicyDenied(runID _: UUID, tool _: String, reason _: String) async {}
    func visitToolArgumentRejected(runID _: UUID, tool _: String, diagnostic _: Diagnostic) async {}
    func visitToolOutputRejected(runID _: UUID, tool _: String, diagnostic _: Diagnostic) async {}
    func visitVerifierEvaluated(runID _: UUID, verifier _: String, cost _: VerifierCost, verdict _: Verdict, elapsed _: Duration) async {}
    func visitRepairScheduled(runID _: UUID, attempt _: Int, diagnostic _: Diagnostic) async {}
    func visitBudgetExhausted(runID _: UUID, kind _: BudgetExhaustion) async {}
    func visitEscalation(runID _: UUID, reason _: String) async {}
    func visitInfo(runID _: UUID, category _: String, message _: String) async {}
    func visitUnknown(runID _: UUID, label _: String, payload _: [String: String]) async {}
}

public extension TraceEvent {
    /// Dispatches this event to the visitor method matching its case.
    func accept(_ visitor: some TraceEventVisitor) async {
        switch self {
        case .runStarted(let id, let prompt, let budget, let auth):
            await visitor.visitRunStarted(runID: id, prompt: prompt, budget: budget, auth: auth)
        case .runEnded(let id, let ok, let usage):
            await visitor.visitRunEnded(runID: id, success: ok, usage: usage)
        case .modelInvocationStarted(let id, let turn, let bytes):
            await visitor.visitModelInvocationStarted(runID: id, turn: turn, promptBytes: bytes)
        case .modelInvocationCompleted(let id, let turn, let bytes, let elapsed):
            await visitor.visitModelInvocationCompleted(runID: id, turn: turn, outputBytes: bytes, elapsed: elapsed)
        case .modelInvocationFailed(let id, let turn, let reason):
            await visitor.visitModelInvocationFailed(runID: id, turn: turn, reason: reason)
        case .toolInvocationRequested(let id, let tool):
            await visitor.visitToolInvocationRequested(runID: id, tool: tool)
        case .toolInvocationCompleted(let id, let tool, let elapsed, let ok):
            await visitor.visitToolInvocationCompleted(runID: id, tool: tool, elapsed: elapsed, succeeded: ok)
        case .toolPolicyDenied(let id, let tool, let reason):
            await visitor.visitToolPolicyDenied(runID: id, tool: tool, reason: reason)
        case .toolArgumentRejected(let id, let tool, let diag):
            await visitor.visitToolArgumentRejected(runID: id, tool: tool, diagnostic: diag)
        case .toolOutputRejected(let id, let tool, let diag):
            await visitor.visitToolOutputRejected(runID: id, tool: tool, diagnostic: diag)
        case .verifierEvaluated(let id, let v, let cost, let verdict, let elapsed):
            await visitor.visitVerifierEvaluated(runID: id, verifier: v, cost: cost, verdict: verdict, elapsed: elapsed)
        case .repairScheduled(let id, let attempt, let diag):
            await visitor.visitRepairScheduled(runID: id, attempt: attempt, diagnostic: diag)
        case .budgetExhausted(let id, let kind):
            await visitor.visitBudgetExhausted(runID: id, kind: kind)
        case .escalation(let id, let reason):
            await visitor.visitEscalation(runID: id, reason: reason)
        case .info(let id, let cat, let msg):
            await visitor.visitInfo(runID: id, category: cat, message: msg)
        case .unknown(let id, let label, let payload):
            await visitor.visitUnknown(runID: id, label: label, payload: payload)
        }
    }
}
