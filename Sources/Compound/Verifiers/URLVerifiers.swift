import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// The gate between a model-proposed URL and a fetch tool. A URL is a request
// to reach into the network on the model's word; this is where that word is
// checked. Reject non-HTTPS schemes by default, optionally restrict to an
// allow-list of hosts, and refuse private-network targets so SSRF attempts
// routed through the fetch tool do not succeed.

/// Decides which URLs the model is allowed to reach. Validates against
/// scheme/host allow-lists and blocks private-network targets so SSRF
/// attempts via a fetch tool do not succeed. A clever encoding is still
/// the same address underneath, so IP-literal hosts are canonicalized via
/// `inet_pton` and alternative encodings (octal, hex, integer,
/// IPv4-mapped IPv6) are caught.
///
/// IDN homograph hosts are rejected outright — callers should supply
/// allow-list entries in Punycode (`xn--` form).
public struct URLSafetyVerifier: Verifier, Sendable {
    public typealias Input = String
    public let name: String
    public let cost: VerifierCost = .parse
    /// Allowed URL schemes (lowercased).
    public let allowedSchemes: Set<String>
    /// Optional allow-list of host names. Entries beginning with `.`
    /// match any subdomain.
    public let allowedHosts: Set<String>?
    /// Block-list of explicit host strings.
    public let blockedHosts: Set<String>
    /// When `true`, hosts on loopback/RFC1918/CGNAT/ULA/etc. are rejected.
    public let blockPrivateNetworks: Bool

    /// Hosts blocked by default (cloud metadata, loopback).
    public static let defaultBlockedHosts: Set<String> = [
        "localhost", "0.0.0.0", "::1",
        "metadata.google.internal",
        "169.254.169.254",
    ]

    /// Creates a verifier.
    public init(name: String = "url-safety",
                allowedSchemes: Set<String> = ["https"],
                allowedHosts: Set<String>? = nil,
                blockedHosts: Set<String>? = nil,
                blockPrivateNetworks: Bool = true) {
        self.name = name
        self.allowedSchemes = Set(allowedSchemes.map { $0.lowercased() })
        self.allowedHosts = allowedHosts.map { hosts in
            Set(hosts.map { Self.normalizeAllowedEntry($0) })
        }
        self.blockedHosts = (blockedHosts ?? Self.defaultBlockedHosts).reduce(into: Set<String>()) { $0.insert($1.lowercased()) }
        self.blockPrivateNetworks = blockPrivateNetworks
    }

    public func verify(_ input: String, context _: RunContext) async throws -> Verdict {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // IDN check on the *raw* input: Foundation silently punycodes the host
        // at URL-parse time, so by the time `url.host` returns we've lost the
        // ability to see Cyrillic-style homographs. Scan the authority portion
        // (between `://` and the first `/?#`) directly.
        if Self.authorityContainsNonASCII(trimmed) {
            return .reject("URL host contains non-ASCII characters: '\(input)'")
        }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              let rawHost = url.host(percentEncoded: false) else {
            return .reject("invalid URL: \(input)")
        }
        // Strip trailing dot, lowercase.
        var host = rawHost.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        if !allowedSchemes.contains(scheme) {
            return .reject("URL scheme '\(scheme)' not allowed (expected one of \(allowedSchemes.sorted()))")
        }
        // If the host is a literal IP-looking string but not in canonical form
        // (octal, hex, decimal-integer), reject it outright — these forms exist
        // mainly to defeat string-based filters.
        if Self.looksLikeNonCanonicalIPLiteral(host) {
            return .reject("URL host is a non-canonical IP literal: '\(host)'")
        }
        if blockedHosts.contains(host) {
            return .reject("URL host '\(host)' is blocked")
        }
        if let allowed = allowedHosts, !Self.matches(host: host, in: allowed) {
            return .reject("URL host '\(host)' is not in the allow-list")
        }
        if blockPrivateNetworks, Self.isPrivateNetworkHost(host) {
            return .reject("URL targets a private network: '\(host)'")
        }
        return .pass
    }

    static func normalizeAllowedEntry(_ s: String) -> String {
        var v = s.lowercased()
        if v.hasSuffix(".") { v.removeLast() }
        return v
    }

