import Foundation

/// Carries the caller's identity, granted scopes, and free-form attributes
/// through a run. Governance lives at the deterministic chokepoints:
/// authorization travels with every tool call and ``Policy`` decisions are
/// evaluated by code that runs regardless of what the model proposes.
/// The model is not a security boundary.
public struct AuthContext: Sendable, Equatable {
    /// Stable principal identifier (user id, service account, etc.).
    public let principal: String
    /// Granted scope strings.
    public let scopes: Set<String>
    /// Free-form attributes propagated alongside the principal.
    public let attributes: [String: String]

    /// Creates an auth context.
    public init(principal: String, scopes: Set<String> = [], attributes: [String: String] = [:]) {
        self.principal = principal
        self.scopes = scopes
        self.attributes = attributes
    }

    /// Anonymous caller with no scopes.
    public static let anonymous = AuthContext(principal: "anonymous")

    /// `true` when `scope` is in ``scopes``.
    public func hasScope(_ scope: String) -> Bool {
        scopes.contains(scope)
    }
}

/// Outcome of a ``Policy/evaluate(_:auth:)`` call.
public enum PolicyDecision: Sendable, Equatable {
    /// The operation is permitted.
    case allow
    /// The operation is denied; `reason` is surfaced to the caller and
    /// in trace events.
    case deny(reason: String)

    /// `true` when this is ``allow``.
    public var isAllowed: Bool {
        if case .allow = self { return true }
        return false
    }
}

/// What is being authorized. Policy evaluators dispatch on the case.
public enum PolicySubject: Sendable {
    /// A tool invocation gated by `requiredScopes`.
    case toolInvocation(name: String, requiredScopes: Set<String>)
    /// The (post-redaction) user prompt about to be sent to the model.
    case promptContent(redactedSize: Int, classification: String?)
    /// Model output about to be returned to the caller.
    case modelOutput(byteCount: Int, classification: String?)

    /// Short, stable label used in trace events.
    public var label: String {
        switch self {
        case .toolInvocation(let name, _): return "tool:\(name)"
        case .promptContent: return "prompt"
        case .modelOutput: return "output"
        }
    }
}

/// Authority that decides whether a ``PolicySubject`` is permitted for a
/// given ``AuthContext``. Policies are pure functions of subject and
/// auth — they should not consult external mutable state.
public protocol Policy: Sendable {
    /// Stable policy name surfaced in trace events.
    var name: String { get }
    /// Evaluates `subject` for `auth`.
    func evaluate(_ subject: PolicySubject, auth: AuthContext) async -> PolicyDecision
}

/// Policy that requires the auth context's ``AuthContext/scopes`` to
/// cover the tool's `requiredScopes`. Always allows prompt and output
/// subjects.
public struct ScopeRequirement: Policy {
    public let name: String = "scope-requirement"

    /// Creates an instance.
    public init() {}

    /// Allows tool invocations when every required scope is present;
    /// denies with a list of missing scopes otherwise.
    public func evaluate(_ subject: PolicySubject, auth: AuthContext) async -> PolicyDecision {
        switch subject {
        case .toolInvocation(let toolName, let required):
            let missing = required.subtracting(auth.scopes)
            if missing.isEmpty {
                return .allow
            }
            return .deny(reason: "tool \(toolName) requires scopes: \(missing.sorted().joined(separator: ", "))")
        case .promptContent, .modelOutput:
            return .allow
        }
    }
}

/// Policy that allows every subject. Useful as the default for trusted,
/// single-user contexts and as a placeholder in tests.
public struct AllowAll: Policy {
    public let name: String = "allow-all"
    /// Creates an instance.
    public init() {}
    /// Always returns `.allow`.
    public func evaluate(_: PolicySubject, auth _: AuthContext) async -> PolicyDecision { .allow }
}

/// AND-composes multiple policies; the first member that returns
/// `.deny` short-circuits.
public struct CompositePolicy: Policy {
    /// Stable name.
    public let name: String
    /// Member policies, evaluated in order.
    public let members: [any Policy]

    /// Creates a composite over `members`.
    public init(name: String = "composite", _ members: [any Policy]) {
        self.name = name
        self.members = members
    }

    /// Evaluates members in order; returns the first `.deny` or
    /// `.allow` if every member allowed.
    public func evaluate(_ subject: PolicySubject, auth: AuthContext) async -> PolicyDecision {
        for member in members {
            let decision = await member.evaluate(subject, auth: auth)
            if case .deny = decision { return decision }
        }
        return .allow
    }
}
