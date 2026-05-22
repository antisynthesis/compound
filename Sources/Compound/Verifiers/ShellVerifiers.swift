import Foundation

// Verifiers for shell commands — the sharpest, most dangerous surface in any
// compound system, where a confident sentence becomes an irreversible act.
// Both verifiers operate on the tokenized command so they reason about words
// and operators rather than raw strings, which means quoting tricks like
// 'rm' "-rf" / don't slip past them.

/// Restricts the executable name (segment head) of a shell command to
/// a fixed allowlist. The allowlist is matched against both the literal
/// head and its basename, so `"git"` matches both `git status` and
/// `/usr/local/bin/git status`.
///
/// Shells and interpreters that take a string to run (`bash -c`,
/// `sh -c`, `python -c`, `node -e`, `xargs`, `env`, etc.) bypass any
/// head-only allowlist by hiding the real command in an argument.
/// Unless `allowShellEscapes` is set, those wrappers are rejected even
/// if they appear in the allow set.
public struct ShellAllowListVerifier: Verifier {
    public typealias Input = String
    public let name: String
    public let cost: VerifierCost = .parse
    /// Allowed executable names.
    public let allowed: Set<String>
    /// When `true`, shells and interpreters in ``inspectionEscapes`` are
    /// permitted as long as their name is in ``allowed``.
    public let allowShellEscapes: Bool

    /// Commands that take user-controlled code or strings to execute.
    /// Each of these would let an attacker smuggle an off-list command
    /// past a head check; rejected by default.
    public static let inspectionEscapes: Set<String> = [
        "bash", "sh", "zsh", "ksh", "dash", "fish",
        "python", "python2", "python3",
        "perl", "ruby", "node", "deno",
        "env", "xargs", "nohup", "setsid",
        "time", "nice", "ionice", "stdbuf",
        "script", "ssh", "watch", "timeout",
    ]

    /// Creates a verifier.
    public init(name: String = "shell-allowlist",
                allowed: Set<String>,
                allowShellEscapes: Bool = false) {
        self.name = name
        self.allowed = allowed
        self.allowShellEscapes = allowShellEscapes
    }

    public func verify(_ input: String, context _: RunContext) async throws -> Verdict {
        let tokens: [ShellToken]
        do {
            tokens = try ShellTokenizer.tokenize(input)
        } catch {
            return .reject("malformed shell command: \(error)")
        }
        let segments = ShellTokenizer.commands(tokens)
        if segments.isEmpty {
            return .reject("empty shell command")
        }
        for segment in segments {
            guard let head = ShellTokenizer.head(segment) else { continue }
            let basename = (head as NSString).lastPathComponent
            if !allowed.contains(head) && !allowed.contains(basename) {
                return .reject("command '\(head)' is not in the allowlist")
            }
            if !allowShellEscapes && Self.inspectionEscapes.contains(basename) {
                return .reject("command '\(basename)' can wrap arbitrary commands; set allowShellEscapes=true to permit")
            }
        }
        // find -exec / find ... -delete also smuggle arbitrary commands
        // past a head-only allowlist; flag them when escapes aren't
        // explicitly permitted.
        if !allowShellEscapes {
            for segment in segments {
                let words = ShellTokenizer.words(segment)
                guard let head = words.first else { continue }
                let basename = (head as NSString).lastPathComponent
                if basename == "find" && (words.contains("-exec") || words.contains("-execdir") || words.contains("-delete")) {
                    return .reject("find -exec/-delete can wrap arbitrary commands; set allowShellEscapes=true to permit")
                }
            }
        }
        return .pass
    }
}

/// Rejects shell commands matching any of a set of dangerous patterns.
/// Defaults cover the canonical footguns: `rm -rf /`, `sudo`,
/// `git --no-verify`, `git push --force`, `git reset --hard`, fork
/// bombs, `dd` to a raw device, `mkfs`, `curl | sh` pipelines, and
/// chmod 777. Rules are evaluated per-segment so a dangerous command
/// hidden behind `&&` is still caught.
public struct ShellDangerousFlagsVerifier: Verifier {
    public typealias Input = String
    public let name: String
    public let cost: VerifierCost = .parse
    /// Active danger rules.
    public let rules: [DangerRule]

