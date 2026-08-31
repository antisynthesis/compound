#if os(macOS)
import Foundation
import Testing
@testable import Compound

/// Live tests that spawn real child processes via /bin/sh. macOS-only:
/// they exercise DefaultProcessRunner's pipe draining, timeout kill
/// escalation, and cancellation reaping against actual POSIX semantics.
@Suite("ProcessRunnerLive")
struct ProcessRunnerLiveTests {
    @Test("large output completes without pipe deadlock", .timeLimit(.minutes(1)))
    func largeOutputNoDeadlock() async throws {
        let runner = DefaultProcessRunner()
        // ~1.35MB of stdout — far beyond the ~64KB kernel pipe buffer.
        // Before the concurrent-reader fix this deadlocked forever.
        let result = try await runner.run(
            executable: "/bin/sh",
            arguments: ["-c", "head -c 1000000 /dev/zero | base64"],
            workingDirectory: nil,
            environment: nil,
            timeout: .seconds(45)
        )
        #expect(result.exitCode == 0)
        #expect(!result.timedOut)
        #expect(!result.truncated)
        #expect(result.stdout.utf8.count > 1_000_000)
    }

    @Test("output is capped at maxOutputBytes with a truncation marker", .timeLimit(.minutes(1)))
    func outputTruncatedAtCap() async throws {
        let runner = DefaultProcessRunner(maxOutputBytes: 1024)
        let result = try await runner.run(
            executable: "/bin/sh",
            arguments: ["-c", "head -c 100000 /dev/zero | base64"],
            workingDirectory: nil,
            environment: nil,
            timeout: .seconds(45)
        )
        #expect(result.exitCode == 0)
        #expect(result.truncated)
        #expect(result.stdout.contains("truncated"))
        // 1024 bytes of payload plus the marker — nowhere near the raw size.
        #expect(result.stdout.utf8.count < 2048)
    }

    @Test("timeout returns timed-out result carrying partial output", .timeLimit(.minutes(1)))
    func timeoutCarriesPartialOutput() async throws {
        let runner = DefaultProcessRunner(killGracePeriod: .milliseconds(500))
        let result = try await runner.run(
            executable: "/bin/sh",
            arguments: ["-c", "echo partial; sleep 30"],
            workingDirectory: nil,
            environment: nil,
            timeout: .seconds(1)
        )
        #expect(result.timedOut)
        #expect(result.stdout.contains("partial"))
    }

    @Test("SIGKILL escalation reaps a child that ignores SIGTERM", .timeLimit(.minutes(1)))
    func sigkillEscalation() async throws {
        let runner = DefaultProcessRunner(killGracePeriod: .milliseconds(500))
        let clock = ContinuousClock()
        let start = clock.now
        // exec so the sleep inherits the ignored-TERM disposition and IS
        // the child process — only SIGKILL can end it early.
        let result = try await runner.run(
            executable: "/bin/sh",
            arguments: ["-c", "trap '' TERM; exec sleep 30"],
            workingDirectory: nil,
            environment: nil,
            timeout: .seconds(1)
        )
        let elapsed = clock.now - start
        #expect(result.timedOut)
        // Timeout (1s) + grace (0.5s) + drain slack — must be far under
        // the 30s the child would run if SIGKILL never landed.
        #expect(elapsed < .seconds(15))
    }

    @Test("task cancellation mid-run reaps the child", .timeLimit(.minutes(1)))
    func cancellationReapsChild() async throws {
        let runner = DefaultProcessRunner(killGracePeriod: .milliseconds(500))
        let clock = ContinuousClock()
        let start = clock.now
        let task = Task {
            try await runner.run(
                executable: "/bin/sleep",
                arguments: ["30"],
                workingDirectory: nil,
                environment: nil,
                timeout: nil
            )
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let result = try? await task.value
        let elapsed = clock.now - start
        // The child must have been terminated, not left running for 30s.
        #expect(elapsed < .seconds(10))
        if let result {
            #expect(result.exitCode != 0)
        }
    }
}
#endif
