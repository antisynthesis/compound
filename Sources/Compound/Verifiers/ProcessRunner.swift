import Foundation

/// The unembellished outcome of an external process invocation — exit code,
/// captured streams, and whether the clock ran out, with nothing inferred.
public struct ProcessResult: Sendable, Equatable {
    /// POSIX exit code, or `-1` when the process was terminated before exit.
    public let exitCode: Int32
    /// Captured standard output.
    public let stdout: String
    /// Captured standard error.
    public let stderr: String
    /// `true` if the process was terminated because it exceeded the timeout.
    public let timedOut: Bool

    /// Creates a result.
    public init(exitCode: Int32, stdout: String, stderr: String, timedOut: Bool = false) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

/// The seam through which a verifier reaches the real world and runs an
/// external process. Some claims can only be disposed of by execution, not
/// by inspection — this is the instrument that pays that cost.
///
/// Exposed on every platform so verifiers can be wired up uniformly;
/// the default ``DefaultProcessRunner`` is gated to platforms with
/// `Foundation.Process` (macOS and Linux). On iOS, supply a custom
/// runner that proxies to a server-side build service or refuse
/// process-backed checks.
public protocol ProcessRunner: Sendable {
    /// Runs `executable` with the supplied arguments. Returns a
    /// ``ProcessResult`` that records exit code, captured streams, and
    /// timeout status.
    func run(
        executable: String,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String]?,
        timeout: Duration?
    ) async throws -> ProcessResult
}

/// A ``ProcessRunner`` that runs nothing and always hands back a predefined
/// ``ProcessResult``. For tests, and for platforms where
/// `Foundation.Process` is unavailable.
public struct StubProcessRunner: ProcessRunner {
    /// Result returned for every invocation.
    public let result: ProcessResult
    /// Wraps `result`.
    public init(result: ProcessResult) { self.result = result }
    public func run(
        executable _: String,
        arguments _: [String],
        workingDirectory _: String?,
        environment _: [String: String]?,
        timeout _: Duration?
    ) async throws -> ProcessResult {
        result
    }
}

#if os(macOS) || os(Linux)
/// Runs child processes with a sanitized environment by default — the child
/// gets only what it needs, not the keys to the whole machine. Pass
/// `inheritEnvironment: true` to inherit the parent's full environment
/// when the child genuinely needs credentials or developer-tool vars.
public struct DefaultProcessRunner: ProcessRunner {
    /// When `true`, the child inherits the parent's full environment;
    /// otherwise a minimal allow-list (`PATH`, `HOME`, `TMPDIR`, `LANG`,
    /// `LC_ALL`) is supplied.
    public let inheritEnvironment: Bool

    /// Creates a runner.
    public init(inheritEnvironment: Bool = false) {
        self.inheritEnvironment = inheritEnvironment
    }

    public func run(
        executable: String,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String]?,
        timeout: Duration?
    ) async throws -> ProcessResult {
        let effectiveEnv = resolveEnvironment(environment)
        let processBox = ProcessBox()
        // Outer cancellation handler ensures that if the parent task is
        // cancelled while we're waiting on a detached process, the child
        // gets terminated rather than orphaned.
        return try await withTaskCancellationHandler {
            if let timeout {
                return try await withThrowingTaskGroup(of: ProcessOutcome.self) { group in
                    group.addTask {
                        try await Self.runDetached(
                            executable: executable,
                            arguments: arguments,
                            workingDirectory: workingDirectory,
                            environment: effectiveEnv,
                            register: processBox
                        )
                    }
                    group.addTask {
                        try await Task.sleep(for: timeout)
                        return .timedOut
                    }
                    guard let outcome = try await group.next() else {
                        throw CancellationError()
                    }
                    group.cancelAll()
                    switch outcome {
                    case .completed(let result):
                        return result
                    case .timedOut:
                        processBox.terminate()
                        return ProcessResult(exitCode: -1, stdout: "", stderr: "", timedOut: true)
                    }
                }
            }
            let outcome = try await Self.runDetached(
                executable: executable,
                arguments: arguments,
                workingDirectory: workingDirectory,
                environment: effectiveEnv,
                register: processBox
            )
            if case .completed(let r) = outcome { return r }
            return ProcessResult(exitCode: -1, stdout: "", stderr: "", timedOut: true)
        } onCancel: {
            processBox.terminate()
        }
    }

    /// When the caller supplies an explicit env, honor it verbatim. Otherwise
    /// either inherit the parent env (only if `inheritEnvironment` is true)
    /// or build a minimal allow-list so model-emitted code can't read
    /// credentials, keys, or developer tokens from the verifier's environment.
    func resolveEnvironment(_ caller: [String: String]?) -> [String: String]? {
        if let caller { return caller }
        if inheritEnvironment { return nil }
        let parent = ProcessInfo.processInfo.environment
        var minimal: [String: String] = [:]
        for key in ["PATH", "HOME", "TMPDIR", "LANG", "LC_ALL"] {
            if let value = parent[key] { minimal[key] = value }
        }
        return minimal
    }

    private enum ProcessOutcome: Sendable {
        case completed(ProcessResult)
        case timedOut
    }

    private static func runDetached(
        executable: String,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String]?,
        register: ProcessBox?
    ) async throws -> ProcessOutcome {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let workingDirectory {
                process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
            }
            if let environment {
                process.environment = environment
            }
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            try process.run()
            register?.set(process)
            process.waitUntilExit()
            let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return ProcessOutcome.completed(
                ProcessResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
            )
        }.value
    }
}

// Holds a Process reference so a sibling timeout task can terminate it. The
// reference itself is unsynchronized because the writer (the runner task)
// always sets before the reader (the timeout task) reads — the only
// contention is benign concurrent reads after set, which is safe for the
// terminate() call.
// `@unchecked` because mutable state is guarded by `lock` (NSLock).
final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    func set(_ p: Process) {
        lock.lock(); defer { lock.unlock() }
        process = p
    }
    func terminate() {
        lock.lock()
        let p = process
        lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }
}
#endif
