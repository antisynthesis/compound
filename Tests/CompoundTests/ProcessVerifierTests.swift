import Foundation
import Testing
@testable import Compound

@Suite("ProcessVerifier")
struct ProcessVerifierTests {
    @Test("swift-command passes on exit 0")
    func passesExitZero() async throws {
        let runner = StubProcessRunner(result: ProcessResult(exitCode: 0, stdout: "Build complete!", stderr: ""))
        let v = SwiftCommandVerifier.build(runner: runner)
        #expect((try await v.verify("/tmp/pkg", context: RunContext())).isPass)
    }

    @Test("swift-command repairs with stderr suggestion on non-zero exit")
    func repairsWithStderr() async throws {
        let runner = StubProcessRunner(result: ProcessResult(exitCode: 1, stdout: "", stderr: "error: cannot find 'foo' in scope"))
        let v = SwiftCommandVerifier.test(runner: runner)
        let verdict = try await v.verify("/tmp/pkg", context: RunContext())
        if case .repair(let d) = verdict {
            #expect(d.message.contains("failed"))
            #expect((d.suggestion ?? "").contains("foo"))
        } else {
            Issue.record("expected .repair")
        }
    }

    @Test("swift-command surfaces timeout flag")
    func surfacesTimeout() async throws {
        let runner = StubProcessRunner(result: ProcessResult(exitCode: -1, stdout: "", stderr: "", timedOut: true))
        let v = SwiftCommandVerifier.build(runner: runner)
        let verdict = try await v.verify("/tmp/pkg", context: RunContext())
        if case .repair(let d) = verdict {
            #expect(d.message.contains("timed out"))
        } else {
            Issue.record("expected .repair")
        }
    }

    @Test("swift-snippet typecheck passes on exit 0")
    func snippetTypecheckPasses() async throws {
        let runner = StubProcessRunner(result: ProcessResult(exitCode: 0, stdout: "", stderr: ""))
        let v = SwiftSnippetTypecheckVerifier(runner: runner)
        #expect((try await v.verify("let x: Int = 1\n", context: RunContext())).isPass)
    }

    @Test("swift-snippet typecheck repairs with stderr on failure")
    func snippetTypecheckRepairs() async throws {
        let runner = StubProcessRunner(result: ProcessResult(exitCode: 1, stdout: "", stderr: "error: missing semicolon"))
        let v = SwiftSnippetTypecheckVerifier(runner: runner)
        let verdict = try await v.verify("let x =\n", context: RunContext())
        if case .repair(let d) = verdict {
            #expect((d.suggestion ?? "").contains("semicolon"))
        } else {
            Issue.record("expected .repair")
        }
    }

    @Test("combinator: contramap reuses a string verifier on a struct field")
    func contramapReuses() async throws {
        let inner = EncodingVerifier()
        let v = inner.contramap(name: "edit-encoding") { (edit: ProposedEdit) in edit.newString }
        let bad = ProposedEdit(path: "x", oldString: "a", newString: "hello\0world")
        #expect((try await v.verify(bad, context: RunContext())).isRepair)
    }

    #if os(macOS) || os(Linux)
    @Test("default process runner sanitizes inherited environment")
    func sanitizesEnvironment() {
        let runner = DefaultProcessRunner()
        let resolved = runner.resolveEnvironment(nil) ?? [:]
        #expect(resolved["AWS_ACCESS_KEY_ID"] == nil)
        #expect(resolved["GITHUB_TOKEN"] == nil)
        #expect(resolved["DYLD_INSERT_LIBRARIES"] == nil)
        #expect(resolved["SSH_AUTH_SOCK"] == nil)
        let allowed: Set<String> = ["PATH", "HOME", "TMPDIR", "LANG", "LC_ALL"]
        for key in resolved.keys {
            #expect(allowed.contains(key), "unexpected env key '\(key)' in sanitized env")
        }
    }

    @Test("default process runner honors explicit caller environment verbatim")
    func honorsExplicitEnv() {
        let runner = DefaultProcessRunner()
        let caller: [String: String] = ["FOO": "bar", "BAZ": "qux"]
        let resolved = runner.resolveEnvironment(caller)
        #expect((resolved ?? [:]) == caller)
    }

    @Test("default process runner inherits full env when explicitly opted in")
    func inheritsFullEnvOptIn() {
        let runner = DefaultProcessRunner(inheritEnvironment: true)
        #expect(runner.resolveEnvironment(nil) == nil)
    }
    #endif
}
