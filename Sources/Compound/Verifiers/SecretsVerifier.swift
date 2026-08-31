import Foundation

// Flags strings that look like API keys, tokens, private keys, or other
// secrets. The default rule set covers the providers that account for the
// large majority of credential leaks in the wild: cloud and SaaS APIs,
// VCS hosting, payment processors, and PEM-formatted private keys. Like
// PathDenyListVerifier this is a deny-list: when a default rule turns out
// to be too noisy in practice, swap it out by passing a custom rule set.
//
// All patterns use bounded `{n,m}` quantifiers so an attacker cannot pin
// the regex engine on a pathological input. Inputs above `inputSizeLimit`
// are rejected outright rather than scanned — the verifier's job is to
// flag credentials, not to scale linearly with megabytes of model output.

/// Flags strings that look like API keys, tokens, private keys, or
/// other secrets.
///
/// The default rule set covers providers responsible for the bulk of
/// real-world credential leaks: cloud and SaaS APIs, VCS hosting,
/// payment processors, and PEM-formatted private keys. All patterns
/// use bounded `{n,m}` quantifiers so an attacker cannot pin the regex
/// engine on a pathological input. Inputs larger than ``inputSizeLimit``
/// are rejected outright rather than scanned.
///
/// Marked `@unchecked Sendable` because ``SecretRule`` holds a
/// non-`Sendable` `Regex`; all stored fields are immutable.
public struct SecretsVerifier: Verifier, @unchecked Sendable {
    public typealias Input = String
    public let name: String
    public let cost: VerifierCost = .parse
    /// Active rule set.
    public let rules: [SecretRule]
    /// Verdict kind returned on match.
    public let returnAs: VerdictKind
    /// Maximum input size (bytes) the verifier will scan; larger inputs
    /// are rejected without scanning.
    public let inputSizeLimit: Int

    /// 1 MiB. Bigger than any realistic single LLM response, small
    /// enough that O(n) regex scans over the whole rule set stay well
    /// under a second on commodity hardware.
    public static let defaultInputSizeLimit: Int = 1 << 20

    /// Verdict kind returned when a rule matches.
    public enum VerdictKind: Sendable {
        /// Surface as `.repair` (the control loop will request a corrected output).
        case repair
        /// Surface as `.reject` (the run fails).
        case reject
    }

    /// One named secret-recognition pattern.
    ///
    /// Marked `@unchecked Sendable` because `Regex<AnyRegexOutput>` is
    /// not formally `Sendable`.
    public struct SecretRule: @unchecked Sendable {
        /// Short identifier used in diagnostics.
        public let id: String
        /// Human-readable description.
        public let description: String
        /// Compiled pattern.
        public let pattern: Regex<AnyRegexOutput>

        /// Compiles `pattern` and stores it.
        public init(id: String, description: String, pattern: String) throws {
            self.id = id
            self.description = description
            self.pattern = try Regex(pattern)
        }
    }

    /// Creates a verifier.
    public init(name: String = "secrets",
                rules: [SecretRule]? = nil,
                returnAs: VerdictKind = .reject,
                inputSizeLimit: Int = SecretsVerifier.defaultInputSizeLimit) {
        self.name = name
        self.rules = rules ?? Self.defaultRules
        self.returnAs = returnAs
        self.inputSizeLimit = inputSizeLimit
    }

