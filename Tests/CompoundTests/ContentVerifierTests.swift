import Foundation
import Testing
@testable import Compound

@Suite("ContentVerifier")
struct ContentVerifierTests {
    @Test("prohibited rejects on substring")
    func prohibitedRejectsSubstring() async throws {
        let v = ProhibitedTermsVerifier(terms: ["confidential", "proprietary"])
        let verdict = try await v.verify("This is CONFIDENTIAL material", context: RunContext())
        #expect(verdict.isReject)
    }

    @Test("prohibited honors case-sensitive mode")
    func prohibitedCaseSensitive() async throws {
        let v = ProhibitedTermsVerifier(terms: ["Secret"], caseInsensitive: false)
        #expect((try await v.verify("not a secret", context: RunContext())).isPass)
        let verdict = try await v.verify("a Secret value", context: RunContext())
        #expect(verdict.isReject)
    }

    @Test("prohibited whole-word avoids substring match")
    func prohibitedWholeWord() async throws {
        let v = ProhibitedTermsVerifier(terms: ["cat"], wholeWord: true)
        #expect((try await v.verify("category management", context: RunContext())).isPass)
        let verdict = try await v.verify("the cat sat", context: RunContext())
        #expect(verdict.isReject)
    }

    @Test("required passes when all present")
    func requiredAllPresent() async throws {
        let v = RequiredTermsVerifier(terms: ["intro", "summary"])
        #expect((try await v.verify("intro... body... summary.", context: RunContext())).isPass)
    }

    @Test("required repairs when missing")
    func requiredRepairsMissing() async throws {
        let v = RequiredTermsVerifier(terms: ["intro", "summary"])
        let verdict = try await v.verify("intro only", context: RunContext())
        #expect(verdict.isRepair)
    }

    @Test("required allRequired=false accepts any-of-many")
    func requiredAnyOfMany() async throws {
        let v = RequiredTermsVerifier(terms: ["unit", "integration"], allRequired: false)
        #expect((try await v.verify("we ran unit tests", context: RunContext())).isPass)
        let verdict = try await v.verify("we did nothing", context: RunContext())
        #expect(verdict.isRepair)
    }

    @Test("implication passes when antecedent false")
    func implicationAntecedentFalse() async throws {
        struct Order: Sendable { let status: String; let closedAt: String? }
        let v = ImplicationVerifier<Order>(
            name: "closed-implies-closedAt",
            when: { $0.status == "closed" },
            then: { $0.closedAt != nil }
        )
        #expect((try await v.verify(Order(status: "open", closedAt: nil), context: RunContext())).isPass)
    }

    @Test("implication passes when both hold")
    func implicationBothHold() async throws {
        struct Order: Sendable { let status: String; let closedAt: String? }
        let v = ImplicationVerifier<Order>(
            name: "closed-implies-closedAt",
            when: { $0.status == "closed" },
            then: { $0.closedAt != nil }
        )
        #expect((try await v.verify(Order(status: "closed", closedAt: "now"), context: RunContext())).isPass)
    }

    @Test("implication repairs when antecedent holds but consequent fails")
    func implicationRepairsConsequent() async throws {
        struct Order: Sendable { let status: String; let closedAt: String? }
        let v = ImplicationVerifier<Order>(
            name: "closed-implies-closedAt",
            onViolation: "closed order missing closedAt",
            when: { $0.status == "closed" },
            then: { $0.closedAt != nil }
        )
        let verdict = try await v.verify(Order(status: "closed", closedAt: nil), context: RunContext())
        if case .repair(let d) = verdict {
            #expect(d.message.contains("closed order"))
        } else {
            Issue.record("expected .repair")
        }
    }

    @Test("unique-elements passes distinct list")
    func uniqueDistinct() async throws {
        let v = UniqueElementsVerifier<Int>()
        #expect((try await v.verify([1, 2, 3, 4], context: RunContext())).isPass)
    }

    @Test("unique-elements repairs duplicates")
    func uniqueRepairsDuplicates() async throws {
        let v = UniqueElementsVerifier<String>()
        let verdict = try await v.verify(["a", "b", "a"], context: RunContext())
        #expect(verdict.isRepair)
    }

    @Test("sha256 verifies match via closure digester")
    func sha256ClosureDigester() async throws {
        let digester: @Sendable (Data) -> Data = { data in
            let count = UInt8(truncatingIfNeeded: data.count)
            return Data(repeating: count, count: 32)
        }
        let v = SHA256HashVerifier(digester: digester)
        let payload = Data("hello".utf8)
        let expectedHex = String(repeating: "05", count: 32)
        let good = try await v.verify(.init(data: payload, expectedHex: expectedHex), context: RunContext())
        #expect(good.isPass)
        let bad = try await v.verify(.init(data: payload, expectedHex: String(repeating: "ff", count: 32)), context: RunContext())
        #expect(bad.isReject)
    }
}