    // Returns true if the authority portion of the input (between `://` and
    // the first `/?#`, excluding any `user:pass@` userinfo) contains any
    // non-ASCII characters.
    static func authorityContainsNonASCII(_ input: String) -> Bool {
        let scheme = input.range(of: "://")
        let authorityStart = scheme?.upperBound ?? input.startIndex
        let stopChars: Set<Character> = ["/", "?", "#"]
        let authorityEnd = input[authorityStart...].firstIndex(where: { stopChars.contains($0) }) ?? input.endIndex
        var hostSlice = input[authorityStart..<authorityEnd]
        if let at = hostSlice.lastIndex(of: "@") {
            hostSlice = hostSlice[hostSlice.index(after: at)...]
        }
        return !hostSlice.allSatisfy(\.isASCII)
    }

    static func matches(host: String, in allowed: Set<String>) -> Bool {
        if allowed.contains(host) { return true }
        for entry in allowed {
            if entry.hasPrefix(".") && (host == String(entry.dropFirst()) || host.hasSuffix(entry)) {
                return true
            }
        }
        return false
    }

    /// True if the host is on a loopback, link-local, RFC1918, CGNAT, ULA, or
    /// other range that should not be reachable from a model-driven fetch tool.
    ///
    /// Hosts are canonicalized via `inet_pton` for both IPv4 and IPv6 so that
    /// alternative encodings (octal, hex, integer, IPv4-mapped IPv6) are
    /// caught — see also ``looksLikeNonCanonicalIPLiteral(_:)``.
    public static func isPrivateNetworkHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        if lower == "localhost" { return true }
        if lower.hasSuffix(".local") { return true }
        if lower.hasSuffix(".internal") { return true }

