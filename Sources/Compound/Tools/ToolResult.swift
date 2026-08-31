import Foundation

/// Conventions for the in-band result strings that string-output tools
/// return to the model instead of throwing.
///
/// Builtins like ``CalculatorTool`` and ``WebFetchTool`` deliberately
/// return validation and runtime failures *in band* — as `"error: ..."`
/// strings — so the model can read the failure and retry with corrected
/// arguments instead of aborting the run. `ToolResult` centralizes that
/// convention so (1) every builtin produces the same prefix, and
/// (2) ``VerifiedTool`` can recognize an in-band failure and record the
/// invocation as `succeeded: false` in the trace rather than dishonestly
/// reporting success.
public enum ToolResult {
    /// Prefix that marks a tool result string as an in-band failure.
    public static let inBandErrorPrefix = "error:"

    /// Formats `message` as an in-band failure string (`"error: ..."`).
    public static func inBandError(_ message: String) -> String {
        "\(inBandErrorPrefix) \(message)"
    }

    /// `true` if `output` is an in-band failure string.
    public static func isInBandError(_ output: String) -> Bool {
        output.hasPrefix(inBandErrorPrefix)
    }

    /// In-band repair request returned when a tool's *argument* verifier
    /// chain votes ``Verdict/repair(_:)``. Carries the diagnostic message
    /// and suggestion so the model can correct the arguments and call the
    /// tool again, preserving repair semantics at the tool boundary
    /// instead of collapsing `.repair` into a thrown rejection.
    public static func argumentRepairRequest(tool: String, diagnostic: Diagnostic) -> String {
        var message = "tool '\(tool)' arguments need repair: \(diagnostic.message)."
        if let suggestion = diagnostic.suggestion {
            message += " Suggestion: \(suggestion)."
        }
        message += " Adjust the arguments and call the tool again."
        return inBandError(message)
    }

    /// In-band repair request returned when a tool's *output* verifier
    /// chain votes ``Verdict/repair(_:)``. The rejected output never
    /// reaches the model; the diagnostic (and suggestion, when present)
    /// travels back instead so the model can retry the call.
    public static func outputRepairRequest(tool: String, diagnostic: Diagnostic) -> String {
        var message = "tool '\(tool)' output failed verification: \(diagnostic.message)."
        if let suggestion = diagnostic.suggestion {
            message += " Suggestion: \(suggestion)."
        }
        message += " The output was withheld; adjust the request and call the tool again."
        return inBandError(message)
    }
}
