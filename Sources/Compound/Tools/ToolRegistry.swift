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
/// Owns the per-tool argument and output verifier chains so the wrapped
/// tool's arguments are always gated before execution and its output is
/// always gated before re-entering the model's context.
public struct GenericToolRegistration<Wrapped: Tool>: ToolRegistration
where Wrapped.Arguments: Sendable, Wrapped.Output: Sendable {
    /// Underlying tool.
    public let wrapped: Wrapped
    /// Scopes required to invoke the tool.
    public let requiredScopes: Set<String>
    /// Argument-side verifiers (in any order; sorted by cost in the chain).
    public let argumentVerifiers: [AnyVerifier<Wrapped.Arguments>]
    /// Output-side verifiers run against the tool's result before it is
    /// returned to the model (in any order; sorted by cost in the chain).
    public let outputVerifiers: [AnyVerifier<Wrapped.Output>]

    /// Creates a registration.
    public init(
        _ wrapped: Wrapped,
        requiredScopes: Set<String> = [],
        argumentVerifiers: [AnyVerifier<Wrapped.Arguments>] = [],
        outputVerifiers: [AnyVerifier<Wrapped.Output>] = []
    ) {
        self.wrapped = wrapped
        self.requiredScopes = requiredScopes
        self.argumentVerifiers = argumentVerifiers
        self.outputVerifiers = outputVerifiers
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
            outputVerifiers: VerifierChain(
                name: "\(wrapped.name)-output",
                outputVerifiers
            ),
            requiredScopes: requiredScopes,
            runContext: runContext,
            policy: policy
        )
    }
}

/// Collects tools alongside the deterministic metadata the model never
/// sees (required scopes, argument and output verifiers) and instantiates
/// per-run ``VerifiedTool`` wrappers bound to the live ``RunContext``.
///
/// Tool names must be unique: ``register(_:requiredScopes:argumentVerifiers:outputVerifiers:)``
/// throws ``CompoundError/toolAlreadyRegistered(name:)`` on a duplicate
/// name rather than silently shadowing an earlier registration.
///
/// # Example
/// ```swift
/// var registry = ToolRegistry()
/// try registry.register(
///     CalculatorTool(),
///     requiredScopes: ["compute.read"],
///     argumentVerifiers: [CalculatorBoundsVerifier().erased()]
/// )
/// let tools = registry.instantiateAll(runContext: ctx, policy: policy)
/// ```
public struct ToolRegistry: Sendable {
    /// Registered tools in insertion order.
    public private(set) var registrations: [any ToolRegistration]

    /// Creates a registry seeded with `registrations`. The seed is taken
    /// as-is; callers assembling the seed by hand are responsible for
    /// name uniqueness (``register(_:)`` enforces it from then on).
    public init(_ registrations: [any ToolRegistration] = []) {
        self.registrations = registrations
    }

    /// Registers a tool with optional scope requirements and argument /
    /// output verifiers.
    ///
    /// - Throws: ``CompoundError/toolAlreadyRegistered(name:)`` when a
    ///   registration with the same tool name already exists.
    public mutating func register<Wrapped: Tool>(
        _ tool: Wrapped,
        requiredScopes: Set<String> = [],
        argumentVerifiers: [AnyVerifier<Wrapped.Arguments>] = [],
        outputVerifiers: [AnyVerifier<Wrapped.Output>] = []
    ) throws where Wrapped.Arguments: Sendable, Wrapped.Output: Sendable {
        try register(
            GenericToolRegistration(
                tool,
                requiredScopes: requiredScopes,
                argumentVerifiers: argumentVerifiers,
                outputVerifiers: outputVerifiers
            )
        )
    }

    /// Registers a pre-built ``ToolRegistration`` (e.g.
    /// ``KVStoreToolRegistration``).
    ///
    /// - Throws: ``CompoundError/toolAlreadyRegistered(name:)`` when a
    ///   registration with the same tool name already exists.
    public mutating func register(_ registration: any ToolRegistration) throws {
        guard !registrations.contains(where: { $0.name == registration.name }) else {
            throw CompoundError.toolAlreadyRegistered(name: registration.name)
        }
        registrations.append(registration)
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
