import Foundation
import FoundationModels
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Resolves a hostname to one or more IP literals so SSRF gates can be
/// re-evaluated against the actual peer addresses (defeats DNS
/// rebinding). The default is ``SystemHostResolver``; tests can inject
/// a fake.
public protocol HostResolver: Sendable {
    /// Returns numeric IP strings for `host`.
    func resolve(_ host: String) async throws -> [String]
}

/// Resolves hostnames via `getaddrinfo`. Returns numeric IPv4/IPv6
/// strings on a detached task so the calling actor is not blocked.
public struct SystemHostResolver: HostResolver {
    /// Creates an instance.
    public init() {}
    /// Synchronously resolves `host` on a detached task.
    public func resolve(_ host: String) async throws -> [String] {
        try await Task.detached(priority: .userInitiated) {
            try Self.resolveSync(host)
        }.value
    }

    static func resolveSync(_ host: String) throws -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        let status = host.withCString { getaddrinfo($0, nil, &hints, &res) }
        guard status == 0, let head = res else {
            throw WebFetchError.dnsResolutionFailed(host)
        }
        defer { freeaddrinfo(head) }
        var out: [String] = []
        var p: UnsafeMutablePointer<addrinfo>? = head
        while let cur = p {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let ok = getnameinfo(cur.pointee.ai_addr,
                                 cur.pointee.ai_addrlen,
                                 &buf, socklen_t(buf.count),
                                 nil, socklen_t(0),
                                 Int32(NI_NUMERICHOST))
            if ok == 0 {
                let bytes = buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                out.append(String(decoding: bytes, as: UTF8.self))
            }
            p = cur.pointee.ai_next
        }
        return out
    }
}

enum WebFetchError: Error {
    case dnsResolutionFailed(String)
}

/// Fetches the body of an HTTPS URL and returns it as text. The tool is
/// intentionally narrow — it performs a single GET request, refuses
/// non-HTTPS schemes by default, and caps the response size. For richer
/// behavior (POST, custom headers, response streaming) wrap this tool
/// or use `URLSession` directly inside your own tool.
///
/// Pair this with ``URLSafetyVerifier`` at the `VerifiedTool` argument
/// layer for an additional gate against SSRF — the tool's built-in
/// allow/block lists are a backstop, not a substitute for the verifier.
public struct WebFetchTool: Tool {
    public typealias Output = String

    public let name: String = "web_fetch"
    public let description: String = "Fetch the text body of an HTTPS URL (capped at maxBytes)."
    public let parameters: GenerationSchema
    public let includesSchemaInInstructions: Bool = true

    /// URL session used for the request.
    public let session: URLSession
    /// Per-request timeout.
    public let timeout: TimeInterval
    /// Maximum number of response bytes the tool will buffer.
    public let maxBytes: Int
    /// Allowed URL schemes (default `["https"]`).
    public let allowedSchemes: Set<String>
    /// Hostnames blocked at the tool layer in addition to the verifier.
    public let blockedHosts: Set<String>
    /// Resolver consulted to defeat DNS rebinding.
    public let resolver: HostResolver
    /// Maximum number of HTTP redirects to follow. Every hop is re-gated
    /// against the full SSRF policy; exceeding this cap aborts the fetch.
    public let maxRedirects: Int

    /// Creates a tool with the supplied gating policy.
    public init(
        session: URLSession = .shared,
        timeout: TimeInterval = 15,
        maxBytes: Int = 256 * 1024,
        allowedSchemes: Set<String> = ["https"],
        blockedHosts: Set<String> = URLSafetyVerifier.defaultBlockedHosts,
        resolver: HostResolver = SystemHostResolver(),
        maxRedirects: Int = 5
    ) {
        self.session = session
        self.timeout = timeout
        self.maxBytes = maxBytes
        self.allowedSchemes = allowedSchemes
        self.blockedHosts = blockedHosts
        self.resolver = resolver
        self.maxRedirects = maxRedirects
        let schema = DynamicGenerationSchema(
            name: "WebFetchArguments",
            description: "Arguments for the web_fetch tool",
            properties: [
                .init(
                    name: "url",
                    description: "Fully qualified HTTPS URL to fetch.",
                    schema: DynamicGenerationSchema(type: String.self)
                )
            ]
        )
        self.parameters = try! GenerationSchema(root: schema, dependencies: [])
    }

