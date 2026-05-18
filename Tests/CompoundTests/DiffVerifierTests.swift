import Foundation
import Testing
@testable import Compound

@Suite("DiffVerifier")
struct DiffVerifierTests {
    let validDiff = """
    --- a/foo.swift
    +++ b/foo.swift
    @@ -1,3 +1,3 @@
     line1
    -line2
    +LINE2
     line3
    """

    @Test("unified-diff passes on a well-formed patch")
    func passesWellFormed() async throws {
        let v = UnifiedDiffParseVerifier()
        let verdict = try await v.verify(validDiff, context: RunContext())
        #expect(verdict.isPass)
    }

    @Test("unified-diff repairs when headers missing")
    func repairsMissingHeaders() async throws {
        let v = UnifiedDiffParseVerifier()
        let body = """
        @@ -1,1 +1,1 @@
        -a
        +b
        """
        let verdict = try await v.verify(body, context: RunContext())
        #expect(verdict.isRepair)
    }

    @Test("unified-diff repairs malformed hunk header")
    func repairsMalformedHunkHeader() async throws {
        let v = UnifiedDiffParseVerifier(requireFileHeaders: false)
        let body = """
        --- a/x
        +++ b/x
        @@ wat @@
        -a
        +b
        """
        let verdict = try await v.verify(body, context: RunContext())
        if case .repair(let d) = verdict {
            #expect(d.message.contains("malformed"))
        } else {
            Issue.record("expected .repair")
        }
    }

    @Test("unified-diff repairs when hunk counts disagree")
    func repairsHunkCountsDisagree() async throws {
        let v = UnifiedDiffParseVerifier()
        let body = """
        --- a/x
        +++ b/x
        @@ -1,5 +1,5 @@
        -a
        +b
        """
        let verdict = try await v.verify(body, context: RunContext())
        if case .repair(let d) = verdict {
            #expect(d.message.contains("disagree"))
        } else {
            Issue.record("expected .repair")
        }
    }

    @Test("unified-diff caps changed lines")
    func capsChangedLines() async throws {
        let v = UnifiedDiffParseVerifier(maxChangedLines: 2)
        let body = """
        --- a/x
        +++ b/x
        @@ -1,3 +1,3 @@
        -a
        -b
        -c
        +A
        +B
        +C
        """
        let verdict = try await v.verify(body, context: RunContext())
        if case .repair(let d) = verdict {
            #expect(d.message.contains("too large"))
        } else {
            Issue.record("expected .repair")
        }
    }

    @Test("unified-diff accepts No newline at end of file markers")
    func acceptsNoNewlineMarkers() async throws {
        let v = UnifiedDiffParseVerifier()
        let body = """
        --- a/x
        +++ b/x
        @@ -1,1 +1,1 @@
        -a
        \\ No newline at end of file
        +b
        \\ No newline at end of file
        """
        #expect((try await v.verify(body, context: RunContext())).isPass)
    }
}
