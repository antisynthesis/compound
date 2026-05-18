import Foundation
import Testing
@testable import Compound

@Suite("MarkdownVerifier")
struct MarkdownVerifierTests {
    @Test("markdown passes a clean document")
    func passesClean() async throws {
        let v = MarkdownStructureVerifier()
        let body = """
        # Title

        Some text with a [link](https://example.com).

        ```swift
        let x = 1
        ```
        """
        #expect((try await v.verify(body, context: RunContext())).isPass)
    }

    @Test("markdown repairs unterminated code fence")
    func repairsUnterminatedFence() async throws {
        let v = MarkdownStructureVerifier()
        let body = """
        ```swift
        let x = 1
        """
        let verdict = try await v.verify(body, context: RunContext())
        if case .repair(let d) = verdict {
            #expect(d.message.contains("fence"))
        } else {
            Issue.record("expected .repair")
        }
    }

    @Test("markdown repairs unclosed link bracket")
    func repairsUnclosedBracket() async throws {
        let v = MarkdownStructureVerifier()
        let body = "see [the docs(https://example.com)"
        #expect((try await v.verify(body, context: RunContext())).isRepair)
    }

    @Test("markdown repairs unclosed link target paren")
    func repairsUnclosedParen() async throws {
        let v = MarkdownStructureVerifier()
        let body = "see [the docs](https://example.com"
        #expect((try await v.verify(body, context: RunContext())).isRepair)
    }

    @Test("markdown ignores bracket characters inside code fences")
    func ignoresBracketsInFence() async throws {
        let v = MarkdownStructureVerifier()
        let body = """
        ```
        let xs = [1, 2, 3
        ```
        """
        #expect((try await v.verify(body, context: RunContext())).isPass)
    }

    @Test("markdown enforces max heading level")
    func enforcesMaxHeadingLevel() async throws {
        let v = MarkdownStructureVerifier(maxHeadingLevel: 2)
        let body = "# H1\n## H2\n### too deep"
        #expect((try await v.verify(body, context: RunContext())).isRepair)
    }
}
