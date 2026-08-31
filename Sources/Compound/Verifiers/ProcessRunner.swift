import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if os(macOS) || os(Linux)
import Dispatch
#endif

/// Outcome of an external process invocation.
public struct ProcessResult: Sendable, Equatable {
    /// POSIX exit code. When the process was terminated by a signal
    /// (timeout escalation, cancellation) this is the signal number as
    /// reported by `Process.terminationStatus`, or `-1` when the process
    /// never produced an exit status.
    public let exitCode: Int32
    /// Captured standard output. On timeout this carries whatever the
    /// process emitted before it was terminated, so callers can surface
    /// partial diagnostics.
    public let stdout: String
    /// Captured standard error. Also populated with partial output on
    /// timeout, like ``stdout``.
    public let stderr: String
    /// `true` if the process was terminated because it exceeded the timeout.
    public let timedOut: Bool
    /// `true` if either captured stream was capped at the runner's
    /// output limit and a truncation marker was appended.
    public let truncated: Bool

    /// Creates a result.
    public init(
        exitCode: Int32,
        stdout: String,
        stderr: String,
        timedOut: Bool = false,
        truncated: Bool = false
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.truncated = truncated
    }
}

/// Abstraction for invoking external processes from inside a verifier.
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

/// Canned ``ProcessRunner`` that always returns a predefined
/// ``ProcessResult``. Used in tests and on platforms where
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
/// Runs child processes with a sanitized environment by default. Pass
/// `inheritEnvironment: true` to inherit the parent's full environment
/// when the child genuinely needs credentials or developer-tool vars.
///
/// Both output pipes are drained concurrently while the child runs, so
/// children that emit more than the kernel pipe buffer (~64KB) cannot
/// deadlock against `waitUntilExit`. Accumulation per stream is capped
/// at ``maxOutputBytes``. On timeout the child receives SIGTERM, then —
/// after ``killGracePeriod`` — SIGKILL, and the returned result carries
/// whatever output accumulated before termination.
public struct DefaultProcessRunner: ProcessRunner {
    /// When `true`, the child inherits the parent's full environment;
    /// otherwise a minimal allow-list (`PATH`, `HOME`, `TMPDIR`, `LANG`,
    /// `LC_ALL`) is supplied.
    public let inheritEnvironment: Bool
    /// Per-stream cap on captured output bytes. Output beyond the cap is
    /// discarded and a truncation marker is appended.
    public let maxOutputBytes: Int
    /// How long to wait after SIGTERM before escalating to SIGKILL when
    /// the child exceeds its timeout (or the parent task is cancelled).
    public let killGracePeriod: Duration

