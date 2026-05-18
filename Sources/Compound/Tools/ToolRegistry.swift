import Foundation
import FoundationModels

/// Existential descriptor for a tool that knows how to instantiate
/// itself as a ``VerifiedTool`` for a specific run. The registry uses
/// this protocol to hide the per-tool `Arguments` associated type from
/// callers that just want to enumerate registrations.
public protocol ToolRegistration: Sendable {
    /// Stable tool name (matches the wrapped `Tool.name`).
    var name: String { get }
    /// Scopes a caller's ``AuthContext`` must hold to invoke the tool.
    var requiredScopes: Set<String> { get }
    /// Builds a ``VerifiedTool`` bound to `runContext` and `policy`.
    func instantiate(runContext: RunContext, policy: any Policy) -> any Tool
}

/// Concrete ``ToolRegistration`` for a single `FoundationModels.Tool`.
/// Owns the per-tool argument verifier chain so the wrapped tool's
/// arguments are always gated before execution.
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

/// Collects tools alongside the deterministic metadata the model never
/// sees (required scopes, argument verifiers) and instantiates per-run
/// ``VerifiedTool`` wrappers bound to the live ``RunContext``.
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