    /// One named pattern evaluated against a tokenized segment.
    public struct DangerRule: Sendable {
        /// Short identifier used in the diagnostic.
        public let id: String
        /// Human-readable description.
        public let description: String
        /// Match predicate over a single command segment.
        public let match: @Sendable ([ShellToken]) -> Bool

        /// Creates a rule.
        public init(id: String, description: String, match: @escaping @Sendable ([ShellToken]) -> Bool) {
            self.id = id
            self.description = description
            self.match = match
        }
    }

    /// Creates a verifier. Defaults to ``defaultRules``.
    public init(name: String = "shell-danger", rules: [DangerRule]? = nil) {
        self.name = name
        self.rules = rules ?? Self.defaultRules
    }

    // Targets so broad that `rm -rf` against them is almost never the
    // user's intent. Includes filesystem roots, user data, and shell
    // home expansions. Matching is case-insensitive to keep parity with
    // case-insensitive filesystems.
    // Stored lowercased; lookups happen against `t.lowercased()`.
    static let broadRmTargets: Set<String> = [
        "/", "/*",
        "~", "~/", "$home", "${home}", "$pwd", "${pwd}",
        ".", "..",
        "/users", "/system", "/applications", "/library",
        "/opt", "/private", "/tmp", "/volumes", "/network",
        "/usr", "/usr/local", "/etc", "/var", "/bin", "/sbin", "/dev",
    ]

    /// Default rule set; covers the canonical shell footguns.
    public static let defaultRules: [DangerRule] = [
        DangerRule(id: "rm-rf-broad", description: "rm -rf on a broad target") { segment in
            let words = ShellTokenizer.words(segment)
            guard let head = ShellTokenizer.head(segment) else { return false }
            let lowerHead = head.lowercased()
            guard lowerHead == "rm" || lowerHead.hasSuffix("/rm") else { return false }
            // Recursive+force can be expressed as:
            //   short cluster:   -rf, -Rf, -fR, -fr
            //   long flags:      --recursive / --force (case-insensitive)
            //   split shorts:    -r -f
            let lowerWords = words.map { $0.lowercased() }
            let hasRecursiveForce: Bool = {
                let clusterHit = lowerWords.contains { w in
                    guard w.hasPrefix("-"), !w.hasPrefix("--") else { return false }
                    return w.contains("r") && w.contains("f")
                }
                if clusterHit { return true }
                let hasLongRecursive = lowerWords.contains("--recursive")
                let hasLongForce = lowerWords.contains("--force")
                let hasShortRecursive = lowerWords.contains("-r") || lowerWords.contains("-r-") || lowerWords.contains("--recursive")
                let hasShortForce = lowerWords.contains("-f")
                if hasLongRecursive && hasLongForce { return true }
                if hasShortRecursive && hasLongForce { return true }
                if hasLongRecursive && hasShortForce { return true }
                if hasShortRecursive && hasShortForce { return true }
                return false
            }()
            guard hasRecursiveForce else { return false }
            // Non-flag positional arguments are the targets. A single-segment
            // absolute path like `/var` or `/etc` is broad enough to flag on
            // its own — see findings H4.
            let targets = words.dropFirst().filter { !$0.hasPrefix("-") }
            for t in targets {
                let lower = t.lowercased()
                if Self.broadRmTargets.contains(lower) { return true }
                if lower.hasPrefix("~/") { return true }
                if lower.hasPrefix("/*") { return true }
                // Single-segment absolute path: /word with no further slash
                // (e.g. /opt, /tmp, /srv, anything top-level).
                if lower.hasPrefix("/") {
                    let trimmed = lower.hasSuffix("/") ? String(lower.dropLast()) : lower
                    let inner = trimmed.dropFirst()
                    if !inner.isEmpty && !inner.contains("/") {
                        return true
                    }
                }
            }
            return false
        },
        DangerRule(id: "sudo", description: "sudo or doas escalation") { segment in
            ShellTokenizer.words(segment).contains { $0 == "sudo" || $0 == "doas" }
        },
        DangerRule(id: "git-no-verify", description: "git commit/push with --no-verify (skips hooks)") { segment in
            let words = ShellTokenizer.words(segment)
            guard let head = ShellTokenizer.head(segment), head == "git" || head.hasSuffix("/git") else { return false }
            return words.contains("--no-verify")
        },
        DangerRule(id: "git-force-push", description: "git push --force / -f") { segment in
            let words = ShellTokenizer.words(segment)
            guard let head = ShellTokenizer.head(segment), head == "git" || head.hasSuffix("/git") else { return false }
            guard words.contains("push") else { return false }
            return words.contains("--force") || words.contains("-f")
        },
        DangerRule(id: "git-reset-hard", description: "git reset --hard") { segment in
            let words = ShellTokenizer.words(segment)
            guard let head = ShellTokenizer.head(segment), head == "git" || head.hasSuffix("/git") else { return false }
            return words.contains("reset") && words.contains("--hard")
        },
        DangerRule(id: "fork-bomb", description: "fork bomb (:(){:|:&};:)") { segment in
            let joined = ShellTokenizer.words(segment).joined()
            return joined.contains(":(){:|:&};:")
        },
        DangerRule(id: "dd-of-device", description: "dd writing to /dev/disk*, /dev/sd*, /dev/rdisk*") { segment in
            guard let head = ShellTokenizer.head(segment), head == "dd" || head.hasSuffix("/dd") else { return false }
            return ShellTokenizer.words(segment).contains { word in
                word.hasPrefix("of=/dev/disk") || word.hasPrefix("of=/dev/sd") || word.hasPrefix("of=/dev/rdisk") || word.hasPrefix("of=/dev/nvme")
            }
        },
        DangerRule(id: "mkfs", description: "filesystem creation (mkfs.*)") { segment in
            ShellTokenizer.words(segment).contains { $0.hasPrefix("mkfs") }
        },
        DangerRule(id: "chmod-777", description: "chmod 777 (world-writable)") { segment in
            let words = ShellTokenizer.words(segment)
            guard let head = ShellTokenizer.head(segment), head == "chmod" || head.hasSuffix("/chmod") else { return false }
            return words.contains("777") || words.contains("-R") && words.contains("a+rwx")
        },
        DangerRule(id: "find-delete-broad", description: "find ... -delete on a broad target") { segment in
            let words = ShellTokenizer.words(segment)
            guard let head = ShellTokenizer.head(segment), head == "find" || head.hasSuffix("/find") else { return false }
            guard words.contains("-delete") else { return false }
            // Inspect the search root (the first non-flag argument after `find`).
            for word in words.dropFirst() {
                if word.hasPrefix("-") { break }
                let lower = word.lowercased()
                if Self.broadRmTargets.contains(lower) { return true }
                if lower.hasPrefix("/") {
                    let trimmed = lower.hasSuffix("/") ? String(lower.dropLast()) : lower
                    let inner = trimmed.dropFirst()
                    if !inner.isEmpty && !inner.contains("/") { return true }
                }
            }
            return false
        },
    ]

