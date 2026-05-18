import Foundation
import Testing
@testable import Compound

@Suite("EditVerifier")
struct EditVerifierTests {
    @Test("exact-match passes when oldString occurs once")
    func passesSingleOccurrence() async throws {
        let v = ExactMatchEditVerifier(reader: { _ in "alpha\nbeta\ngamma\n" })
        let edit = ProposedEdit(path: "x.swift", oldString: "beta", newString: "BETA")
        let verdict = try await v.verify(edit, context: RunContext())
        #expect(verdict.isPass)
    }

    @Test("exact-match repairs when oldString missing")
    func repairsMissing() async throws {
        let v = ExactMatchEditVerifier(reader: { _ in "alpha\nbeta\n" })
        let edit = ProposedEdit(path: "x.swift", oldString: "delta", newString: "DELTA")
        let verdict = try await v.verify(edit, context: RunContext())
        if case .repair(let d) = verdict {
            #expect(d.message.contains("not found"))
        } else {
            Issue.record("expected .repair, got \(verdict)")
        }
    }

    @Test("exact-match repairs when oldString occurs more than once")
    func repairsMultipleOccurrences() async throws {
        let v = ExactMatchEditVerifier(reader: { _ in "x\nx\nx\n" })
        let edit = ProposedEdit(path: "x.swift", oldString: "x", newString: "y")
        let verdict = try await v.verify(edit, context: RunContext())
        if case .repair(let d) = verdict {
            #expect(d.message.contains("3 places"))
        } else {
            Issue.record("expected .repair, got \(verdict)")
        }
    }

    @Test("exact-match flags no-op edit")
    func flagsNoOp() async throws {
        let v = ExactMatchEditVerifier(reader: { _ in "abc" })
        let edit = ProposedEdit(path: "x", oldString: "abc", newString: "abc")
        let verdict = try await v.verify(edit, context: RunContext())
        #expect(verdict.isRepair)
    }

    @Test("exact-match flags empty oldString")
    func flagsEmptyOldString() async throws {
        let v = ExactMatchEditVerifier(reader: { _ in "abc" })
        let edit = ProposedEdit(path: "x", oldString: "", newString: "y")
        let verdict = try await v.verify(edit, context: RunContext())
        #expect(verdict.isRepair)
    }

    @Test("exact-match rejects on reader error")
    func rejectsOnReaderError() async throws {
        struct ReaderError: Error {}
        let v = ExactMatchEditVerifier(reader: { _ in throw ReaderError() })
        let edit = ProposedEdit(path: "missing", oldString: "x", newString: "y")
        let verdict = try await v.verify(edit, context: RunContext())
        #expect(verdict.isReject)
    }

    @Test("edit-applied verifies post-state")
    func appliedVerifiesPostState() async throws {
        let v = EditAppliedVerifier(reader: { _ in "old text changed to new text" })
        let edit = ProposedEdit(path: "x", oldString: "missing", newString: "new text")
        let verdict = try await v.verify(edit, context: RunContext())
        #expect(verdict.isPass)
    }

    @Test("edit-applied repairs when oldString still present")
    func appliedRepairsStillPresent() async throws {
        let v = EditAppliedVerifier(reader: { _ in "the old still here" })
        let edit = ProposedEdit(path: "x", oldString: "old", newString: "new")
        let verdict = try await v.verify(edit, context: RunContext())
        #expect(verdict.isRepair)
    }

    @Test("no-op verifier catches identical strings")
    func noOpCatchesIdentical() async throws {
        let v = NoOpEditVerifier()
        let same = ProposedEdit(path: "x", oldString: "a", newString: "a")
        #expect((try await v.verify(same, context: RunContext())).isRepair)
        let diff = ProposedEdit(path: "x", oldString: "a", newString: "b")
        #expect((try await v.verify(diff, context: RunContext())).isPass)
    }
}
