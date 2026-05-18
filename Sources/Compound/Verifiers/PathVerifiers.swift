import Foundation

// Verifiers for file paths. Every tool that takes a path is a potential
// escape route from the workspace and a potential exposure of sensitive
// files; these two verifiers gate that.

/// Verifies a path resolves inside `workspaceRoot` after symlink
/// resolution and path normalization. Rejects absolute paths that point
/// outside the root, relative paths that traverse outside via `..`,
/// and (optionally) symlinks that redirect outside.
///
/// Normalization order: percent-decode, NFC canonical decomposition,
/// then case-folded comparison. APFS volumes default to
/// case-insensitive, and macOS file APIs canonicalize to NFC, so
/// `..%2foutside`, NFD vs NFC homographs, and `.SSH/id_rsa` all
/// collapse to the same canonical form.
public struct PathSafetyVerifier: Verifier {
    public typealias Input = String
    public let name: String
    public let cost: VerifierCost = .parse
    /// Canonicalized workspace root.
    public let workspaceRoot: String
    /// When `true`, symlinks in the input are resolved before comparison.
    public let resolveSymlinks: Bool

    /// Creates a verifier scoped to `workspaceRoot`.
    public init(name: String = "path-safety", workspaceRoot: String, resolveSymlinks: Bool = true) {
        self.name = name
        let url = URL(fileURLWithPath: workspaceRoot).standardizedFileURL
        self.workspaceRoot = resolveSymlinks ? url.resolvingSymlinksInPath().path : url.path
        self.resolveSymlinks = resolveSymlinks
    }

    public func verify(_ input: String, context _: RunContext) async throws -> Verdict {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            return .reject("path is empty")
        }
        // Percent-decode so `..%2foutside` collapses to `../outside`. If
        // decoding fails (malformed escape), fall back to the raw input —
        // the rest of the pipeline will still reject obvious traversal.
        let decoded = raw.removingPercentEncoding ?? raw
        let base = URL(fileURLWithPath: workspaceRoot, isDirectory: true)
        let url: URL = decoded.hasPrefix("/")
            ? URL(fileURLWithPath: decoded)
            : URL(fileURLWithPath: decoded, relativeTo: base)
        let normalized = url.standardizedFileURL
        let resolved = resolveSymlinks ? normalized.resolvingSymlinksInPath().path : normalized.path

        let resolvedKey = Self.canonical(resolved)
        let rootKey = Self.canonical(workspaceRoot)
        let rootWithSlash = rootKey.hasSuffix("/") ? rootKey : rootKey + "/"
        if resolvedKey == rootKey || resolvedKey.hasPrefix(rootWithSlash) {
            return .pass
        }
        return .reject("path '\(input)' escapes workspace root '\(workspaceRoot)'")
    }

    // NFC-normalize then lowercase. APFS is case-insensitive by default, so
    // path comparisons must be too. NFC matches the on-disk canonical form
    // and collapses Unicode homographs.
    private static func canonical(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping.lowercased()
    }
}

/// Rejects paths matching any of a list of regex patterns. The
/// defaults cover the usual suspects: VCS metadata, dotfiles holding
/// credentials, SSH/cloud keys, kubeconfig and gcloud directories,
/// terraform state, package-manager auth files, and PEM/P12 bundles.
/// Patterns are anchored with `(^|/)` so they match the path component
/// regardless of directory depth.
///
/// Inputs are percent-decoded and NFC-normalized before matching so
/// usual obfuscations (URL encoding, NFD homographs, mixed case on
/// case-insensitive volumes) do not slip past.
///
/// Marked `@unchecked Sendable` because `Regex<AnyRegexOutput>` is not
/// formally `Sendable`; all stored fields are immutable.
public struct PathDenyListVerifier: Verifier, @unchecked Sendable {
    public typealias Input = String
    public let name: String
    public let cost: VerifierCost = .parse
    /// Compiled regex patterns.
    public let patterns: [Regex<AnyRegexOutput>]
    /// Source pattern strings (preserved for diagnostics).
    public let patternStrings: [String]

    /// Default deny patterns covering common credential / secret files.
    public static let defaultPatterns: [String] = [
        #"(^|/)\.git(/|$)"#,
        #"(^|/)\.env(\..*)?$"#,
        #"(^|/)id_rsa(\..*)?$"#,
        #"(^|/)id_ed25519(\..*)?$"#,
        #"(^|/)id_ecdsa(\..*)?$"#,
        #"(^|/)\.ssh(/|$)"#,
        #"(^|/)\.aws(/|$)"#,
        #"(^|/)\.kube(/|$)"#,
        #"(^|/)kubeconfig$"#,
        #"(^|/)\.docker/config\.json$"#,
        #"(^|/)\.config/gcloud(/|$)"#,
        #"(^|/)\.npmrc$"#,
        #"(^|/)\.pypirc$"#,
        #"(^|/)hosts\.yml$"#,
        #"(^|/)service-account[^/]*\.json$"#,
        #"\.tfstate(\.[^/]*)?$"#,
        #"(^|/)\.terraformrc$"#,
        #"(^|/)\.netrc$"#,
        #"(^|/)secrets?(/|$)"#,
        #"\.pem$"#,
        #"\.p12$"#,
        #"\.pfx$"#,
        #"\.keystore$"#,
    ]

    /// Compiles each pattern (case-insensitive).
    ///
    /// - Throws: Any error from `Regex.init(_:)` if a pattern is invalid.
    public init(name: String = "path-denylist", patterns: [String]? = nil) throws {
        let strings = patterns ?? Self.defaultPatterns
        self.name = name
        self.patternStrings = strings
        // Compile with case-insensitive matching so `.SSH/id_rsa` on an
        // APFS volume is treated the same as `.ssh/id_rsa`.
        self.patterns = try strings.map { try Regex($0).ignoresCase() }
    }

    public func verify(_ input: String, context _: RunContext) async throws -> Verdict {
        // Mirror PathSafetyVerifier's normalization so deny rules see the
        // same canonical form an attacker would have to bypass to reach
        // the filesystem.
        let decoded = input.removingPercentEncoding ?? input
        let normalized = decoded.precomposedStringWithCanonicalMapping
        for (i, pattern) in patterns.enumerated() {
            if (try? pattern.firstMatch(in: normalized)) != nil {
                return .reject("path '\(input)' matches deny pattern \(patternStrings[i])")
            }
        }
        return .pass
    }
}
