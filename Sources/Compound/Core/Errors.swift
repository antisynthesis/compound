import Foundation

/// The umbrella error type thrown across Compound's framework boundaries.
///
/// `CompoundError` is intentionally a single enum so callers have one type
/// to catch at the surface of a run, but it carries enough structure that
/// callers do not have to string-match its description. Use ``severity``
/// and ``layer`` to route programmatically.
public enum CompoundError: Error, Sendable, CustomStringConvertible {
    /// The control loop hit a hard budget limit (turns, tool calls,
    /// repair attempts, wall clock, or output tokens) before reaching a
    /// pass verdict. Carries the dimension that tripped and the usage at
    /// the moment of failure.
    case budgetExhausted(BudgetExhaustion, BudgetUsage)
    /// An output verifier returned `.reject`. `lastDiagnostic` is the most
    /// recent diagnostic surfaced during the run.
    case verifierRejected(reason: String, lastDiagnostic: Diagnostic?)
    /// A verifier returned `.escalate`, signalling the run cannot be
    /// completed without human intervention.
    case escalationRequired(reason: String, lastDiagnostic: Diagnostic?)
    /// The active ``Policy`` denied a privileged operation (typically a
    /// tool invocation lacking the required scope).
    case policyDenied(reason: String)
    /// The model asked for a tool that is not registered in the
    /// ``ToolRegistry``.
    case toolUnavailable(name: String)
    /// Decoding the model-supplied JSON arguments for a tool failed.
    /// `underlying` is the decoder's error message.
    case toolDecodeFailed(name: String, underlying: String)
    /// A tool's argument verifier chain rejected the decoded arguments.
    /// Distinguished from output-side ``verifierRejected(reason:lastDiagnostic:)``
    /// so callers can route argument-time failures separately (e.g. retry
    /// the tool call with a corrected argument prompt vs. fail the run).
    case toolArgumentRejected(name: String, diagnostic: Diagnostic)
    /// A tool's output verifier chain rejected the value the tool
    /// returned, so it was withheld from the model's context. Tool output
    /// is untrusted input (indirect prompt injection travels through it);
    /// this case is the typed surface for output-side rejections at the
    /// tool boundary, distinct from run-level
    /// ``verifierRejected(reason:lastDiagnostic:)``.
    case toolOutputRejected(name: String, diagnostic: Diagnostic)
    /// A tool was registered under a name the ``ToolRegistry`` already
    /// holds. Duplicate names would make instantiation ambiguous, so
    /// registration fails loudly instead of silently shadowing.
    case toolAlreadyRegistered(name: String)
    /// The on-device `SystemLanguageModel` is unavailable. The reason
    /// string mirrors the `Availability.UnavailableReason` returned by
    /// FoundationModels (device not eligible, Apple Intelligence not
    /// enabled, model still downloading).
    case modelUnavailable(reason: String)
    /// The on-device safety system blocked the prompt or the generation.
    /// `context` carries the framework's debug description when available.
    /// Terminal: retrying the same content will be blocked again.
    case guardrailViolation(context: String?)
    /// The session transcript plus prompt no longer fit the model's context
    /// window. `promptTokens` is the token count reported by the framework
    /// when available. Recoverable: compaction/summarization of the
    /// transcript lets the run continue.
    case contextWindowExceeded(promptTokens: Int?)
    /// The model declined to respond to the request. The payload carries
    /// the framework's debug description when available.
    case refusal(String?)
    /// The prompt used a language or locale the on-device model does not
    /// support. Terminal for the current input.
    case unsupportedLanguage
    /// The system model throttled the request (rate limit or concurrent
    /// request contention). Transient: retry after a backoff.
    case modelRateLimited
    /// Framework-boundary wrapper for `CancellationError`. Wrapping is
    /// optional — `CancellationError` is still thrown directly in most
    /// places; this case exists for the boundaries that prefer to surface
    /// cancellation as part of the umbrella type.
    case cancelled
    /// Anything else that crossed the framework boundary unwrapped.
    case underlying(any Error)

    /// Human-readable, low-noise summary suitable for diagnostics and logs.
    public var description: String {
        switch self {
        case .budgetExhausted(let kind, let usage):
            return "budget exhausted on \(kind.rawValue) (usage: turns=\(usage.turns), tools=\(usage.toolCalls), repairs=\(usage.repairAttempts))"
        case .verifierRejected(let reason, let diag):
            return "verifier rejected: \(reason)" + (diag.map { " — \($0.summary)" } ?? "")
        case .escalationRequired(let reason, _):
            return "escalation required: \(reason)"
        case .policyDenied(let reason):
            return "policy denied: \(reason)"
        case .toolUnavailable(let name):
            return "tool unavailable: \(name)"
        case .toolDecodeFailed(let name, let underlying):
            return "tool argument decode failed for \(name): \(underlying)"
        case .toolArgumentRejected(let name, let diagnostic):
            return "tool '\(name)' argument rejected: \(diagnostic.summary)"
        case .toolOutputRejected(let name, let diagnostic):
            return "tool '\(name)' output rejected: \(diagnostic.summary)"
        case .toolAlreadyRegistered(let name):
            return "tool already registered: \(name)"
        case .modelUnavailable(let reason):
            return "model unavailable: \(reason)"
        case .guardrailViolation(let context):
            return "guardrail violation" + (context.map { ": \($0)" } ?? "")
        case .contextWindowExceeded(let promptTokens):
            return "context window exceeded" + (promptTokens.map { " (prompt tokens: \($0))" } ?? "")
        case .refusal(let detail):
            return "model refused to respond" + (detail.map { ": \($0)" } ?? "")
        case .unsupportedLanguage:
            return "unsupported language or locale"
        case .modelRateLimited:
            return "model rate limited"
        case .cancelled:
            return "cancelled"
        case .underlying(let err):
            return "underlying error: \(err)"
        }
    }
}

