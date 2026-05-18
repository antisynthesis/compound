import Foundation
import Testing
@testable import Compound

@Suite("SQLVerifier")
struct SQLVerifierTests {
    @Test("tokenizer recognizes keywords and identifiers")
    func tokenizerKeywords() throws {
        let tokens = try SQLTokenizer.tokenize("SELECT id FROM users WHERE id = 1")
        #expect(tokens == [
            .keyword("select"), .identifier("id"),
            .keyword("from"), .identifier("users"),
            .keyword("where"), .identifier("id"),
            .op("="), .number("1"),
        ])
    }

    @Test("tokenizer keeps semicolons separate")
    func tokenizerSemicolons() throws {
        let tokens = try SQLTokenizer.tokenize("SELECT 1; SELECT 2")
        #expect(tokens.contains(.semicolon))
        #expect(SQLTokenizer.statements(tokens).count == 2)
    }

    @Test("tokenizer treats -- as line comment")
    func tokenizerLineComment() throws {
        let tokens = try SQLTokenizer.tokenize("SELECT 1 -- comment\nFROM t")
        #expect(tokens.contains(.keyword("select")))
        #expect(tokens.contains(.keyword("from")))
        #expect(!tokens.contains(.identifier("comment")))
    }

    @Test("tokenizer eats /* block comment */")
    func tokenizerBlockComment() throws {
        let tokens = try SQLTokenizer.tokenize("/* unused */ SELECT 1")
        #expect(tokens == [.keyword("select"), .number("1")])
    }

    @Test("tokenizer keeps quoted identifiers separate from strings")
    func tokenizerQuoted() throws {
        let tokens = try SQLTokenizer.tokenize(#"SELECT "id", 'name' FROM t"#)
        #expect(tokens.contains(.identifier("id")))
        #expect(tokens.contains(.string("name")))
    }

    @Test("tokenizer throws on unterminated string")
    func tokenizerUnterminated() {
        do {
            _ = try SQLTokenizer.tokenize("SELECT 'open")
            Issue.record("expected throw")
        } catch let e as SQLParseError {
            #expect(e == .unterminatedString)
        } catch {
            Issue.record("expected SQLParseError, got \(error)")
        }
    }

    @Test("safety passes a SELECT")
    func safetyPassesSelect() async throws {
        let v = SQLSafetyVerifier()
        #expect((try await v.verify("SELECT id FROM users LIMIT 10", context: RunContext())).isPass)
    }

    @Test("safety rejects DROP")
    func safetyRejectsDrop() async throws {
        let v = SQLSafetyVerifier()
        #expect((try await v.verify("DROP TABLE users", context: RunContext())).isReject)
    }

    @Test("safety rejects multi-statement by default")
    func safetyRejectsMultiStatement() async throws {
        let v = SQLSafetyVerifier()
        #expect((try await v.verify("SELECT 1; SELECT 2", context: RunContext())).isReject)
    }

    @Test("safety rejects UPDATE without WHERE")
    func safetyRejectsUpdateNoWhere() async throws {
        let v = SQLSafetyVerifier(allowedStatements: [.select, .update])
        let verdict = try await v.verify("UPDATE users SET banned = true", context: RunContext())
        if case .reject(let r) = verdict {
            #expect(r.message.contains("WHERE"))
        } else {
            Issue.record("expected .reject")
        }
    }

    @Test("safety accepts UPDATE with WHERE")
    func safetyAcceptsUpdateWhere() async throws {
        let v = SQLSafetyVerifier(allowedStatements: [.update])
        #expect((try await v.verify("UPDATE users SET banned = true WHERE id = 1", context: RunContext())).isPass)
    }

    @Test("safety rejects DELETE without WHERE")
    func safetyRejectsDeleteNoWhere() async throws {
        let v = SQLSafetyVerifier(allowedStatements: [.delete])
        #expect((try await v.verify("DELETE FROM users", context: RunContext())).isReject)
    }

    @Test("safety surfaces malformed SQL")
    func safetySurfacesMalformed() async throws {
        let v = SQLSafetyVerifier()
        let verdict = try await v.verify("SELECT 'unterminated", context: RunContext())
        if case .reject(let r) = verdict {
            #expect(r.message.contains("malformed"))
        } else {
            Issue.record("expected .reject")
        }
    }
}