    /// Creates a runner.
    public init(
        inheritEnvironment: Bool = false,
        maxOutputBytes: Int = 4 * 1024 * 1024,
        killGracePeriod: Duration = .seconds(2)
    ) {
        self.inheritEnvironment = inheritEnvironment
        self.maxOutputBytes = maxOutputBytes
        self.killGracePeriod = killGracePeriod
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
        let stdoutBuffer = OutputBuffer(maxBytes: maxOutputBytes)
        let stderrBuffer = OutputBuffer(maxBytes: maxOutputBytes)
        let grace = killGracePeriod
        // Outer cancellation handler ensures that if the parent task is
        // cancelled while we're waiting on a detached process, the child
        // gets terminated (and force-killed after the grace period)
        // rather than orphaned.
        return try await withTaskCancellationHandler {
            if let timeout {
                return try await withThrowingTaskGroup(of: ProcessEvent.self) { group in
                    group.addTask {
                        let status = try await Self.runDetached(
                            executable: executable,
                            arguments: arguments,
                            workingDirectory: workingDirectory,
                            environment: effectiveEnv,
                            stdoutBuffer: stdoutBuffer,
                            stderrBuffer: stderrBuffer,
                            register: processBox
                        )
                        return .exited(status)
                    }
                    group.addTask {
                        try await Task.sleep(for: timeout)
                        return .timedOut
                    }
                    guard let first = try await group.next() else {
                        throw CancellationError()
                    }
                    if case .exited(let status) = first {
                        group.cancelAll()
                        return Self.makeResult(
                            exitCode: status, stdout: stdoutBuffer, stderr: stderrBuffer, timedOut: false
                        )
                    }
                    // Timed out: SIGTERM, then SIGKILL after the grace
                    // period if the child has not exited. Always wait for
                    // the child's actual exit so partial output is joined
                    // and the process is reaped.
                    processBox.terminate()
                    group.addTask {
                        try await Task.sleep(for: grace)
                        return .graceExpired
                    }
                    while let event = try await group.next() {
                        switch event {
                        case .exited(let status):
                            group.cancelAll()
                            return Self.makeResult(
                                exitCode: status, stdout: stdoutBuffer, stderr: stderrBuffer, timedOut: true
                            )
                        case .graceExpired:
                            processBox.forceKill()
                        case .timedOut:
                            continue
                        }
                    }
                    throw CancellationError()
                }
            }
            let status = try await Self.runDetached(
                executable: executable,
                arguments: arguments,
                workingDirectory: workingDirectory,
                environment: effectiveEnv,
                stdoutBuffer: stdoutBuffer,
                stderrBuffer: stderrBuffer,
                register: processBox
            )
            return Self.makeResult(exitCode: status, stdout: stdoutBuffer, stderr: stderrBuffer, timedOut: false)
        } onCancel: {
            processBox.terminate()
            Task.detached {
                try? await Task.sleep(for: grace)
                processBox.forceKill()
            }
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

    private enum ProcessEvent: Sendable {
        case exited(Int32)
        case timedOut
        case graceExpired
    }

    private static func makeResult(
        exitCode: Int32,
        stdout: OutputBuffer,
        stderr: OutputBuffer,
        timedOut: Bool
    ) -> ProcessResult {
        let out = stdout.snapshot()
        let err = stderr.snapshot()
        return ProcessResult(
            exitCode: exitCode,
            stdout: out.text,
            stderr: err.text,
            timedOut: timedOut,
            truncated: out.truncated || err.truncated
        )
    }

    /// After the child exits, how long to wait for each stream to report
    /// EOF before returning with whatever accumulated. Bounded so a
    /// grandchild that inherited the pipe's write end (and outlives the
    /// direct child) cannot stall the runner.
    private static let drainGraceSeconds: Double = 0.5

    private static func runDetached(
        executable: String,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String]?,
        stdoutBuffer: OutputBuffer,
        stderrBuffer: OutputBuffer,
        register: ProcessBox?
    ) async throws -> Int32 {
        try await Task.detached(priority: .userInitiated) {
            try Self.runBlocking(
                executable: executable,
                arguments: arguments,
                workingDirectory: workingDirectory,
                environment: environment,
                stdoutBuffer: stdoutBuffer,
                stderrBuffer: stderrBuffer,
                register: register
            )
        }.value
    }

    /// Synchronous body of ``runDetached(executable:arguments:workingDirectory:environment:stdoutBuffer:stderrBuffer:register:)``.
    /// Deliberately blocking (`waitUntilExit`, timed semaphore waits) —
    /// always invoked from a detached task, never from an async context
    /// directly.
    private static func runBlocking(
        executable: String,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String]?,
        stdoutBuffer: OutputBuffer,
        stderrBuffer: OutputBuffer,
        register: ProcessBox?
    ) throws -> Int32 {
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
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        // Drain both pipes concurrently with the child's execution —
        // readers MUST be installed before waitUntilExit, otherwise a
        // child emitting more than the kernel pipe buffer deadlocks.
        // The semaphore is signaled once per stream on EOF.
        let eof = DispatchSemaphore(value: 0)
        stdoutHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                eof.signal()
            } else {
                stdoutBuffer.append(chunk)
            }
        }
        stderrHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                eof.signal()
            } else {
                stderrBuffer.append(chunk)
            }
        }
        do {
            try process.run()
        } catch {
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            throw error
        }
        register?.set(process)
        process.waitUntilExit()
        // Give each stream a bounded window to flush and hit EOF.
        _ = eof.wait(timeout: .now() + drainGraceSeconds)
        _ = eof.wait(timeout: .now() + drainGraceSeconds)
        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
        try? stdoutHandle.close()
        try? stderrHandle.close()
        return process.terminationStatus
    }
}

/// Accumulates chunks of pipe output up to a byte cap. Chunks beyond the
/// cap are discarded and the snapshot gains a truncation marker.
/// `@unchecked` because mutable state is guarded by `lock` (NSLock);
/// writers are the pipe readability handlers, readers are the runner.
final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var truncated = false
    private let maxBytes: Int

    init(maxBytes: Int) {
        self.maxBytes = max(0, maxBytes)
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let remaining = maxBytes - data.count
        if remaining <= 0 {
            truncated = true
            return
        }
        if chunk.count > remaining {
            data.append(chunk.prefix(remaining))
            truncated = true
        } else {
            data.append(chunk)
        }
    }

    func snapshot() -> (text: String, truncated: Bool) {
        lock.lock()
        defer { lock.unlock() }
        var text = String(decoding: data, as: UTF8.self)
        if truncated {
            text += "\n… (output truncated at \(maxBytes) bytes)"
        }
        return (text, truncated)
    }
}

// Holds a Process reference so a sibling timeout task (or the outer
// cancellation handler) can terminate it. `@unchecked` because the
// mutable reference is guarded by `lock` (NSLock); the writer (the
// runner task) always sets before any reader signals, and concurrent
// terminate()/forceKill() calls after set are safe.
final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func set(_ p: Process) {
        lock.lock(); defer { lock.unlock() }
        process = p
    }

    /// Sends SIGTERM, giving the child a chance to exit cleanly.
    func terminate() {
        lock.lock()
        let p = process
        lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }

    /// Sends SIGKILL for children that ignore or trap SIGTERM.
    func forceKill() {
        lock.lock()
        let p = process
        lock.unlock()
        if let p, p.isRunning {
            kill(p.processIdentifier, SIGKILL)
        }
    }
}
#endif