extension CompoundError {
    /// Whether a caller could reasonably recover from this error by issuing
    /// another turn, repairing input, or asking a human — versus terminating
    /// the run.
    public enum Severity: Sendable, Equatable {
        /// The error can be retried with a different strategy or after operator
        /// input; the framework itself can re-enter a loop safely.
        case recoverable
        /// The error indicates the run cannot proceed without intervention
        /// outside the framework.
        case terminal
    }

    /// Severity routing: recoverable cases let the caller try a different
    /// strategy (e.g. ask the user, raise the budget, ask for help);
    /// terminal cases indicate the run cannot proceed without intervention
    /// outside the framework's loop.
    public var severity: Severity {
        switch self {
        case .budgetExhausted, .verifierRejected, .toolArgumentRejected, .toolOutputRejected,
             .escalationRequired, .cancelled, .contextWindowExceeded, .modelRateLimited:
            return .recoverable
        case .policyDenied, .toolUnavailable, .toolDecodeFailed, .toolAlreadyRegistered,
             .modelUnavailable, .underlying, .guardrailViolation, .refusal, .unsupportedLanguage:
            return .terminal
        }
    }

    /// Which architectural layer originated the error, for dashboarding and
    /// alert routing without string-matching ``description``.
    public enum Layer: String, Sendable, Equatable {
        /// Budget enforcement (turns, tool calls, repair attempts, wall clock, tokens).
        case budget
        /// Output or argument verifier rejection / escalation.
        case verifier
        /// ``Policy`` denial of a privileged operation.
        case policy
        /// Tool registry, decoding, or argument verification.
        case tool
        /// Model unavailability or runtime failure.
        case model
        /// Control-loop concerns such as cancellation.
        case control
        /// Anything not classified into the layers above.
        case unknown
    }

    /// Layer attribution for routing/alerting without parsing ``description``.
    public var layer: Layer {
        switch self {
        case .budgetExhausted: return .budget
        case .verifierRejected, .escalationRequired: return .verifier
        case .policyDenied: return .policy
        case .toolUnavailable, .toolDecodeFailed, .toolArgumentRejected, .toolOutputRejected,
             .toolAlreadyRegistered:
            return .tool
        case .modelUnavailable, .guardrailViolation, .contextWindowExceeded,
             .refusal, .unsupportedLanguage, .modelRateLimited:
            return .model
        case .cancelled: return .control
        case .underlying: return .unknown
        }
    }
}

extension CompoundError: LocalizedError {
    public var errorDescription: String? { description }

    public var failureReason: String? {
        switch self {
        case .budgetExhausted(let kind, _):
            return "budget exhausted on dimension '\(kind.rawValue)'"
        case .verifierRejected(let reason, _):
            return reason
        case .escalationRequired(let reason, _):
            return reason
        case .policyDenied(let reason):
            return reason
        case .toolUnavailable(let name):
            return "no registered tool named '\(name)' was available"
        case .toolDecodeFailed(_, let underlying):
            return underlying
        case .toolArgumentRejected(_, let diagnostic):
            return diagnostic.message
        case .toolOutputRejected(_, let diagnostic):
            return diagnostic.message
        case .toolAlreadyRegistered(let name):
            return "a tool named '\(name)' is already registered"
        case .modelUnavailable(let reason):
            return reason
        case .guardrailViolation(let context):
            return context ?? "the on-device safety system blocked the content"
        case .contextWindowExceeded(let promptTokens):
            return "the prompt and transcript exceeded the model's context window"
                + (promptTokens.map { " (\($0) tokens)" } ?? "")
        case .refusal(let detail):
            return detail ?? "the model declined to respond"
        case .unsupportedLanguage:
            return "the prompt's language or locale is not supported by the on-device model"
        case .modelRateLimited:
            return "the system model throttled the request"
        case .cancelled:
            return "the operation was cancelled"
        case .underlying(let err):
            return String(describing: err)
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .budgetExhausted:
            return "Raise the run's Budget, simplify the prompt, or split into multiple smaller runs."
        case .verifierRejected(_, let diag), .escalationRequired(_, let diag):
            return diag?.suggestion
        case .toolArgumentRejected(_, let diag):
            return diag.suggestion ?? "Adjust the tool's argument prompt and retry."
        case .toolOutputRejected(_, let diag):
            return diag.suggestion ?? "The tool's output failed verification; retry the call or tighten the tool's output contract."
        case .toolAlreadyRegistered:
            return "Register each tool name at most once, or rename the conflicting tool."
        case .policyDenied:
            return "Re-authenticate with the required scope or request the operator widen the policy."
        case .toolUnavailable:
            return "Register the tool with the ToolRegistry before invoking the run."
        case .toolDecodeFailed:
            return "Tighten the tool's argument schema or adjust the prompt to produce the expected shape."
        case .modelUnavailable:
            return "Retry after a short backoff; if the device's on-device model is unavailable, surface this to the user."
        case .guardrailViolation:
            return "Rephrase the request; the on-device safety system will block the same content again."
        case .contextWindowExceeded:
            return "Compact or summarize the transcript, or start a fresh session with a shorter prompt."
        case .refusal:
            return "Rephrase the request or adjust the session instructions."
        case .unsupportedLanguage:
            return "Use a language supported by Apple Intelligence on this device."
        case .modelRateLimited:
            return "Back off briefly and retry; the system model is throttling requests."
        case .cancelled:
            return nil
        case .underlying:
            return nil
        }
    }
}
