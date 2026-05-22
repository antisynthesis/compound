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

/// The verdict of a ``Policy/evaluate(_:auth:)`` call: permitted, or denied
/// with a reason. There is no implicit third option — silence is not consent.
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

/// The thing under authorization, named precisely so policy can dispatch on
/// exactly what it is — a tool call, a prompt, or model output — and never on
/// a vague notion of "the request."
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

/// Explicit, scoped authority. A `Policy` decides whether a ``PolicySubject``
/// is permitted for a given ``AuthContext`` — nothing is trusted by default,
/// and the model gets no vote. Policies are pure functions of subject and
/// auth; they must not consult external mutable state, because authority you
/// can't reason about isn't authority, it's hope.
public protocol Policy: Sendable {
    /// Stable policy name surfaced in trace events.
    var name: String { get }
    /// Evaluates `subject` for `auth`.
    func evaluate(_ subject: PolicySubject, auth: AuthContext) async -> PolicyDecision
}

/// A policy that grants a tool call only when the caller's
/// ``AuthContext/scopes`` actually cover the tool's `requiredScopes` — the
/// scope you weren't granted is the scope you don't get. Prompt and output
/// subjects always pass here.
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

/// A policy that permits everything. Honest about what it is: a deliberate
/// surrender of the gate, fit only for trusted single-user contexts and
/// tests. Reach for it knowingly, never by accident.
public struct AllowAll: Policy {
    public let name: String = "allow-all"
    /// Creates an instance.
    public init() {}
    /// Always returns `.allow`.
    public func evaluate(_: PolicySubject, auth _: AuthContext) async -> PolicyDecision { .allow }
}

/// Composes policies under AND: every member must allow, and the first one to
/// return `.deny` ends the conversation. A single refusal is enough; consensus
/// is not required to say no.
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
