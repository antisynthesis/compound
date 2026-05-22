import Foundation
import FoundationModels

/// The promise a tool makes before a run exists: that when the moment
/// comes, it can forge itself into a ``VerifiedTool`` bound to that run's
/// reality. The registry leans on this protocol to hide the per-tool
/// `Arguments` associated type from callers that just want to enumerate
/// what is on the table.
public protocol ToolRegistration: Sendable {
    /// Stable tool name (matches the wrapped `Tool.name`).
    var name: String { get }
    /// Scopes a caller's ``AuthContext`` must hold to invoke the tool.
    var requiredScopes: Set<String> { get }
    /// Builds a ``VerifiedTool`` bound to `runContext` and `policy`.
    func instantiate(runContext: RunContext, policy: any Policy) -> any Tool
}

/// A concrete ``ToolRegistration`` for one `FoundationModels.Tool`. It
/// owns the per-tool argument verifier chain, so the arguments the model
/// proposes are always disposed of by a verifier before the tool fires —
/// never on trust, never unguarded.
public struct GenericToolRegistration<Wrapped: Tool>: ToolRegistration where Wrapped.Arguments: Sendable {
    /// Underlying tool.
    public let wrapped: Wrapped
    /// Scopes required to invoke the tool.
    public let requiredScopes: Set<String>
    /// Argument-side verifiers (in any order; sorted by cost in the chain).
    public let argumentVerifiers: [AnyVerifier<Wrapped.Arguments>]

    /// Creates a registration.
    public init(
        _ wrapped: Wrapped,
        requiredScopes: Set<String> = [],
        argumentVerifiers: [AnyVerifier<Wrapped.Arguments>] = []
    ) {
        self.wrapped = wrapped
        self.requiredScopes = requiredScopes
        self.argumentVerifiers = argumentVerifiers
    }

    /// Inherited tool name.
    public var name: String { wrapped.name }

    /// Builds the per-run ``VerifiedTool`` instance.
    public func instantiate(runContext: RunContext, policy: any Policy) -> any Tool {
        VerifiedTool(
            wrapped: wrapped,
            argumentVerifiers: VerifierChain(
                name: "\(wrapped.name)-args",
                argumentVerifiers
            ),
            requiredScopes: requiredScopes,
            runContext: runContext,
            policy: policy
        )
    }
}

/// The catalogue of what the model is permitted to reach for, and the
/// terms it never gets to see. The registry pairs each tool with the
/// deterministic metadata the model is never shown — required scopes,
/// argument verifiers — then forges per-run ``VerifiedTool`` wrappers
/// bound to the live ``RunContext``. The model asks; this layer decides.
///
/// # Example
/// ```swift
/// var registry = ToolRegistry()
/// registry.register(
///     CalculatorTool(),
///     requiredScopes: ["compute.read"],
///     argumentVerifiers: [CalculatorBoundsVerifier().erased()]
/// )
/// let tools = registry.instantiateAll(runContext: ctx, policy: policy)
/// ```
public struct ToolRegistry: Sendable {
    /// Registered tools in insertion order.
    public private(set) var registrations: [any ToolRegistration]

    /// Creates a registry seeded with `registrations`.
    public init(_ registrations: [any ToolRegistration] = []) {
        self.registrations = registrations
    }

    /// Registers a tool with optional scope requirements and argument
    /// verifiers.
    public mutating func register<Wrapped: Tool>(
        _ tool: Wrapped,
        requiredScopes: Set<String> = [],
        argumentVerifiers: [AnyVerifier<Wrapped.Arguments>] = []
    ) where Wrapped.Arguments: Sendable {
        registrations.append(
            GenericToolRegistration(
                tool,
                requiredScopes: requiredScopes,
                argumentVerifiers: argumentVerifiers
            )
        )
    }

    /// Instantiates every registered tool against `runContext`/`policy`.
    public func instantiateAll(runContext: RunContext, policy: any Policy) -> [any Tool] {
        registrations.map { $0.instantiate(runContext: runContext, policy: policy) }
    }

    /// Names of every registered tool, in insertion order.
    public var names: [String] {
        registrations.map(\.name)
    }

    /// `true` if no tools are registered.
    public var isEmpty: Bool { registrations.isEmpty }
}
