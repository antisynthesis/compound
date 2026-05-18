import Foundation
import Testing
@testable import Compound

@Suite("Conversation")
struct ConversationTests {
    @Test("in-memory store appends and lists")
    func inMemoryAppendsLists() async throws {
        let store = InMemoryConversationStore()
        await store.append(.user("hi"))
        await store.append(.assistant("hello"))
        let messages = await store.messages()
        #expect(messages.count == 2)
        #expect(messages[0].role == .user)
        #expect(messages[1].role == .assistant)
    }

    @Test("in-memory store respects cap")
    func inMemoryRespectsCap() async throws {
        let store = InMemoryConversationStore(cap: 3)
        for i in 0..<5 {
            await store.append(.user("\(i)"))
        }
        let messages = await store.messages()
        #expect(messages.count == 3)
        #expect(messages.last?.content == "4")
    }

    @Test("jsonl store round-trips")
    func jsonlRoundTrips() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("compound-conv-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = JSONLConversationStore(fileURL: url)
        try await store.append(.user("first"))
        try await store.append(.assistant("second"))
        let messages = try await store.messages()
        #expect(messages.count == 2)
        #expect(messages[0].content == "first")
        #expect(messages[1].role == .assistant)
    }

    @Test("truncating summarizer omits older turns")
    func truncatingSummarizer() async throws {
        let summarizer = TruncatingSummarizer()
        let dropped = (1...3).map { ConversationMessage.user("\($0)") }
        let summary = try await summarizer.summarize(dropped)
        #expect(summary.contains("3"))
        let none = try await summarizer.summarize([])
        #expect(none.isEmpty)
    }

    @Test("conversation assembler adds transcript to prompt")
    func conversationAssembler() async throws {
        let store = InMemoryConversationStore()
        await store.append(.user("what's 2+2"))
        await store.append(.assistant("4"))
        let assembler = ConversationContextAssembler(
            baseInstructions: "be terse",
            store: store
        )
        let context = try await assembler.assemble(
            userPrompt: "and 3+3?",
            runContext: RunContext()
        )
        #expect(context.userPrompt.contains("what's 2+2"))
        #expect(context.userPrompt.contains("New user message: and 3+3?"))
    }
}
