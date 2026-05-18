import Foundation
import Testing
@testable import Compound

@Suite("Assembler")
struct AssemblerTests {
    @Test("assembler applies redactors")
    func appliesRedactors() async throws {
        let emailR = try CommonRedactors.email()
        let assembler = DefaultContextAssembler(
            baseInstructions: "be helpful",
            retriever: EmptyRetriever(),
            redactors: [emailR]
        )
        let result = try await assembler.assemble(
            userPrompt: "my email is alice@example.com",
            runContext: RunContext()
        )
        #expect(!result.userPrompt.contains("alice@example.com"))
        #expect(result.redactionsApplied.contains("email"))
    }

    @Test("assembler attaches retrieved sources")
    func attachesRetrievedSources() async throws {
        let retriever = StaticRetriever([
            RetrievedSource(id: "doc-1", title: "T1", content: "C1"),
            RetrievedSource(id: "doc-2", title: "T2", content: "C2"),
        ])
        let assembler = DefaultContextAssembler(
            baseInstructions: "x",
            retriever: retriever,
            retrievalLimit: 1
        )
        let result = try await assembler.assemble(userPrompt: "q", runContext: RunContext())
        #expect(result.sources.count == 1)
        #expect(result.sources.first?.id == "doc-1")
    }

    @Test("rendered prompt embeds source ids")
    func renderedPromptEmbedsSourceIDs() async throws {
        let assembler = DefaultContextAssembler(
            baseInstructions: "x",
            retriever: StaticRetriever([
                RetrievedSource(id: "abc", title: "T", content: "C")
            ])
        )
        let r = try await assembler.assemble(userPrompt: "what?", runContext: RunContext())
        #expect(r.renderedPrompt().contains("[abc]"))
        #expect(r.renderedPrompt().contains("what?"))
    }

    @Test("assembler enforces prompt policy")
    func enforcesPromptPolicy() async throws {
        struct DenyAll: Policy {
            let name = "deny-all"
            func evaluate(_: PolicySubject, auth _: AuthContext) async -> PolicyDecision {
                .deny(reason: "blocked")
            }
        }
        let assembler = DefaultContextAssembler(
            baseInstructions: "x",
            policy: DenyAll()
        )
        await #expect(throws: CompoundError.self) {
            _ = try await assembler.assemble(userPrompt: "anything", runContext: RunContext())
        }
    }
}
