import Foundation
import NaturalLanguage
import Testing
@testable import Compound

@Suite("AppleIntegration")
struct AppleIntegrationTests {
    @Test("NSDataDetector PII catches phone")
    func nsDataDetectorPIICatchesPhone() async throws {
        let v = try NSDataDetectorPIIVerifier(categories: [.phoneNumber])
        let verdict = try await v.verify("call me at (415) 555-1212", context: RunContext())
        #expect(verdict.isRepair)
    }

    @Test("NSDataDetector PII passes clean text")
    func nsDataDetectorPIIPassesCleanText() async throws {
        let v = try NSDataDetectorPIIVerifier(categories: [.address, .phoneNumber])
        let verdict = try await v.verify("hello world", context: RunContext())
        #expect(verdict.isPass)
    }

    @Test("language verifier passes English")
    func languageVerifierPassesEnglish() async throws {
        let v = LanguageVerifier(allowed: [.english])
        let verdict = try await v.verify(
            "The quick brown fox jumps over the lazy dog. This is unambiguously English text.",
            context: RunContext()
        )
        #expect(verdict.isPass)
    }

    @Test("language verifier rejects clearly off-list language")
    func languageVerifierRejectsOffList() async throws {
        let v = LanguageVerifier(allowed: [.english])
        let verdict = try await v.verify(
            "今日はとても良い天気ですね。私は日本語で話しています。",
            context: RunContext()
        )
        #expect(verdict.isRepair)
    }

    @Test("language verifier passes very short text without judgement")
    func languageVerifierPassesShort() async throws {
        let v = LanguageVerifier(allowed: [.english], minimumLength: 100)
        let verdict = try await v.verify("ok", context: RunContext())
        #expect(verdict.isPass)
    }

    @Test("CryptoKit SHA-256 digester matches expected hex")
    func sha256MatchesExpected() async throws {
        let v = SHA256HashVerifier.cryptoKit()
        let data = Data("abc".utf8)
        let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let check = SHA256HashVerifier.HashCheck(data: data, expectedHex: expected)
        let verdict = try await v.verify(check, context: RunContext())
        #expect(verdict.isPass)
    }

    @Test("composite tracer fans out")
    func compositeTracerFansOut() async throws {
        let in1 = InMemoryTracer()
        let in2 = InMemoryTracer()
        let composite = CompositeTracer([in1, in2])
        await composite.record(.info(runID: UUID(), category: "test", message: "hi"))
        let e1 = await in1.snapshot()
        let e2 = await in2.snapshot()
        #expect(e1.count == 1)
        #expect(e2.count == 1)
    }
}