    /// Decoded arguments for ``WebFetchTool``.
    public struct Arguments: ConvertibleFromGeneratedContent, Sendable {
        /// Fully qualified URL to fetch.
        public let url: String
        /// Decodes `content`.
        public init(_ content: GeneratedContent) throws {
            self.url = try content.value(String.self, forProperty: "url")
        }
    }

    /// Performs a single GET and returns the body text. SSRF gates are
    /// enforced before the request and against the resolved peer
    /// address. Errors are returned in-band as `"error: ..."` strings;
    /// cancellation is re-thrown.
    public func call(arguments: Arguments) async throws -> String {
        guard let url = URL(string: arguments.url) else {
            return ToolResult.inBandError("invalid URL")
        }
        // Gate the initial URL against the full SSRF policy.
        if let reason = try await gate(url) {
            return ToolResult.inBandError("\(reason)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("text/plain, text/html, application/json", forHTTPHeaderField: "Accept")

        // Re-run the same gate on every redirect hop. URLSession follows
        // redirects with its default policy *after* the initial gate, so
        // without this a vetted host could 302 to 169.254.169.254 (cloud
        // metadata) or any private address and the tool would happily
        // fetch it. The delegate re-evaluates scheme/host/resolver per hop
        // and caps the number of hops.
        let redirectGuard = RedirectGuard(maxRedirects: maxRedirects) { [self] hopURL in
            try await self.gate(hopURL)
        }
        // Install the guard as a session-level delegate so it reliably
        // receives `willPerformHTTPRedirection` on every hop. The wrapper
        // session inherits the injected session's configuration (protocol
        // classes, timeouts, cookie policy, ...) and is torn down when the
        // fetch completes.
        let guardedSession = URLSession(
            configuration: session.configuration,
            delegate: redirectGuard,
            delegateQueue: nil
        )
        defer { guardedSession.finishTasksAndInvalidate() }
        do {
            let (byteStream, response) = try await guardedSession.bytes(for: request)
            if let reason = redirectGuard.blockReason {
                return ToolResult.inBandError("\(reason)")
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return ToolResult.inBandError("HTTP \(http.statusCode)")
            }
            var buffer = Data()
            buffer.reserveCapacity(min(maxBytes, 64 * 1024))
            var overflow = false
            for try await byte in byteStream {
                if buffer.count >= maxBytes {
                    overflow = true
                    break
                }
                buffer.append(byte)
            }
            if overflow {
                // URLSession.AsyncBytes doesn't expose the task to cancel;
                // breaking the loop drops the reference and the connection
                // tears down. Truncate to a UTF-8 boundary so we don't return
                // a half-encoded code point.
                buffer = truncatedToUTF8Boundary(buffer)
            }
            return String(data: buffer, encoding: .utf8) ?? ToolResult.inBandError("response was not valid UTF-8")
        } catch {
            if error is CancellationError { throw error }
            return ToolResult.inBandError("\(error.localizedDescription)")
        }
    }

    /// Evaluates one URL (the initial request or a redirect target)
    /// against the full SSRF policy: scheme allow-list, host block-list,
    /// non-canonical IP-literal rejection, private-network rejection, and
    /// a DNS resolution check that rejects any address resolving onto the
    /// blocklist (defeating DNS rebinding).
    ///
    /// Returns `nil` when the URL is safe to fetch, or a human-readable
    /// reason string when it must be blocked. Re-throws `CancellationError`
    /// so cooperative cancellation still propagates.
    ///
    /// - Note: This is a resolve-then-connect check, so a classic DNS
    ///   TOCTOU window remains: a resolver could return a public address
    ///   here and a private one when `URLSession` actually connects.
    ///   Fully closing it requires pinning the connection to the vetted
    ///   address (a custom `URLProtocol` or socket-level control), which
    ///   is out of scope for this tool; the per-hop re-gate narrows but
    ///   does not eliminate the window.
    func gate(_ url: URL) async throws -> String? {
        guard let scheme = url.scheme?.lowercased(),
              let rawHost = url.host(percentEncoded: false) else {
            return "invalid URL"
        }
        var host = rawHost.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        guard host.allSatisfy({ $0.isASCII }) else {
            return "host contains non-ASCII characters"
        }
        if !allowedSchemes.contains(scheme) {
            return "scheme '\(scheme)' not allowed"
        }
        if blockedHosts.contains(host) {
            return "host '\(host)' is blocked"
        }
        if URLSafetyVerifier.looksLikeNonCanonicalIPLiteral(host) {
            return "host '\(host)' is a non-canonical IP literal"
        }
        if URLSafetyVerifier.isPrivateNetworkHost(host) {
            return "host '\(host)' is on a private network"
        }

        // Defeat DNS rebinding: resolve the hostname now and reject if any
        // returned address is on the SSRF blocklist. Literal IPs short-circuit
        // because resolution would just echo the input.
        let resolved: [String]
        if URLSafetyVerifier.parseIPv4(host) != nil || URLSafetyVerifier.parseIPv6(host) != nil {
            resolved = [host]
        } else {
            do {
                resolved = try await resolver.resolve(host)
            } catch {
                if error is CancellationError { throw error }
                return "DNS resolution failed for '\(host)'"
            }
        }
        if resolved.isEmpty {
            return "DNS resolution returned no addresses for '\(host)'"
        }
        for ip in resolved {
            let normalized = ip.split(separator: "%").first.map(String.init) ?? ip  // strip zone id
            if URLSafetyVerifier.isPrivateNetworkHost(normalized) {
                return "host '\(host)' resolves to private address '\(normalized)'"
            }
        }
        return nil
    }

    /// Drop a trailing incomplete UTF-8 code point if the buffer was cut
    /// mid-sequence. Look back at most three bytes for a lead.
    private func truncatedToUTF8Boundary(_ data: Data) -> Data {
        var d = data
        let bytes = [UInt8](d)
        var trailingContinuations = 0
        while trailingContinuations < 3,
              bytes.count - 1 - trailingContinuations >= 0 {
            let byte = bytes[bytes.count - 1 - trailingContinuations]
            if byte & 0b1100_0000 == 0b1000_0000 {
                trailingContinuations += 1
            } else {
                break
            }
        }
        let leadIndex = bytes.count - 1 - trailingContinuations
        guard leadIndex >= 0 else { return d }
        let lead = bytes[leadIndex]
        let expected: Int
        if lead & 0b1000_0000 == 0 { expected = 0 }
        else if lead & 0b1110_0000 == 0b1100_0000 { expected = 1 }
        else if lead & 0b1111_0000 == 0b1110_0000 { expected = 2 }
        else if lead & 0b1111_1000 == 0b1111_0000 { expected = 3 }
        else { expected = 0 }
        if trailingContinuations < expected {
            d.removeLast(trailingContinuations + 1)
        }
        return d
    }
}

/// Per-task `URLSession` delegate that re-gates every HTTP redirect hop
/// against the same SSRF policy the initial request passed, and caps the
/// number of hops. Returning `nil` from the redirect callback cancels the
/// redirect; the block reason is recorded for the caller to surface.
///
/// `@unchecked Sendable`: mutable state (`hops`, `_blockReason`) is guarded
/// by an `NSLock`, and the injected `gate` closure is `@Sendable`.
final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let gate: @Sendable (URL) async throws -> String?
    private let maxRedirects: Int
    private let lock = NSLock()
    private var hops = 0
    private var _blockReason: String?

    init(maxRedirects: Int, gate: @escaping @Sendable (URL) async throws -> String?) {
        self.maxRedirects = maxRedirects
        self.gate = gate
    }

    /// Reason the fetch was blocked mid-flight, if any.
    var blockReason: String? {
        lock.lock(); defer { lock.unlock() }
        return _blockReason
    }

    private func record(_ reason: String) {
        lock.lock(); defer { lock.unlock() }
        if _blockReason == nil { _blockReason = reason }
    }

    // Non-async so it can touch the NSLock (whose lock/unlock are
    // unavailable from async contexts); returns the incremented hop count.
    private func nextHop() -> Int {
        lock.lock(); defer { lock.unlock() }
        hops += 1
        return hops
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let hop = nextHop()
        if hop > maxRedirects {
            record("too many redirects (> \(maxRedirects))")
            completionHandler(nil)
            return
        }
        guard let url = request.url else {
            record("redirect to an invalid URL")
            completionHandler(nil)
            return
        }
        Task { [self] in
            do {
                if let reason = try await gate(url) {
                    record("redirect blocked: \(reason)")
                    completionHandler(nil)
                } else {
                    completionHandler(request)
                }
            } catch {
                // Cancellation or any gate fault: refuse to follow the hop.
                record("redirect gate failed")
                completionHandler(nil)
            }
        }
    }
}
