import Foundation
import FoundationModels
import Testing
@testable import Compound

@Suite("BuiltinTool")
struct BuiltinToolTests {
    @Test("calculator evaluates a basic expression")
    func calculatorBasic() async throws {
        let tool = CalculatorTool()
        let args = try CalculatorTool.Arguments(GeneratedContent(properties: ["expression": "2 + 3 * 4"]))
        let result = try await tool.call(arguments: args)
        #expect(result == "14")
    }

    @Test("calculator rejects disallowed characters")
    func calculatorRejectsDisallowed() async throws {
        let tool = CalculatorTool()
        let args = try CalculatorTool.Arguments(GeneratedContent(properties: ["expression": "exit(1)"]))
        let result = try await tool.call(arguments: args)
        #expect(result.hasPrefix("error:"))
    }

    @Test("calculator handles parentheses and floats")
    func calculatorParensFloats() async throws {
        let tool = CalculatorTool()
        let args = try CalculatorTool.Arguments(GeneratedContent(properties: ["expression": "(1.5 + 0.5) * 4"]))
        let result = try await tool.call(arguments: args)
        #expect(result == "8")
    }

    @Test("kv store round-trips set/get/delete")
    func kvStoreRoundTrips() async throws {
        let tool = KVStoreTool()
        let set = try KVStoreTool.Arguments(GeneratedContent(properties: ["op": "set", "key": "name", "value": "Ada"]))
        _ = try await tool.call(arguments: set)
        let get = try KVStoreTool.Arguments(GeneratedContent(properties: ["op": "get", "key": "name"]))
        #expect(try await tool.call(arguments: get) == "Ada")
        let del = try KVStoreTool.Arguments(GeneratedContent(properties: ["op": "delete", "key": "name"]))
        _ = try await tool.call(arguments: del)
        let missing = try await tool.call(arguments: get)
        #expect(missing == "not-found")
    }

    @Test("kv store lists keys")
    func kvStoreListsKeys() async throws {
        let tool = KVStoreTool()
        for (k, v) in [("a", "1"), ("b", "2"), ("c", "3")] {
            let set = try KVStoreTool.Arguments(GeneratedContent(properties: ["op": "set", "key": k, "value": v]))
            _ = try await tool.call(arguments: set)
        }
        let list = try KVStoreTool.Arguments(GeneratedContent(properties: ["op": "list"]))
        let listed = try await tool.call(arguments: list)
        #expect(listed.contains("a"))
        #expect(listed.contains("b"))
        #expect(listed.contains("c"))
    }

    @Test("kv store rejects missing key for set")
    func kvStoreRejectsMissingKey() async throws {
        let tool = KVStoreTool()
        let args = try KVStoreTool.Arguments(GeneratedContent(properties: ["op": "set"]))
        let result = try await tool.call(arguments: args)
        #expect(result.contains("required"))
    }

    @Test("kv store isolates keys across principals")
    func kvStoreIsolatesKeys() async throws {
        let backend = InMemoryKVStoreBackend()
        let alice = KVStoreTool(backend: backend, principal: "alice")
        let bob = KVStoreTool(backend: backend, principal: "bob")

        let set = try KVStoreTool.Arguments(GeneratedContent(properties: [
            "op": "set", "key": "secret", "value": "alice-only",
        ]))
        _ = try await alice.call(arguments: set)

        let get = try KVStoreTool.Arguments(GeneratedContent(properties: [
            "op": "get", "key": "secret",
        ]))
        #expect(try await alice.call(arguments: get) == "alice-only")
        #expect(try await bob.call(arguments: get) == "not-found")

        let list = try KVStoreTool.Arguments(GeneratedContent(properties: ["op": "list"]))
        #expect(!(try await bob.call(arguments: list)).contains("secret"))
    }

    @Test("kv store shared backend opts in to a global keyspace")
    func kvStoreSharedBackend() async throws {
        let backend = SharedKVStoreBackend()
        let alice = KVStoreTool(backend: backend, principal: "alice")
        let bob = KVStoreTool(backend: backend, principal: "bob")
        let set = try KVStoreTool.Arguments(GeneratedContent(properties: [
            "op": "set", "key": "shared", "value": "visible",
        ]))
        _ = try await alice.call(arguments: set)
        let get = try KVStoreTool.Arguments(GeneratedContent(properties: [
            "op": "get", "key": "shared",
        ]))
        #expect(try await bob.call(arguments: get) == "visible")
    }