        // IPv6 literal: URL.host strips the surrounding brackets, but accept
        // either form here so isPrivateNetworkHost is robust as a public API.
        var v6Candidate = lower
        if v6Candidate.hasPrefix("[") && v6Candidate.hasSuffix("]") {
            v6Candidate = String(v6Candidate.dropFirst().dropLast())
        }
        if let bytes = parseIPv6(v6Candidate) {
            return isPrivateIPv6(bytes)
        }
        if let bytes = parseIPv4(lower) {
            return isPrivateIPv4(bytes)
        }
        return false
    }

    /// Parse a strict dotted-quad IPv4 address via `inet_pton`.
    static func parseIPv4(_ s: String) -> [UInt8]? {
        var addr = in_addr()
        let ok = s.withCString { inet_pton(AF_INET, $0, &addr) }
        guard ok == 1 else { return nil }
        // `inet_pton` writes the four octets in network byte order to s_addr's
        // memory. Read the bytes in that same order.
        var bytes = [UInt8](repeating: 0, count: 4)
        withUnsafeBytes(of: &addr) { raw in
            for i in 0..<4 { bytes[i] = raw[i] }
        }
        return bytes
    }

    /// Parse an IPv6 address (any form accepted by `inet_pton(AF_INET6)`).
    static func parseIPv6(_ s: String) -> [UInt8]? {
        var addr = in6_addr()
        let ok = s.withCString { inet_pton(AF_INET6, $0, &addr) }
        guard ok == 1 else { return nil }
        var bytes = [UInt8](repeating: 0, count: 16)
        withUnsafeBytes(of: &addr) { raw in
            for i in 0..<16 { bytes[i] = raw[i] }
        }
        return bytes
    }

    static func isPrivateIPv4(_ b: [UInt8]) -> Bool {
        precondition(b.count == 4)
        // 0.0.0.0/8 — "this network"
        if b[0] == 0 { return true }
        // 10.0.0.0/8
        if b[0] == 10 { return true }
        // 127.0.0.0/8 — loopback
        if b[0] == 127 { return true }
        // 169.254.0.0/16 — link-local (incl. AWS/GCP metadata)
        if b[0] == 169 && b[1] == 254 { return true }
        // 172.16.0.0/12
        if b[0] == 172 && (b[1] & 0xF0) == 16 { return true }
        // 192.168.0.0/16
        if b[0] == 192 && b[1] == 168 { return true }
        // 100.64.0.0/10 — CGNAT
        if b[0] == 100 && (b[1] & 0xC0) == 64 { return true }
        // 255.255.255.255 — broadcast
        if b[0] == 255 && b[1] == 255 && b[2] == 255 && b[3] == 255 { return true }
        return false
    }

    static func isPrivateIPv6(_ b: [UInt8]) -> Bool {
        precondition(b.count == 16)
        // ::1 — loopback
        if b == [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1] { return true }
        // :: — unspecified
        if b == [UInt8](repeating: 0, count: 16) { return true }
        // ::ffff:0:0/96 — IPv4-mapped IPv6
        if b.prefix(10).allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {
            return isPrivateIPv4(Array(b.suffix(4)))
        }
        // ::ffff:0:0:0/96 (IPv4-translated, RFC 6145) — treat as v4-mapped
        if b.prefix(8).allSatisfy({ $0 == 0 }) && b[8] == 0xff && b[9] == 0xff && b[10] == 0 && b[11] == 0 {
            return isPrivateIPv4(Array(b.suffix(4)))
        }
        // 64:ff9b::/96 — NAT64 well-known prefix
        if b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xff && b[3] == 0x9b
            && b.dropFirst(4).prefix(8).allSatisfy({ $0 == 0 }) {
            return true
        }
        // 100::/64 — discard-only address block
        if b[0] == 0x01 && b[1] == 0x00 && b.dropFirst(2).prefix(6).allSatisfy({ $0 == 0 }) {
            return true
        }
        // 2001::/32 — Teredo tunneling
        if b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x00 && b[3] == 0x00 { return true }
        // fc00::/7 — Unique Local Addresses
        if (b[0] & 0xfe) == 0xfc { return true }
        // fe80::/10 — link-local
        if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return true }
        return false
    }

    /// True if `host` looks like an IP literal in a non-canonical form
    /// (octal, hex, decimal integer, or a mix). These are reliable SSRF
    /// fingerprints and we reject them up front. A canonical dotted-quad
    /// address returns `false` and falls through to byte-range checks.
    static func looksLikeNonCanonicalIPLiteral(_ host: String) -> Bool {
        // IPv6 literals are handled by inet_pton; nothing further here.
        if host.contains(":") { return false }
        // All-digit host (e.g. "2130706433"): decimal-integer encoding.
        if !host.isEmpty, host.allSatisfy({ $0.isASCII && $0.isNumber }) {
            return true
        }
        // Dotted form where any octet has a leading zero (octal) or "0x"
        // prefix (hex), or where there aren't exactly four octets but the
        // string is composed only of dotted hex/octal-looking tokens.
        if host.contains(".") {
            let parts = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            // If every part is a valid IP-octet token (numeric / 0x-hex / 0-leading octal):
            let allOctetLike = parts.allSatisfy { isOctetLikeToken($0) }
            if allOctetLike {
                // Strict canonical IPv4 must be exactly 4 dotted decimal octets in
                // 0...255 with no leading zeros (except literal "0").
                if parts.count == 4, parts.allSatisfy({ isCanonicalDecimalOctet($0) }) {
                    return false
                }
                // Mixed-radix or wrong octet count — non-canonical IP literal.
                if parts.contains(where: { $0.hasPrefix("0x") || $0.hasPrefix("0X") }) {
                    return true
                }
                if parts.contains(where: { $0.count > 1 && $0.hasPrefix("0") && Int($0) != nil }) {
                    return true
                }
                if parts.count != 4 && parts.allSatisfy({ Int($0) != nil }) {
                    // e.g. "127.1" or "0x7f.1" — not a valid hostname either.
                    return true
                }
            }
        }
        return false
    }

    private static func isOctetLikeToken(_ s: String) -> Bool {
        if s.isEmpty { return false }
        if s.hasPrefix("0x") || s.hasPrefix("0X") {
            return s.dropFirst(2).allSatisfy { $0.isHexDigit }
        }
        return s.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static func isCanonicalDecimalOctet(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 3, s.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
        if s.count > 1 && s.hasPrefix("0") { return false }
        guard let n = Int(s), (0...255).contains(n) else { return false }
        return true
    }
}
