import Foundation
import Testing
@testable import Compound

@Suite("FormatVerifier")
struct FormatVerifierTests {
    @Test("uuid passes well-formed UUID")
    func uuidPasses() async throws {
        let v = UUIDVerifier()
        #expect((try await v.verify("550E8400-E29B-41D4-A716-446655440000", context: RunContext())).isPass)
    }

    @Test("uuid repairs garbage")
    func uuidRepairs() async throws {
        let v = UUIDVerifier()
        let verdict = try await v.verify("not-a-uuid", context: RunContext())
        #expect(verdict.isRepair)
    }

    @Test("iso8601 passes valid datetime")
    func iso8601Passes() async throws {
        let v = ISO8601DateVerifier()
        #expect((try await v.verify("2026-05-17T12:00:00Z", context: RunContext())).isPass)
    }

    @Test("iso8601 repairs malformed date")
    func iso8601Repairs() async throws {
        let v = ISO8601DateVerifier()
        let verdict = try await v.verify("yesterday", context: RunContext())
        #expect(verdict.isRepair)
    }

    @Test("semver accepts 1.0.0 and pre-release/build")
    func semverAccepts() async throws {
        let v = SemVerVerifier()
        #expect((try await v.verify("1.0.0", context: RunContext())).isPass)
        #expect((try await v.verify("2.0.0-rc.1", context: RunContext())).isPass)
        #expect((try await v.verify("1.4.0+build.123", context: RunContext())).isPass)
    }

    @Test("semver rejects 1.0 and v1.0.0")
    func semverRejects() async throws {
        let v = SemVerVerifier()
        for bad in ["1.0", "v1.0.0", "01.0.0"] {
            let verdict = try await v.verify(bad, context: RunContext())
            #expect(verdict.isRepair, "expected .repair for \(bad)")
        }
    }

    @Test("email accepts a standard address")
    func emailAccepts() async throws {
        let v = EmailVerifier()
        #expect((try await v.verify("ada@example.com", context: RunContext())).isPass)
    }

    @Test("email rejects malformed")
    func emailRejects() async throws {
        let v = EmailVerifier()
        let verdict = try await v.verify("not-an-email", context: RunContext())
        #expect(verdict.isRepair)
    }

    @Test("phone-e164 accepts +14155551212")
    func phoneE164Accepts() async throws {
        let v = PhoneE164Verifier()
        #expect((try await v.verify("+14155551212", context: RunContext())).isPass)
    }

    @Test("phone-e164 rejects non-E164 forms")
    func phoneE164Rejects() async throws {
        let v = PhoneE164Verifier()
        for bad in ["(415) 555-1212", "14155551212", "+0123"] {
            let verdict = try await v.verify(bad, context: RunContext())
            #expect(verdict.isRepair, "expected .repair for \(bad)")
        }
    }

    @Test("hex accepts 0x-prefixed and bare")
    func hexAccepts() async throws {
        let v = HexStringVerifier()
        #expect((try await v.verify("0xDEADBEEF", context: RunContext())).isPass)
        #expect((try await v.verify("deadbeef", context: RunContext())).isPass)
    }

    @Test("hex repairs odd-length")
    func hexRepairs() async throws {
        let v = HexStringVerifier()
        let verdict = try await v.verify("abc", context: RunContext())
        #expect(verdict.isRepair)
    }

    @Test("hex enforces byte length")
    func hexEnforcesByteLength() async throws {
        let v = HexStringVerifier(expectedByteLength: 32)
        let bad = try await v.verify("deadbeef", context: RunContext())
        #expect(bad.isRepair)
        let good = String(repeating: "ab", count: 32)
        #expect((try await v.verify(good, context: RunContext())).isPass)
    }

    @Test("base64 standard accepts padded value")
    func base64Accepts() async throws {
        let v = Base64Verifier()
        #expect((try await v.verify("SGVsbG8sIHdvcmxkIQ==", context: RunContext())).isPass)
    }

    @Test("base64 rejects out-of-alphabet character")
    func base64Rejects() async throws {
        let v = Base64Verifier()
        let verdict = try await v.verify("invalid$$", context: RunContext())
        #expect(verdict.isRepair)
    }

    @Test("base64 url-safe rejects +/")
    func base64URLSafeRejects() async throws {
        let v = Base64Verifier(urlSafe: true, allowPadding: false)
        let verdict = try await v.verify("SGVsbG8+", context: RunContext())
        #expect(verdict.isRepair)
    }
}
