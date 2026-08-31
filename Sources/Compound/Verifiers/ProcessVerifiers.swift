import Foundation

// Process-backed verifiers. These delegate to an external authoritative
// checker (the Swift compiler, the test runner, etc.) and convert its exit
// code and output into a Verdict. The verifier itself is platform-portable
// because it accepts a ProcessRunner — on iOS where Foundation.Process is
// unavailable, supply a custom runner that proxies to a build service.

/// Runs `swift <subcommand>` via a ``ProcessRunner`` and converts the
/// result into a ``Verdict``. Typically used for `swift build`,
/// `swift test`, or `swiftc -typecheck`. The process stderr (or stdout
/// when stderr is empty) is surfaced — truncated to ``outputBudget``
/// characters — as the diagnostic's suggestion so the model can react.
public struct SwiftCommandVerifier: Verifier {
    public typealias Input = String  // working-directory path
    public let name: String
    public let cost: VerifierCost
    /// Process runner used to invoke the swift toolchain.
    public let runner: ProcessRunner
    /// Path to the `swift` binary.
    public let swiftPath: String
    /// Subcommand arguments (e.g. `["build"]` or `["test", "--filter", "..."]`).
    public let arguments: [String]
    /// Optional wall-clock timeout for the invocation.
    public let timeout: Duration?
    /// Maximum characters of process output surfaced in the diagnostic.
    public let outputBudget: Int

    /// Creates a verifier.
    public init(
        name: String,
        cost: VerifierCost,
        runner: ProcessRunner,
        swiftPath: String = "/usr/bin/swift",
        arguments: [String],
        timeout: Duration? = .seconds(120),
        outputBudget: Int = 1200
    ) {
        self.name = name
        self.cost = cost
        self.runner = runner
        self.swiftPath = swiftPath
        self.arguments = arguments
        self.timeout = timeout
        self.outputBudget = outputBudget
    }

    public func verify(_ workingDirectory: String, context _: RunContext) async throws -> Verdict {
        let result = try await runner.run(
            executable: swiftPath,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: nil,
            timeout: timeout
        )
        if result.timedOut {
            // Surface any partial output captured before the process was
            // killed, so the model has compiler diagnostics to repair
            // against even when the invocation ran out of time.
            let partial = result.stderr.isEmpty ? result.stdout : result.stderr
            return .repair(Diagnostic(
                verifier: name,
                message: "process timed out",
                suggestion: partial.isEmpty ? nil : Self.truncate(partial, to: outputBudget)
            ))
        }
        if result.exitCode == 0 {
            return .pass
        }
        let suggestion = Self.truncate(result.stderr.isEmpty ? result.stdout : result.stderr, to: outputBudget)
        return .repair(Diagnostic(
            verifier: name,
            message: "swift \(arguments.first ?? "") failed (exit \(result.exitCode))",
            suggestion: suggestion
        ))
    }

    /// Convenience factory wired for `swift build`.
    public static func build(runner: ProcessRunner, swiftPath: String = "/usr/bin/swift", timeout: Duration? = .seconds(180)) -> SwiftCommandVerifier {
        SwiftCommandVerifier(
            name: "swift-build",
            cost: .types,
            runner: runner,
            swiftPath: swiftPath,
            arguments: ["build"],
            timeout: timeout
        )
    }

    /// Convenience factory wired for `swift test`.
    public static func test(runner: ProcessRunner, swiftPath: String = "/usr/bin/swift", timeout: Duration? = .seconds(300)) -> SwiftCommandVerifier {
        SwiftCommandVerifier(
            name: "swift-test",
            cost: .unitTest,
            runner: runner,
            swiftPath: swiftPath,
            arguments: ["test"],
            timeout: timeout
        )
    }

    static func truncate(_ s: String, to limit: Int) -> String {
        if s.count <= limit { return s }
        let idx = s.index(s.startIndex, offsetBy: limit)
        return String(s[..<idx]) + "… (truncated)"
    }
}

/// Type-checks a Swift source string in isolation by writing it to a
/// temp file and invoking `swiftc -typecheck`. A fast "does this even
/// parse and bind names" check to run before more expensive
/// build/test verifiers.
public struct SwiftSnippetTypecheckVerifier: Verifier {
    public typealias Input = String  // raw source
    public let name: String
    public let cost: VerifierCost = .types
    /// Process runner.
    public let runner: ProcessRunner
    /// Path to `swiftc`.
    public let swiftcPath: String
    /// Extra arguments appended to `-typecheck <temp-file>`.
    public let extraArguments: [String]
    /// Optional wall-clock timeout.
    public let timeout: Duration?
    /// Maximum characters of process output surfaced in the diagnostic.
    public let outputBudget: Int

    /// Creates a verifier.
    public init(
        name: String = "swift-typecheck",
        runner: ProcessRunner,
        swiftcPath: String = "/usr/bin/swiftc",
        extraArguments: [String] = [],
        timeout: Duration? = .seconds(60),
        outputBudget: Int = 1200
    ) {
        self.name = name
        self.runner = runner
        self.swiftcPath = swiftcPath
        self.extraArguments = extraArguments
        self.timeout = timeout
        self.outputBudget = outputBudget
    }

    public func verify(_ source: String, context _: RunContext) async throws -> Verdict {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("compound-\(UUID().uuidString).swift")
        do {
            try source.write(to: tmp, atomically: true, encoding: .utf8)
        } catch {
            return .reject("could not write temp file: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: tmp) }
        let args = ["-typecheck"] + extraArguments + [tmp.path]
        let result = try await runner.run(
            executable: swiftcPath,
            arguments: args,
            workingDirectory: nil,
            environment: nil,
            timeout: timeout
        )
        if result.timedOut {
            let partial = result.stderr.isEmpty ? result.stdout : result.stderr
            return .repair(Diagnostic(
                verifier: name,
                message: "typecheck timed out",
                suggestion: partial.isEmpty ? nil : SwiftCommandVerifier.truncate(partial, to: outputBudget)
            ))
        }
        if result.exitCode == 0 {
            return .pass
        }
        return .repair(Diagnostic(
            verifier: name,
            message: "swift typecheck failed (exit \(result.exitCode))",
            suggestion: SwiftCommandVerifier.truncate(result.stderr.isEmpty ? result.stdout : result.stderr, to: outputBudget)
        ))
    }
}
