import Foundation
import FoundationModels

/// The contract for where the model's scratch space actually lives — and
/// for whom. Every backend method takes a `principal: String`, because a
/// keyspace without an owner is a leak waiting to happen: this is how one
/// backend serves many ``CompoundSession`` instances without one tenant's
/// keys bleeding into another's. The built-in ``InMemoryKVStoreBackend``
/// namespaces per-principal; ``SharedKVStoreBackend`` exists only for the
/// caller who deliberately wants one global keyspace and accepts every
/// consequence that implies.
public protocol KVStoreBackend: Sendable {
    /// Returns the value stored at `key` for `principal`, or `nil`.
    func get(_ key: String, principal: String) async throws -> String?
    /// Stores `value` at `key` for `principal`.
    func set(_ key: String, value: String, principal: String) async throws
    /// Deletes the entry at `key` for `principal`.
    func delete(_ key: String, principal: String) async throws
    /// Returns all keys belonging to `principal`.
    func keys(principal: String) async throws -> [String]
}

/// On-device, process-local, and walled off by `principal`. Nothing
/// persists, nothing escapes the process, and two callers with different
/// principals see strictly disjoint keyspaces — isolation by construction,
/// not by convention.
public actor InMemoryKVStoreBackend: KVStoreBackend {
    private var stores: [String: [String: String]] = [:]
    /// Creates an empty backend.
    public init() {}

    public func get(_ key: String, principal: String) async -> String? {
        stores[principal]?[key]
    }

    public func set(_ key: String, value: String, principal: String) async {
        stores[principal, default: [:]][key] = value
    }

    public func delete(_ key: String, principal: String) async {
        stores[principal]?.removeValue(forKey: key)
        if stores[principal]?.isEmpty == true {
            stores.removeValue(forKey: principal)
        }
    }

    public func keys(principal: String) async -> [String] {
        (stores[principal].map { Array($0.keys) } ?? []).sorted()
    }
}

/// One keyspace, no walls. Reach for this only when you have decided, on
/// purpose, that every caller should see every other caller's keys — an
/// offline single-user app, say. For anything multi-tenant or
/// per-user-account, this is the wrong instrument; use
/// ``InMemoryKVStoreBackend`` instead.
public actor SharedKVStoreBackend: KVStoreBackend {
    private var store: [String: String] = [:]
    /// Creates an empty backend.
    public init() {}
    public func get(_ key: String, principal _: String) async -> String? { store[key] }
    public func set(_ key: String, value: String, principal _: String) async { store[key] = value }
    public func delete(_ key: String, principal _: String) async { store.removeValue(forKey: key) }
    public func keys(principal _: String) async -> [String] { Array(store.keys).sorted() }
}

/// Memory the model can reach for within a run, and not one byte further.
/// Scratch space for multi-turn work — pinning an extracted entity for
/// later turns, accumulating partial results, stashing a tool's output for
/// re-use. The model reads and writes; it never sees or chooses the
/// principal its keys are filed under.
public struct KVStoreTool: Tool {
    public typealias Output = String

    public let name: String = "kv_store"
    public let description: String = "Read, write, delete, or list keys in a session-scoped key-value store."
    public let parameters: GenerationSchema
    public let includesSchemaInInstructions: Bool = true

    /// Storage backend.
    public let backend: any KVStoreBackend
    /// The principal whose keyspace this tool reads and writes. Bound
    /// at construction (or via ``withPrincipal(_:)``) so the model
    /// never sees or controls the principal.
    public let principal: String

    /// Creates a tool bound to `backend` and `principal`.
    public init(
        backend: any KVStoreBackend = InMemoryKVStoreBackend(),
        principal: String = AuthContext.anonymous.principal
    ) {
        self.backend = backend
        self.principal = principal
        let schema = DynamicGenerationSchema(
            name: "KVStoreArguments",
            description: "Arguments for the kv_store tool",
            properties: [
                .init(
                    name: "op",
                    description: "Operation to perform: 'get', 'set', 'delete', or 'list'.",
                    schema: DynamicGenerationSchema(name: "Operation", anyOf: ["get", "set", "delete", "list"])
                ),
                .init(
                    name: "key",
                    description: "Key to operate on. Required for get / set / delete; ignored for list.",
                    schema: DynamicGenerationSchema(type: String.self),
                    isOptional: true
                ),
                .init(
                    name: "value",
                    description: "Value to write. Required for set; ignored otherwise.",
                    schema: DynamicGenerationSchema(type: String.self),
                    isOptional: true
                ),
            ]
        )
        self.parameters = try! GenerationSchema(root: schema, dependencies: [])
    }

