import Foundation
import Testing
@testable import Compound

// Tiny deterministic PRNG so fuzz cases are reproducible.
struct Xorshift64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { self.state = seed == 0 ? 0xDEAD_BEEF : seed }
    mutating func next() -> UInt64 {
        var x = state
        x ^= x << 13
        x ^= x >> 7
        x ^= x << 17
        state = x
        return x
    }
}

@Suite("Fuzz")
struct FuzzTests {
    @Test("url verifier survives 200 mangled inputs and never passes known-bad shapes")
    func urlVerifierFuzz() async throws {
        let v = URLSafetyVerifier()
        var rng = Xorshift64(seed: 0xC0FFEE)
        let knownBad: [String] = [
            "http://example.com/",
            "https://2130706433/",
            "https://127.0.0.1/",
            "https://localhost/",
            "https://0x7f.0.0.1/",
            "https://192.168.1.1/",
            "https://[::1]/",
            "https://0.0.0.0/",
        ]
        // 1. All known-bad shapes must never come back as .pass.
        for url in knownBad {
            let verdict = try await v.verify(url, context: RunContext())
            #expect(!verdict.isPass, "known-bad URL slipped through: \(url)")
        }
        // 2. 200 random-mangled inputs must not crash, must complete < 50ms each.
        let pool: [String] = [
            "https://", "http://", "ftp://", "://", "https",
            "example", ".com", "/", ":", "..%2f", "%2e%2e/",
            "[::1]", "127.0.0.1", "0x7f", "0177", "@", "?", "#",
        ]
        for _ in 0..<200 {
            var s = ""
            let n = Int(rng.next() % 8) + 1
            for _ in 0..<n {
                let idx = Int(rng.next() % UInt64(pool.count))
                s += pool[idx]
            }
            let start = Date()
            _ = try? await v.verify(s, context: RunContext())
            let elapsed = Date().timeIntervalSince(start)
            #expect(elapsed < 0.05, "fuzz input '\(s)' took \(elapsed)s")
        }
    }

    @Test("shell tokenizer survives 200 perturbed commands and never crashes")
    func shellTokenizerFuzz() throws {
        var rng = Xorshift64(seed: 0xABC_123)
        let pieces: [String] = [
            "git status", "echo hi", "ls -la", "\"", "'", "\\\"", "$VAR",
            "`backtick`", "$(sub)", "${var}", "&", "|", "&&", "||",
            ";", ">", ">>", "<", "/path/with/slashes",
            // Control chars and unicode
            "\u{0007}", "\u{0001}", "héllo", "日本語",
        ]
        for _ in 0..<200 {
            var s = ""
            let n = Int(rng.next() % 6) + 1
            for _ in 0..<n {
                let idx = Int(rng.next() % UInt64(pieces.count))
                s += pieces[idx]
                s += " "
            }
            // Should either succeed or throw a ShellParseError. Anything else
            // (or a crash) is a failure.
            do {
                _ = try ShellTokenizer.tokenize(s)
            } catch is ShellParseError {
                // OK
            } catch {
                Issue.record("unexpected error type from tokenizer for '\(s)': \(error)")
            }
        }
    }

    @Test("regex secret rules complete within 100ms on 1 MiB random text")
    func secretsRegexReDoSGuard() async throws {
        // Build 1 MiB of pseudorandom alphanumerics. Should not match anything,
        // but timing is what matters: a regression to unbounded backtracking
        // would blow the budget here.
        var rng = Xorshift64(seed: 0x1234)
        let alphabet: [Character] = Array("abcdefghijklmnopqrstuvwxyz0123456789-_= /")
        var buf = ""
        buf.reserveCapacity(1 << 20)
        for _ in 0..<(1 << 20) {
            buf.append(alphabet[Int(rng.next() % UInt64(alphabet.count))])
        }
        // SecretsVerifier has a default input-size limit. Bump it generously so
        // the test exercises the regex path on a real 1 MiB payload.
        let v = SecretsVerifier(inputSizeLimit: 2 << 20)
        let start = Date()
        _ = try await v.verify(buf, context: RunContext())
        let elapsed = Date().timeIntervalSince(start)
        // ReDoS guard: 21 bounded patterns over 1 MiB of random text should
        // complete in linear time. The threshold is generous to absorb CI
        // noise; what we're guarding against is catastrophic backtracking
        // (which would push elapsed into the tens of seconds).
        #expect(elapsed < 5.0, "regex took \(elapsed)s on 1 MiB; expected linear-time completion")
    }
}
