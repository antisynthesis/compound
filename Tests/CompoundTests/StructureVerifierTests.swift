import Foundation
import Testing
@testable import Compound

@Suite("StructureVerifier")
struct StructureVerifierTests {
    @Test("encoding rejects NUL bytes")
    func encodingRejectsNul() async throws {
        let v = EncodingVerifier()
        #expect((try await v.verify("hello\0world", context: RunContext())).isRepair)
    }

    @Test("encoding rejects U+FFFD by default")
    func encodingRejectsFFFD() async throws {
        let v = EncodingVerifier()
        #expect((try await v.verify("oops \u{FFFD}", context: RunContext())).isRepair)
    }

    @Test("encoding optionally rejects CRLF")
    func encodingRejectsCRLF() async throws {
        let v = EncodingVerifier(forbidCRLF: true)
        #expect((try await v.verify("a\r\nb", context: RunContext())).isRepair)
    }

    @Test("encoding passes clean text")
    func encodingPassesClean() async throws {
        let v = EncodingVerifier()
        #expect((try await v.verify("hello world\n", context: RunContext())).isPass)
    }

    @Test("balanced brackets passes on well-formed code")
    func balancedPasses() async throws {
        let v = BalancedBracketsVerifier()
        #expect((try await v.verify("func f(x: Int) -> [String: Any] { return [:] }", context: RunContext())).isPass)
    }

    @Test("balanced brackets repairs unclosed brace")
    func balancedRepairsUnclosed() async throws {
        let v = BalancedBracketsVerifier()
        let verdict = try await v.verify("func f() { let x = 1", context: RunContext())
        if case .repair(let d) = verdict {
            #expect(d.message.contains("unclosed"))
        } else {
            Issue.record("expected .repair")
        }
    }

    @Test("balanced brackets ignores content inside strings")
    func balancedIgnoresStrings() async throws {
        let v = BalancedBracketsVerifier()
        #expect((try await v.verify(#"let s = "} ] )""#, context: RunContext())).isPass)
    }

    @Test("balanced brackets ignores content inside line comments")
    func balancedIgnoresLineComments() async throws {
        let v = BalancedBracketsVerifier()
        #expect((try await v.verify("let x = 1 // ignore } ] )\n", context: RunContext())).isPass)
    }

    @Test("balanced brackets ignores content inside block comments")
    func balancedIgnoresBlockComments() async throws {
        let v = BalancedBracketsVerifier()
        #expect((try await v.verify("let x = /* ) ] } */ 1", context: RunContext())).isPass)
    }

    @Test("balanced brackets flags unterminated string")
    func balancedFlagsUnterminated() async throws {
        let v = BalancedBracketsVerifier()
        #expect((try await v.verify(#"let s = "open"#, context: RunContext())).isRepair)
    }

    @Test("balanced brackets flags mismatched closer")
    func balancedFlagsMismatched() async throws {
        let v = BalancedBracketsVerifier()
        #expect((try await v.verify("func f(x: Int]", context: RunContext())).isRepair)
    }

    @Test("line-count enforces lower bound")
    func lineCountLower() async throws {
        let v = LineCountVerifier(min: 3)
        #expect((try await v.verify("only one", context: RunContext())).isRepair)
    }

    @Test("line-count enforces upper bound")
    func lineCountUpper() async throws {
        let v = LineCountVerifier(max: 2)
        #expect((try await v.verify("a\nb\nc\nd", context: RunContext())).isRepair)
    }
}
