import Foundation
import Testing
@testable import Compound

@Suite("PIIVerifier")
struct PIIVerifierTests {
    @Test("pii detects SSN")
    func detectsSSN() async throws {
        let v = PIIVerifier()
        #expect((try await v.verify("SSN: 123-45-6789", context: RunContext())).isRepair)
    }

    @Test("pii ignores dummy SSN ranges")
    func ignoresDummySSN() async throws {
        let v = PIIVerifier(categories: [.ssn])
        #expect((try await v.verify("000-12-3456", context: RunContext())).isPass)
        #expect((try await v.verify("666-12-3456", context: RunContext())).isPass)
    }

    @Test("pii detects valid credit card via Luhn")
    func detectsCreditCard() async throws {
        let v = PIIVerifier(categories: [.creditCard])
        #expect((try await v.verify("card 4111 1111 1111 1111 valid", context: RunContext())).isRepair)
    }

    @Test("pii ignores invalid Luhn 16-digit string")
    func ignoresInvalidLuhn() async throws {
        let v = PIIVerifier(categories: [.creditCard])
        #expect((try await v.verify("1234567890123456", context: RunContext())).isPass)
    }

    @Test("pii detects email")
    func detectsEmail() async throws {
        let v = PIIVerifier(categories: [.email])
        #expect((try await v.verify("contact ada@example.com", context: RunContext())).isRepair)
    }

    @Test("pii detects US phone")
    func detectsUSPhone() async throws {
        let v = PIIVerifier(categories: [.phoneUS])
        #expect((try await v.verify("call (415) 555-1212 today", context: RunContext())).isRepair)
    }

    @Test("pii detects IPv4")
    func detectsIPv4() async throws {
        let v = PIIVerifier(categories: [.ipv4])
        #expect((try await v.verify("server at 192.168.1.42 down", context: RunContext())).isRepair)
    }

    @Test("pii passes clean text")
    func passesClean() async throws {
        let v = PIIVerifier()
        #expect((try await v.verify("nothing personal here", context: RunContext())).isPass)
    }

    @Test("luhn helper agrees with known cards")
    func luhnHelper() {
        #expect(PIIVerifier.luhnValid("4111111111111111"))
        #expect(PIIVerifier.luhnValid("5500000000000004"))
        #expect(!PIIVerifier.luhnValid("4111111111111112"))
    }

    @Test("pii completes within 100ms on pathological input")
    func completesWithin100ms() async throws {
        let v = PIIVerifier()
        let pathological = String(repeating: "a", count: 5000)
            + "@"
            + String(repeating: "b.", count: 2500)
            + String(repeating: "c-", count: 2500)
            + ".x"
        let start = Date()
        _ = try await v.verify(pathological, context: RunContext())
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 0.1, "verify took \(elapsed)s, expected < 0.1s")
    }

    @Test("pii rejects input that exceeds size limit")
    func rejectsOversized() async throws {
        let v = PIIVerifier(inputSizeLimit: 1024)
        let payload = String(repeating: "x", count: 2048)
        let verdict = try await v.verify(payload, context: RunContext())
        if case .reject(let r) = verdict {
            #expect(r.message.contains("too large"))
        } else {
            Issue.record("expected .reject for oversized input")
        }
    }
}
