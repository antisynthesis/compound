import Foundation
import Testing
@testable import Compound

@Suite("Redactor")
struct RedactorTests {
    @Test("email redactor masks an email")
    func emailMasks() throws {
        let r = try CommonRedactors.email()
        let out = r.redact("contact me at alice@example.com please")
        #expect(!out.contains("alice@example.com"))
        #expect(out.contains("⟨email⟩"))
    }

    @Test("composite chains redactors")
    func compositeChains() throws {
        let email = try CommonRedactors.email()
        let phone = try CommonRedactors.usPhone()
        let comp = CompositeRedactor([email, phone])
        let out = comp.redact("a@b.com and 555-123-4567")
        #expect(!out.contains("a@b.com"))
        #expect(!out.contains("555-123-4567"))
    }

    @Test("aws key redactor masks AKIA")
    func awsKeyMasks() throws {
        let r = try CommonRedactors.awsAccessKey()
        let out = r.redact("export key AKIAIOSFODNN7EXAMPLE")
        #expect(!out.contains("AKIAIOSFODNN7EXAMPLE"))
    }

    @Test("fromSecretsRules mirrors the SecretsVerifier rule set")
    func fromSecretsRulesMirrors() {
        let redactors = CommonRedactors.fromSecretsRules()
        #expect(redactors.count == SecretsVerifier.defaultRules.count)
        #expect(redactors.count >= 24)
        let names = Set(redactors.map(\.name))
        #expect(names.contains("secret-github-pat-classic"))
        #expect(names.contains("secret-anthropic-api-key"))
        #expect(names.contains("secret-pem-private-key"))
    }

    @Test("fromSecretsRules redactors scrub provider tokens")
    func fromSecretsRulesScrubs() {
        let comp = CompositeRedactor(CommonRedactors.fromSecretsRules().map { $0 as any Redactor })
        let samples = [
            "ghp_0123456789abcdefghijklmnopqrstuvwxyz",
            "AKIAIOSFODNN7EXAMPLE",
            "xoxb-123456789012-abcdefABCDEF",
            "-----BEGIN OPENSSH PRIVATE KEY-----",
        ]
        for s in samples {
            let out = comp.redact("value: \(s) end")
            #expect(!out.contains(s), "sample survived redaction: \(s)")
            #expect(out.contains("⟨secret⟩"))
        }
    }

    @Test("pattern redactor fails closed above its input size limit")
    func inputSizeLimitFailsClosed() throws {
        let r = try PatternRedactor(
            name: "email-small",
            pattern: #"[A-Za-z0-9._%+\-]{1,64}@example\.com"#,
            replacement: "⟨email⟩",
            inputSizeLimit: 32
        )
        let oversized = "a@example.com " + String(repeating: "x", count: 64)
        let out = r.redact(oversized)
        #expect(!out.contains("a@example.com"))
        #expect(out.contains("⟨redacted"))
        // Under the limit the pattern applies normally.
        #expect(r.redact("a@example.com") == "⟨email⟩")
    }

    @Test("bounded email pattern still matches ordinary addresses")
    func boundedEmailMatches() throws {
        let r = try CommonRedactors.email()
        #expect(r.redact("x alice.smith+tag@sub.example.co.uk y") == "x ⟨email⟩ y")
    }
}