    public func verify(_ input: String, context _: RunContext) async throws -> Verdict {
        let tokens: [ShellToken]
        do {
            tokens = try ShellTokenizer.tokenize(input)
        } catch {
            return .reject("malformed shell command: \(error)")
        }

        // Pipeline-level check: `curl ... | sh` / `wget ... | bash`.
        if let pipelineDanger = Self.detectFetchPipeShell(tokens) {
            return .reject(pipelineDanger)
        }

        // Redirection to system paths: `... > /etc/passwd`.
        if let redirDanger = Self.detectDangerousRedirection(tokens) {
            return .reject(redirDanger)
        }

        let segments = ShellTokenizer.commands(tokens)
        for segment in segments {
            // Inspection-escape recursion: if the head is a shell or
            // interpreter taking a code argument (`bash -c "rm -rf /"`,
            // `xargs rm -rf /`), re-tokenize that argument and re-run the
            // danger rules on it. Without this, head-only matching misses
            // every wrapped command in H3.
            if let inner = Self.unwrappedInnerCommand(segment) {
                let innerVerdict = try await self.verify(inner, context: RunContext())
                if case .reject = innerVerdict { return innerVerdict }
            }
            for rule in rules {
                if rule.match(segment) {
                    return .reject("dangerous pattern '\(rule.id)': \(rule.description)")
                }
            }
        }
        return .pass
    }