    /// Return a copy of this tool bound to a new principal. Used by
    /// ``KVStoreToolRegistration`` to plumb the per-run `AuthContext`
    /// through the otherwise context-free `Tool.call` signature.
    public func withPrincipal(_ principal: String) -> KVStoreTool {
        KVStoreTool(backend: backend, principal: principal)
    }

    /// Decoded arguments for ``KVStoreTool``.
    public struct Arguments: ConvertibleFromGeneratedContent, Sendable {
        /// Operation: `"get"`, `"set"`, `"delete"`, or `"list"`.
        public let op: String
        /// Target key (required for get / set / delete).
        public let key: String?
        /// Replacement value (required for set).
        public let value: String?
        /// Decodes `content`.
        public init(_ content: GeneratedContent) throws {
            self.op = try content.value(String.self, forProperty: "op")
            self.key = try? content.value(String.self, forProperty: "key")
            self.value = try? content.value(String.self, forProperty: "value")
        }
    }

    /// Dispatches `op` to the backend. Returns one of: the stored value
    /// (`get`), `"not-found"` (missing `get`), `"ok"` (mutating ops),
    /// the newline-joined key list (`list`), or `"error: ..."` on
    /// validation failure. Does not throw.
    public func call(arguments: Arguments) async throws -> String {
        switch arguments.op {
        case "get":
            guard let key = arguments.key else { return "error: 'key' is required for get" }
            let v = try await backend.get(key, principal: principal)
            return v ?? "not-found"
        case "set":
            guard let key = arguments.key else { return "error: 'key' is required for set" }
            guard let value = arguments.value else { return "error: 'value' is required for set" }
            try await backend.set(key, value: value, principal: principal)
            return "ok"
        case "delete":
            guard let key = arguments.key else { return "error: 'key' is required for delete" }
            try await backend.delete(key, principal: principal)
            return "ok"
        case "list":
            let ks = try await backend.keys(principal: principal)
            return ks.joined(separator: "\n")
        default:
            return "error: unknown op '\(arguments.op)' (expected get / set / delete / list)"
        }
    }
}

/// The registration that keeps tenants honest. It rebinds ``KVStoreTool``
/// to the caller's principal at the instant of instantiation, so one
/// registered tool can serve many `CompoundSession` invocations under
/// different `AuthContext`s without a single key crossing the line between
/// them. Identity is decided here, not by the model.
public struct KVStoreToolRegistration: ToolRegistration {
    /// Template tool whose principal is replaced at instantiation.
    public let tool: KVStoreTool
    /// Scopes required to invoke the tool.
    public let requiredScopes: Set<String>
    /// Argument verifiers run before the tool executes.
    public let argumentVerifiers: [AnyVerifier<KVStoreTool.Arguments>]

    /// Creates a registration.
    public init(
        _ tool: KVStoreTool,
        requiredScopes: Set<String> = [],
        argumentVerifiers: [AnyVerifier<KVStoreTool.Arguments>] = []
    ) {
        self.tool = tool
        self.requiredScopes = requiredScopes
        self.argumentVerifiers = argumentVerifiers
    }

    /// Inherited tool name.
    public var name: String { tool.name }

    /// Builds a verified tool with the principal rebound to
    /// `runContext.auth.principal`.
    public func instantiate(runContext: RunContext, policy: any Policy) -> any Tool {
        let bound = tool.withPrincipal(runContext.auth.principal)
        return VerifiedTool(
            wrapped: bound,
            argumentVerifiers: VerifierChain(
                name: "\(tool.name)-args",
                argumentVerifiers
            ),
            requiredScopes: requiredScopes,
            runContext: runContext,
            policy: policy
        )
    }
}
