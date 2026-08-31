import Foundation
import FoundationModels

/// Wraps any `Retriever` as a tool the model can invoke explicitly when it
/// needs to look something up mid-turn. The model receives the top-K
/// matching sources rendered as a Markdown list of `[source-id] title —
/// excerpt`. Pair with ``CitationVerifier`` on the output verifier to
/// require the model to cite the sources it claims to ground on.
public struct SearchTool: Tool {
    public typealias Output = String

    public let name: String
    public let description: String
    public let parameters: GenerationSchema
    public let includesSchemaInInstructions: Bool = true

    /// Underlying retriever.
    public let retriever: any Retriever
    /// Default `limit` when the model omits it.
    public let defaultLimit: Int
    /// Hard cap on `limit` regardless of what the model requests.
    public let maxLimit: Int
    /// Maximum excerpt length per result, in characters.
    public let excerptMaxChars: Int

    /// Creates a tool over `retriever`.
    public init(
        name: String = "search",
        description: String = "Search the indexed corpus and return the top matching passages with their source IDs.",
        retriever: any Retriever,
        defaultLimit: Int = 5,
        maxLimit: Int = 20,
        excerptMaxChars: Int = 320
    ) {
        precondition(defaultLimit > 0 && maxLimit >= defaultLimit, "limits must be positive and ordered")
        self.name = name
        self.description = description
        self.retriever = retriever
        self.defaultLimit = defaultLimit
        self.maxLimit = maxLimit
        self.excerptMaxChars = excerptMaxChars
        let schema = DynamicGenerationSchema(
            name: "SearchArguments",
            description: "Arguments for the search tool",
            properties: [
                .init(
                    name: "query",
                    description: "Natural-language search query.",
                    schema: DynamicGenerationSchema(type: String.self)
                ),
                .init(
                    name: "limit",
                    description: "Maximum number of results to return. Defaults to \(defaultLimit); cap is \(maxLimit).",
                    schema: DynamicGenerationSchema(type: Int.self),
                    isOptional: true
                ),
            ]
        )
        self.parameters = try! GenerationSchema(root: schema, dependencies: [])
    }

    /// Decoded arguments for ``SearchTool``.
    public struct Arguments: ConvertibleFromGeneratedContent, Sendable {
        /// Natural-language query.
        public let query: String
        /// Caller-requested result cap (clamped to `[1, maxLimit]`).
        public let limit: Int?
        /// Decodes `content`.
        public init(_ content: GeneratedContent) throws {
            self.query = try content.value(String.self, forProperty: "query")
            self.limit = try? content.value(Int.self, forProperty: "limit")
        }
    }

    /// Runs the retriever and renders the results as `- [id] title —
    /// excerpt` lines. Returns `"no results"` when the retriever finds
    /// nothing or `"error: ..."` on retrieval failure; does not throw.
    public func call(arguments: Arguments) async throws -> String {
        let limit = min(maxLimit, max(1, arguments.limit ?? defaultLimit))
        let results: [RetrievedSource]
        do {
            results = try await retriever.retrieve(query: arguments.query, limit: limit)
        } catch {
            return ToolResult.inBandError("retrieval failed: \(error.localizedDescription)")
        }
        if results.isEmpty {
            return "no results"
        }
        return results.map { Self.renderEntry($0, excerptMaxChars: excerptMaxChars) }.joined(separator: "\n")
    }

    private static func renderEntry(_ source: RetrievedSource, excerptMaxChars: Int) -> String {
        var excerpt = source.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if excerpt.count > excerptMaxChars {
            excerpt = String(excerpt.prefix(excerptMaxChars)) + "…"
        }
        return "- [\(source.id)] \(source.title) — \(excerpt)"
    }
}