    // Returns the inner command string for inspection escapes that take
    // code as an argument. Examples: `bash -c "rm -rf /"` -> "rm -rf /",
    // `xargs rm -rf /` -> "rm -rf /", `find / -exec rm -rf {} +` ->
    // "rm -rf {}". Returns nil when the segment isn't a wrapper or the
    // wrapped command can't be recovered.
    private static func unwrappedInnerCommand(_ segment: [ShellToken]) -> String? {
        let words = ShellTokenizer.words(segment)
        guard let head = words.first else { return nil }
        let basename = (head as NSString).lastPathComponent.lowercased()
        switch basename {
        case "bash", "sh", "zsh", "ksh", "dash", "fish":
            // `bash -c "<cmd>"`. Pick the argument right after -c.
            if let idx = words.firstIndex(of: "-c"), idx + 1 < words.count {
                return words[idx + 1]
            }
            return nil
        case "python", "python2", "python3", "perl", "ruby":
            // `python -c "<code>"` / `perl -e "<code>"`. We can't actually
            // tokenize Python, but a literal `os.system("rm -rf /")` will
            // still be visible as a substring. Forward the argument
            // verbatim so any embedded shell metacharacters surface.
            if let idx = words.firstIndex(where: { $0 == "-c" || $0 == "-e" }), idx + 1 < words.count {
                return words[idx + 1]
            }
            return nil
        case "node", "deno":
            if let idx = words.firstIndex(of: "-e"), idx + 1 < words.count {
                return words[idx + 1]
            }
            return nil
        case "env", "nohup", "setsid", "time", "nice", "ionice", "stdbuf", "timeout":
            // Skip env-var assignments and option flags, then re-emit the
            // remaining words as the inner command.
            var rest: [String] = []
            var sawCommand = false
            for w in words.dropFirst() {
                if !sawCommand {
                    if w.hasPrefix("-") { continue }
                    if w.contains("=") && !w.hasPrefix("=") { continue }
                    sawCommand = true
                }
                rest.append(w)
            }
            return rest.isEmpty ? nil : rest.joined(separator: " ")
        case "xargs":
            // `xargs <cmd> <args>` — everything after the command name.
            var rest: [String] = []
            var sawCommand = false
            for w in words.dropFirst() {
                if !sawCommand {
                    if w.hasPrefix("-") { continue }
                    sawCommand = true
                }
                rest.append(w)
            }
            return rest.isEmpty ? nil : rest.joined(separator: " ")
        case "find":
            // `find <path...> -exec <cmd> ... ;` / `... -execdir <cmd>`.
            if let idx = words.firstIndex(where: { $0 == "-exec" || $0 == "-execdir" }) {
                var rest: [String] = []
                for w in words.dropFirst(idx + 1) {
                    if w == ";" || w == "+" || w == "\\;" { break }
                    rest.append(w)
                }
                return rest.isEmpty ? nil : rest.joined(separator: " ")
            }
            return nil
        case "ssh":
            // `ssh host <cmd...>`. First non-flag argument is the host;
            // the rest is the remote command.
            var sawHost = false
            var rest: [String] = []
            for w in words.dropFirst() {
                if w.hasPrefix("-") { continue }
                if !sawHost { sawHost = true; continue }
                rest.append(w)
            }
            return rest.isEmpty ? nil : rest.joined(separator: " ")
        default:
            return nil
        }
    }

    private static func detectFetchPipeShell(_ tokens: [ShellToken]) -> String? {
        let fetchers: Set<String> = ["curl", "wget", "fetch"]
        let shells: Set<String> = ["sh", "bash", "zsh", "ksh", "dash"]
        var sawFetcher = false
        var expectShell = false
        for token in tokens {
            switch token {
            case .word(let w):
                let base = (w as NSString).lastPathComponent
                if fetchers.contains(base) { sawFetcher = true }
                if expectShell && shells.contains(base) {
                    return "piping fetched content directly to a shell"
                }
                expectShell = false
            case .op(let op):
                if op == "|" && sawFetcher {
                    expectShell = true
                }
            }
        }
        return nil
    }

    private static func detectDangerousRedirection(_ tokens: [ShellToken]) -> String? {
        let systemPrefixes = ["/etc/", "/usr/", "/var/", "/bin/", "/sbin/", "/dev/disk", "/dev/sd", "/dev/rdisk", "/dev/nvme"]
        var expectTarget = false
        for token in tokens {
            switch token {
            case .op(let op):
                expectTarget = op == ">" || op == ">>"
            case .word(let w):
                if expectTarget {
                    for prefix in systemPrefixes where w.hasPrefix(prefix) {
                        return "redirection to system path '\(w)'"
                    }
                    expectTarget = false
                }
            }
        }
        return nil
    }
}
