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
}
