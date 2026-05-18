import Foundation
import Testing
@testable import Compound

@Suite("SecretsVerifier")
struct SecretsVerifierTests {
    @Test("secrets detects AWS access key")
    func detectsAWS() async throws {
        let v = SecretsVerifier()
        let verdict = try await v.verify("the key is AKIAIOSFODNN7EXAMPLE here", context: RunContext())
        if case .reject(let r) = verdict {
            #expect(r.message.contains("aws-access-key"))
        } else {
            Issue.record("expected .reject")
        }
    }

    @Test("secrets detects GitHub PAT classic")
    func detectsGitHubPAT() async throws {
        let v = SecretsVerifier()
        #expect((try await v.verify("ghp_1234567890abcdefghijklmnopqrstuvwxyz", context: RunContext())).isReject)
    }

    @Test("secrets detects Anthropic API key")
    func detectsAnthropic() async throws {
        let v = SecretsVerifier()
        #expect((try await v.verify("export ANTHROPIC_API_KEY=sk-ant-api03-abcdef1234567890XYZWQRT", context: RunContext())).isReject)
    }

    @Test("secrets detects Anthropic admin key")
    func detectsAnthropicAdmin() async throws {
        let v = SecretsVerifier()
        let verdict = try await v.verify("ANTHROPIC_ADMIN_KEY=sk-ant-admin01-abcdefGHIJKLmnopqrSTUVWXYZ", context: RunContext())
        if case .reject(let r) = verdict {
            #expect(r.message.contains("anthropic-admin-key"))
        } else {
            Issue.record("expected .reject")
        }
    }

    @Test("secrets detects OpenAI service-account key")
    func detectsOpenAISvcAcct() async throws {
        let v = SecretsVerifier()
        let verdict = try await v.verify("OPENAI_KEY=sk-svcacct-abcdefGHIJKLmnopqrSTUVWXYZ", context: RunContext())
        if case .reject(let r) = verdict {
            #expect(r.message.contains("openai-svc-acct"))
        } else {
            Issue.record("expected .reject")
        }
    }

    @Test("secrets detects GitHub refresh token")
    func detectsGitHubRefresh() async throws {
        let v = SecretsVerifier()
        let verdict = try await v.verify("token ghr_abcdefGHIJKLmnopqrSTUV here", context: RunContext())
        if case .reject(let r) = verdict {
            #expect(r.message.contains("github-refresh"))
        } else {
            Issue.record("expected .reject")
        }
    }

    @Test("secrets detects JWT-shaped token")
    func detectsJWT() async throws {
        let v = SecretsVerifier()
        let token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        #expect((try await v.verify("token: \(token)", context: RunContext())).isReject)
    }

    @Test("secrets detects PEM private key block")
    func detectsPEM() async throws {
        let v = SecretsVerifier()
        let pem = "-----BEGIN RSA PRIVATE KEY-----\nMIIE...\n-----END RSA PRIVATE KEY-----"
        #expect((try await v.verify(pem, context: RunContext())).isReject)
    }

    @Test("secrets detects Slack webhook")
    func detectsSlack() async throws {
        let v = SecretsVerifier()
        let webhook = "https://hooks.slack.com/services/T00000000/B00000000/XXXXXXXXXXXXXXXXXXXXXXXX"
        #expect((try await v.verify(webhook, context: RunContext())).isReject)
    }

    @Test("secrets passes clean text")
    func passesClean() async throws {
        let v = SecretsVerifier()
        #expect((try await v.verify("hello world, nothing to see here", context: RunContext())).isPass)
    }

    @Test("secrets does not flag AKIA-like false positives")
    func doesNotFlagAKIAFalsePositives() async throws {
        let v = SecretsVerifier()
        #expect((try await v.verify("AKIAABCDEF", context: RunContext())).isPass)
        #expect((try await v.verify("AKIAabcdefghijklmnop", context: RunContext())).isPass)
        #expect((try await v.verify("XAKIAIOSFODNN7EXAMPLEY", context: RunContext())).isPass)
    }

    @Test("secrets does not flag arbitrary sk- prefixes")
    func doesNotFlagSKPrefixes() async throws {
        let v = SecretsVerifier()
        #expect((try await v.verify("sk-short", context: RunContext())).isPass)
    }

    @Test("secrets honors returnAs override")
    func honorsReturnAsOverride() async throws {
        let v = SecretsVerifier(returnAs: .repair)
        let verdict = try await v.verify("token AKIAIOSFODNN7EXAMPLE", context: RunContext())
        #expect(verdict.isRepair)
    }

    @Test("secrets rejects input that exceeds size limit")
    func rejectsOversized() async throws {
        let v = SecretsVerifier(inputSizeLimit: 1024)
        let payload = String(repeating: "x", count: 2048)
        let verdict = try await v.verify(payload, context: RunContext())
        if case .reject(let r) = verdict {
            #expect(r.message.contains("too large"))
        } else {
            Issue.record("expected .reject for oversized input")
        }
    }
}