    @Test("kv store registration rebinds principal from RunContext")
    func kvStoreRegistrationRebindsPrincipal() async throws {
        let backend = InMemoryKVStoreBackend()
        let registration = KVStoreToolRegistration(KVStoreTool(backend: backend))
        let aliceCtx = RunContext(auth: AuthContext(principal: "alice"))
        let bobCtx = RunContext(auth: AuthContext(principal: "bob"))
        let aliceTool = registration.instantiate(runContext: aliceCtx, policy: AllowAll())
        let bobTool = registration.instantiate(runContext: bobCtx, policy: AllowAll())

        let set = try KVStoreTool.Arguments(GeneratedContent(properties: [
            "op": "set", "key": "k", "value": "alice",
        ]))
        _ = try await (aliceTool as! VerifiedTool<KVStoreTool>).call(arguments: set)
        let get = try KVStoreTool.Arguments(GeneratedContent(properties: ["op": "get", "key": "k"]))
        #expect(try await (bobTool as! VerifiedTool<KVStoreTool>).call(arguments: get) == "not-found")
        #expect(try await (aliceTool as! VerifiedTool<KVStoreTool>).call(arguments: get) == "alice")
    }

    @Test("calculator rejects oversized expressions")
    func calculatorRejectsOversized() async throws {
        let tool = CalculatorTool()
        let huge = String(repeating: "1+", count: 200) + "1"
        let args = try CalculatorTool.Arguments(GeneratedContent(properties: ["expression": huge]))
        let result = try await tool.call(arguments: args)
        #expect(result.hasPrefix("error:"))
        #expect(result.contains("256"))
    }

    @Test("calculator rejects deeply nested parentheses")
    func calculatorRejectsDeepNesting() async throws {
        let tool = CalculatorTool()
        let depth = 40
        let deep = String(repeating: "(", count: depth) + "1" + String(repeating: ")", count: depth)
        let args = try CalculatorTool.Arguments(GeneratedContent(properties: ["expression": deep]))
        let result = try await tool.call(arguments: args)
        #expect(result.hasPrefix("error:"))
        #expect(result.contains("nesting"))
    }

    @Test("calculator rejects power operator")
    func calculatorRejectsPower() async throws {
        let tool = CalculatorTool()
        let args = try CalculatorTool.Arguments(GeneratedContent(properties: ["expression": "2 ** 10"]))
        let result = try await tool.call(arguments: args)
        #expect(result.hasPrefix("error:"))
        #expect(result.contains("**"))
    }

    @Test("calculator rejects unbalanced parentheses")
    func calculatorRejectsUnbalanced() async throws {
        let tool = CalculatorTool()
        let args = try CalculatorTool.Arguments(GeneratedContent(properties: ["expression": "(1 + 2"]))
        let result = try await tool.call(arguments: args)
        #expect(result.hasPrefix("error:"))
    }

    @Test("search tool renders results with source IDs")
    func searchToolRendersResults() async throws {
        let bm25 = BM25Retriever(chunks: [
            DocumentChunk(documentID: "doc-a", ordinal: 0, content: "the quick brown fox"),
            DocumentChunk(documentID: "doc-b", ordinal: 0, content: "unrelated text about cats"),
        ])
        let tool = SearchTool(retriever: bm25)
        let args = try SearchTool.Arguments(GeneratedContent(properties: ["query": "quick fox"]))
        let result = try await tool.call(arguments: args)
        #expect(result.contains("doc-a"))
        #expect(!result.contains("doc-b"))
    }

    @Test("search tool honors limit")
    func searchToolHonorsLimit() async throws {
        let bm25 = BM25Retriever(chunks: (0..<10).map {
            DocumentChunk(documentID: "doc-\($0)", ordinal: 0, content: "shared term \($0)")
        })
        let tool = SearchTool(retriever: bm25, defaultLimit: 5)
        let args = try SearchTool.Arguments(GeneratedContent(properties: ["query": "shared", "limit": 2]))
        let result = try await tool.call(arguments: args)
        let lineCount = result.split(separator: "\n").count
        #expect(lineCount == 2)
    }

    @Test("web fetch rejects non-HTTPS scheme")
    func webFetchRejectsHttp() async throws {
        let tool = WebFetchTool()
        let args = try WebFetchTool.Arguments(GeneratedContent(properties: ["url": "http://example.com"]))
        let result = try await tool.call(arguments: args)
        #expect(result.hasPrefix("error: scheme"))
    }

    @Test("web fetch rejects private network host")
    func webFetchRejectsPrivateHost() async throws {
        let tool = WebFetchTool()
        let args = try WebFetchTool.Arguments(GeneratedContent(properties: ["url": "https://192.168.1.1/"]))
        let result = try await tool.call(arguments: args)
        #expect(result.contains("private network"))
    }
}