    /// Default rule set covering common cloud, SaaS, and VCS provider tokens.
    public static let defaultRules: [SecretRule] = {
        // Each rule uses an explicit `{n,m}` upper bound so an attacker
        // can't drive the regex engine with arbitrarily long runs of
        // matching characters. The upper bounds reflect realistic
        // maximums for each provider's token format, plus headroom.
        let raw: [(String, String, String)] = [
            ("aws-access-key", "AWS access key ID", #"\bAKIA[0-9A-Z]{16}\b"#),
            ("aws-temp-key", "AWS session key", #"\bASIA[0-9A-Z]{16}\b"#),
            ("github-pat-classic", "GitHub personal access token (classic)", #"\bghp_[0-9A-Za-z]{36,255}\b"#),
            ("github-pat-fine", "GitHub fine-grained PAT", #"\bgithub_pat_[0-9A-Za-z_]{60,255}\b"#),
            ("github-oauth", "GitHub OAuth token", #"\bgho_[0-9A-Za-z]{36,255}\b"#),
            ("github-app", "GitHub app installation token", #"\bghs_[0-9A-Za-z]{36,255}\b"#),
            ("github-user", "GitHub user-to-server token", #"\bghu_[0-9A-Za-z]{36,255}\b"#),
            ("github-refresh", "GitHub refresh token", #"\bghr_[A-Za-z0-9_]{20,255}\b"#),
            ("slack-token", "Slack token", #"\bxox[abprs]-[0-9A-Za-z-]{10,255}"#),
            ("slack-webhook", "Slack incoming webhook URL", #"https://hooks\.slack\.com/services/T[A-Z0-9]{1,32}/B[A-Z0-9]{1,32}/[A-Za-z0-9]{8,64}"#),
            ("anthropic-api-key", "Anthropic API key", #"\bsk-ant-api03-[A-Za-z0-9_-]{20,200}"#),
            ("anthropic-admin-key", "Anthropic admin key", #"\bsk-ant-admin01-[A-Za-z0-9_-]{20,200}"#),
            ("openai-api-key", "OpenAI API key", #"\bsk-(?:proj-)?[A-Za-z0-9_-]{20,200}"#),
            ("openai-svc-acct", "OpenAI service-account key", #"\bsk-svcacct-[A-Za-z0-9_-]{20,200}"#),
            ("google-api-key", "Google API key", #"\bAIza[0-9A-Za-z_-]{35}\b"#),
            ("stripe-live-secret", "Stripe live secret key", #"\bsk_live_[0-9A-Za-z]{24,128}"#),
            ("stripe-restricted", "Stripe restricted key", #"\brk_live_[0-9A-Za-z]{24,128}"#),
            ("npm-token", "npm access token", #"\bnpm_[A-Za-z0-9]{36}\b"#),
            ("sendgrid-api-key", "SendGrid API key", #"\bSG\.[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{43}\b"#),
            ("twilio-api-key", "Twilio API key", #"\bSK[0-9a-fA-F]{32}\b"#),
            ("jwt-shaped", "JWT-shaped token", #"\beyJ[A-Za-z0-9_-]{8,4096}\.eyJ[A-Za-z0-9_-]{8,4096}\.[A-Za-z0-9_-]{8,4096}"#),
            ("pem-private-key", "PEM-encoded private key block", #"-----BEGIN [A-Z ]{1,64}PRIVATE KEY[A-Z ]{0,64}-----"#),
            ("putty-private-key", "PuTTY private key block", #"PuTTY-User-Key-File-[0-9]{1,3}:"#),
            ("ssh-private-key-openssh", "OpenSSH private key block", #"-----BEGIN OPENSSH PRIVATE KEY-----"#),
        ]
        // Compile every rule eagerly with `try` and trap on failure. A
        // pattern that fails to compile is a build-time defect, not an
        // input to silently tolerate: the previous `compactMap + try?`
        // would drop the broken rule and ship a verifier that quietly
        // stopped detecting that class of secret (fail-open). Crashing
        // here — or surfacing the throw — keeps the rule set intact.
        do {
            return try raw.map { try SecretRule(id: $0.0, description: $0.1, pattern: $0.2) }
        } catch {
            fatalError("SecretsVerifier.defaultRules contains an uncompilable pattern: \(error)")
        }
    }()

    public func verify(_ input: String, context _: RunContext) async throws -> Verdict {
        // Input-size guard: if the input exceeds the limit, refuse to
        // scan. Scanning megabytes of model output with a dozen regexes
        // is not a sensible thing to do under any threat model — even
        // bounded patterns can be coaxed into slow paths.
        if input.utf8.count > inputSizeLimit {
            return .reject("input too large to scan safely (\(input.utf8.count) bytes > \(inputSizeLimit))")
        }
        var matched: [String] = []
        for rule in rules {
            do {
                if try rule.pattern.firstMatch(in: input) != nil {
                    matched.append(rule.id)
                }
            } catch {
                // A regex engine error mid-scan is an internal fault, not
                // a clean "no match" — fail closed rather than passing
                // potentially secret-laden output through.
                return .reject(Diagnostic(
                    verifier: name,
                    message: "internal verifier error: secret rule '\(rule.id)' failed to evaluate: \(error)"
                ))
            }
        }
        if matched.isEmpty { return .pass }
        let summary = "output contains secret-like content: \(matched.joined(separator: ", "))"
        switch returnAs {
        case .repair:
            return .repair(Diagnostic(
                verifier: name,
                message: summary,
                suggestion: "redact or never emit credentials in model output"
            ))
        case .reject:
            return .reject(summary)
        }
    }
}
