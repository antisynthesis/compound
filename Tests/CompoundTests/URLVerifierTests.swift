import Foundation
import FoundationModels
import Testing
@testable import Compound

@Suite("URLVerifier")
struct URLVerifierTests {
    @Test("url-safety passes a clean https URL")
    func passesCleanHttps() async throws {
        let v = URLSafetyVerifier()
        #expect((try await v.verify("https://example.com/path", context: RunContext())).isPass)
    }

    @Test("url-safety rejects http when https-only")
    func rejectsHttp() async throws {
        let v = URLSafetyVerifier()
        #expect((try await v.verify("http://example.com", context: RunContext())).isReject)
    }

    @Test("url-safety rejects localhost")
    func rejectsLocalhost() async throws {
        let v = URLSafetyVerifier()
        #expect((try await v.verify("https://localhost/admin", context: RunContext())).isReject)
    }

    @Test("url-safety rejects loopback IP")
    func rejectsLoopbackIP() async throws {
        let v = URLSafetyVerifier()
        #expect((try await v.verify("https://127.0.0.1/", context: RunContext())).isReject)
    }

    @Test("url-safety rejects private RFC1918 ranges")
    func rejectsRFC1918() async throws {
        let v = URLSafetyVerifier()
        for host in ["https://10.0.0.1/", "https://192.168.1.1/", "https://172.20.0.5/"] {
            let verdict = try await v.verify(host, context: RunContext())
            #expect(verdict.isReject, "expected .reject for \(host)")
        }
    }

    @Test("url-safety rejects link-local")
    func rejectsLinkLocal() async throws {
        let v = URLSafetyVerifier()
        #expect((try await v.verify("https://169.254.169.254/latest/meta-data", context: RunContext())).isReject)
    }

    @Test("url-safety enforces host allow-list")
    func enforcesAllowList() async throws {
        let v = URLSafetyVerifier(allowedHosts: ["api.example.com", ".trusted.example"])
        #expect((try await v.verify("https://api.example.com/v1", context: RunContext())).isPass)
        #expect((try await v.verify("https://foo.trusted.example/", context: RunContext())).isPass)
        #expect((try await v.verify("https://elsewhere.example/", context: RunContext())).isReject)
    }

    @Test("url-safety rejects garbage URL")
    func rejectsGarbage() async throws {
        let v = URLSafetyVerifier()
        #expect((try await v.verify("not a url", context: RunContext())).isReject)
    }

    @Test("url-safety rejects decimal-integer loopback (2130706433)")
    func rejectsDecimalInteger() async throws {
        let v = URLSafetyVerifier()
        #expect((try await v.verify("https://2130706433/", context: RunContext())).isReject)
    }

    @Test("url-safety rejects octal-encoded loopback (0177.0.0.1)")
    func rejectsOctal() async throws {
        let v = URLSafetyVerifier()
        #expect((try await v.verify("https://0177.0.0.1/", context: RunContext())).isReject)
    }

    @Test("url-safety rejects hex-encoded loopback (0x7f.0.0.1)")
    func rejectsHex() async throws {
        let v = URLSafetyVerifier()
        #expect((try await v.verify("https://0x7f.0.0.1/", context: RunContext())).isReject)
    }

    @Test("url-safety rejects IPv4-mapped IPv6 loopback")
    func rejectsV4MappedV6() async throws {
        let v = URLSafetyVerifier()
        #expect((try await v.verify("https://[::ffff:127.0.0.1]/", context: RunContext())).isReject)
    }

    @Test("url-safety rejects 0.0.0.0/8 range")
    func rejectsZeroSlashEight() async throws {
        let v = URLSafetyVerifier()
        for host in ["https://0.0.0.0/", "https://0.1.2.3/"] {
            let verdict = try await v.verify(host, context: RunContext())
            #expect(verdict.isReject, "expected .reject for \(host)")
        }
    }

    @Test("url-safety rejects 255.255.255.255 broadcast")
    func rejectsBroadcast() async throws {
        let v = URLSafetyVerifier()
        #expect((try await v.verify("https://255.255.255.255/", context: RunContext())).isReject)
    }

    @Test("url-safety rejects CGNAT 100.64.0.0/10")
    func rejectsCGNAT() async throws {
        let v = URLSafetyVerifier()
        for host in ["https://100.64.0.1/", "https://100.127.255.254/"] {
            let verdict = try await v.verify(host, context: RunContext())
            #expect(verdict.isReject, "expected .reject for \(host)")
        }
        #expect((try await URLSafetyVerifier().verify("https://100.63.0.1/", context: RunContext())).isPass)
        #expect((try await URLSafetyVerifier().verify("https://100.128.0.1/", context: RunContext())).isPass)
    }

    @Test("url-safety rejects IPv6 ULA fc00::/7 and link-local fe80::/10")
    func rejectsIPv6ULA() async throws {
        let v = URLSafetyVerifier()
        for host in ["https://[fc00::1]/", "https://[fd12:3456::1]/", "https://[fe80::1]/"] {
            let verdict = try await v.verify(host, context: RunContext())
            #expect(verdict.isReject, "expected .reject for \(host)")
        }
        let okVerdict = try await v.verify("https://[fbff::1]/", context: RunContext())
        #expect(!okVerdict.isReject, "fbff:: should not be ULA-flagged")
    }

    @Test("url-safety rejects 64:ff9b::/96, 100::/64, 2001::/32 ranges")
    func rejectsIPv6SpecialRanges() async throws {
        let v = URLSafetyVerifier()
        for host in ["https://[64:ff9b::1.2.3.4]/", "https://[100::1]/", "https://[2001::abcd]/"] {
            let verdict = try await v.verify(host, context: RunContext())
            #expect(verdict.isReject, "expected .reject for \(host)")
        }
    }

    @Test("url-safety strips trailing dot before allow-list match")
    func stripsTrailingDot() async throws {
        let v = URLSafetyVerifier(allowedHosts: ["api.example.com"])
        #expect((try await v.verify("https://api.example.com./v1", context: RunContext())).isPass)
    }

    @Test("url-safety rejects non-ASCII (IDN homograph) hosts")
    func rejectsIDN() async throws {
        let v = URLSafetyVerifier()
        #expect((try await v.verify("https://exаmple.com/", context: RunContext())).isReject)
    }

    @Test("url-safety treats integer-form IP as non-canonical even on allow-list")
    func integerIPNonCanonical() async throws {
        let v = URLSafetyVerifier(allowedHosts: ["2130706433"])
        #expect((try await v.verify("https://2130706433/", context: RunContext())).isReject)
    }

    @Test("web-fetch rejects hostnames that resolve to private IPs (DNS rebinding)")
    func rejectsDNSRebinding() async throws {
        let resolver = FakeHostResolver(map: ["totally-public.example": ["127.0.0.1"]])
        let tool = WebFetchTool(resolver: resolver)
        let args = try WebFetchTool.Arguments(
            GeneratedContent(properties: ["url": "https://totally-public.example/"])
        )
        let result = try await tool.call(arguments: args)
        #expect(result.contains("private address"), "expected DNS rebinding rejection, got: \(result)")
    }
}

struct FakeHostResolver: HostResolver {
    let map: [String: [String]]
    func resolve(_ host: String) async throws -> [String] {
        map[host] ?? []
    }
}
