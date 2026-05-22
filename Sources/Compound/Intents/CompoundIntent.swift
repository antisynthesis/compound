import Foundation

#if canImport(AppIntents)
import AppIntents

/// The system meeting the user where they already are. This adapts a Compound
/// flow into Apple's AppIntents so the same verified, observable, governed
/// pipeline is reachable from Siri, Shortcuts, Spotlight, and the system intent
/// surfaces — no second, weaker path bolted on for convenience.
///
/// Adopters supply a `CompoundSession` and a `prompt(from:)` mapping their
/// `@Parameter` properties to a model prompt. The default `perform()` runs
/// the session and returns the verified output as an `IntentResult` value.
/// Verifier failures, policy denials, and budget exhaustion surface as
/// localized errors with stable error codes.
///
/// Use this when the action you want to expose is itself a compound run —
/// "Summarize this article", "Draft a reply", "Extract action items".
/// Tool-level intents (calculator, fetch) should adopt
/// ``CompoundToolIntent`` instead, which wraps a `Tool` rather than a full
/// session.
@available(iOS 16.0, macOS 13.0, visionOS 1.0, *)
public protocol CompoundIntent: AppIntent {
    /// Session that backs the intent.
    var session: CompoundSession { get }
    /// Identity supplied to the run; defaults to ``AuthContext/anonymous``.
    var auth: AuthContext { get }
    /// Returns the model prompt assembled from this intent's parameters.
    func prompt() throws -> String
}

@available(iOS 16.0, macOS 13.0, visionOS 1.0, *)
extension CompoundIntent {
    /// Default identity: anonymous.
    public var auth: AuthContext { .anonymous }

    /// Runs the underlying ``CompoundSession`` and returns output that has
    /// already survived verification — the intent surface gets the disposed
    /// result, never the raw proposal. Translates ``CompoundError`` into
    /// ``IntentBridgeError`` so callers see localized failure reasons.
    public func performCompoundRun() async throws -> String {
        let assembledPrompt = try prompt()
        do {
            let outcome = try await session.respond(
                to: assembledPrompt,
                auth: auth,
                progress: NullProgressReporter(),
                metadata: [:]
            )
            return outcome.output
        } catch let err as CompoundError {
            throw IntentBridgeError(compound: err)
        }
    }
}

/// Exposes a single `FoundationModels.Tool` as an AppIntent. Unlike
/// ``CompoundIntent``, the model never enters the room — this calls the
/// underlying tool directly, still gated by the same `VerifiedTool` policy
/// and argument verifiers. Skipping the model does not mean skipping the
/// guardrails. The decoded `@Parameter` properties are converted to
/// `Arguments` via ``arguments()``.
@available(iOS 16.0, macOS 13.0, visionOS 1.0, *)
public protocol CompoundToolIntent: AppIntent {
    associatedtype Wrapped: AnyObject & Sendable
    /// Adapter that performs the gated tool call.
    var verifiedTool: VerifiedToolAdapter<Wrapped> { get }
    /// Returns the argument dictionary built from this intent's parameters.
    func argumentsBlob() throws -> [String: any Sendable]
}

/// A type-erased seam that decouples a `CompoundToolIntent` from the concrete
/// `Tool` protocol in `FoundationModels`. Applications keep their
/// `VerifiedTool` instances inside this adapter so the intent surface stays
/// Generable-free — the boundary is deliberate, not incidental.
@available(iOS 16.0, macOS 13.0, visionOS 1.0, *)
public struct VerifiedToolAdapter<Wrapped>: Sendable {
    private let invoke: @Sendable ([String: any Sendable]) async throws -> String
    /// Stable tool name for diagnostics.
    public let name: String

    /// Wraps the supplied invocation closure.
    public init(
        name: String,
        invoke: @escaping @Sendable ([String: any Sendable]) async throws -> String
    ) {
        self.name = name
        self.invoke = invoke
    }

    /// Invokes the underlying ``VerifiedTool`` with `arguments`.
    public func call(_ arguments: [String: any Sendable]) async throws -> String {
        try await invoke(arguments)
    }
}

/// Translates a `CompoundError` into something a Shortcuts user can actually
/// act on: a stable, identifiable code and a useful failure reason instead of
/// a raw description leaked from the internals. A failure should explain
/// itself, not mumble.
@available(iOS 16.0, macOS 13.0, visionOS 1.0, *)
public struct IntentBridgeError: Swift.Error, CustomLocalizedStringResourceConvertible {
    /// Originating ``CompoundError``.
    public let compound: CompoundError
    /// Wraps `compound`.
    public init(compound: CompoundError) { self.compound = compound }

    /// Localized representation surfaced to AppIntents consumers.
    public var localizedStringResource: LocalizedStringResource {
        switch compound {
        case .budgetExhausted(let kind, _):
            return "Budget exhausted: \(kind.rawValue)."
        case .verifierRejected(let reason, _):
            return "Verification failed: \(reason)."
        case .escalationRequired(let reason, _):
            return "Human review required: \(reason)."
        case .policyDenied(let reason):
            return "Action not permitted: \(reason)."
        case .toolUnavailable(let name):
            return "Tool '\(name)' unavailable."
        case .toolDecodeFailed(let name, _):
            return "Tool '\(name)' received invalid arguments."
        case .toolArgumentRejected(let name, let diagnostic):
            return "Tool '\(name)' argument rejected: \(diagnostic.message)."
        case .modelUnavailable(let reason):
            return "Model unavailable: \(reason)."
        case .cancelled:
            return "Operation cancelled."
        case .underlying(let error):
            return "\(String(describing: error))"
        }
    }
}
#endif
