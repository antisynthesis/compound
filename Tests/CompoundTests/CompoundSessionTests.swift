import Foundation
import FoundationModels
import Testing
@testable import Compound

// MARK: - Facade fakes

// SessionFakeModel conforms to both model surfaces so it can pass through
// the CompoundSession.Configuration.makeModel seam. respond() consumes a
// scripted queue (the last response repeats indefinitely); stream() serves
// the same script, yielding each response in small chunks.
actor SessionFakeModel: ModelResponding, ModelStreaming {
    private var responses: [String]
    private(set) var calls = 0
    private(set) var prompts: [String] = []

    init(_ responses: [String]) {
        self.responses = responses
    }

    private func nextResponse(for prompt: String) -> String {
        calls += 1
        prompts.append(prompt)
        if responses.count > 1 {
            return responses.removeFirst()
        }
        return responses.first ?? ""
    }

    func respond(to prompt: String, options _: GenerationOptions) async throws -> String {
        nextResponse(for: prompt)
    }

    func respondGenerating<T: Generable & Sendable>(
        _ type: T.Type,
        to prompt: String,
        options: GenerationOptions
    ) async throws -> T {
        fatalError("unused in tests")
    }

    func stream(to prompt: String, options _: GenerationOptions) async -> ModelStreamResult {
        let response = nextResponse(for: prompt)
        let (stream, cont) = AsyncThrowingStream<String, Error>.makeStream()
        let chunks = Self.chunk(response, size: 3)
        let final = Task<String, Error> {
            var acc = ""
            for piece in chunks {
                try Task.checkCancellation()
                cont.yield(piece)
                acc += piece
            }
            cont.finish()
            return acc
        }
        return ModelStreamResult(stream: stream, final: final)
    }

    private static func chunk(_ text: String, size: Int) -> [String] {
        guard !text.isEmpty else { return [] }
        var pieces: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            pieces.append(String(text[index..<end]))
            index = end
        }
        return pieces
    }
}

// ToolInvokingFakeModel drives the tool path the way the real session
// would: it invokes the policy-wrapped calculator handed to it through the
// makeModel seam and returns (or rethrows) the tool's result as the model
// output.
struct ToolInvokingFakeModel: ModelResponding, ModelStreaming {
    let tools: [any Tool]
    let expression: String

    func respond(to _: String, options _: GenerationOptions) async throws -> String {
        guard let calculator = tools.compactMap({ $0 as? VerifiedTool<CalculatorTool> }).first else {
            throw CompoundError.toolUnavailable(name: "calculator")
        }
        let arguments = try CalculatorTool.Arguments(
            GeneratedContent(properties: ["expression": expression])
        )
        return try await calculator.call(arguments: arguments)
    }

    func respondGenerating<T: Generable & Sendable>(
        _ type: T.Type,
        to prompt: String,
        options: GenerationOptions
    ) async throws -> T {
        fatalError("unused in tests")
    }

    func stream(to prompt: String, options: GenerationOptions) async -> ModelStreamResult {
        let (stream, cont) = AsyncThrowingStream<String, Error>.makeStream()
        let final = Task<String, Error> {
            do {
                let output = try await respond(to: prompt, options: options)
                cont.yield(output)
                cont.finish()
                return output
            } catch {
                cont.finish(throwing: error)
                throw error
            }
        }
        return ModelStreamResult(stream: stream, final: final)
    }
}

// Captures what CompoundSession hands the makeModel seam, synchronously —
// the factory closure is not async, so an NSLock-guarded box records the
// values for post-run assertions.
final class SeamCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _instructions: [String] = []
    private var _toolNames: [[String]] = []
    private var _runIDs: [UUID] = []

    func record(instructions: String, tools: [any Tool], runContext: RunContext) {
        lock.lock()
        defer { lock.unlock() }
        _instructions.append(instructions)
        _toolNames.append(tools.map(\.name))
        _runIDs.append(runContext.runID)
    }

    var instructions: [String] {
        lock.lock(); defer { lock.unlock() }
        return _instructions
    }

    var toolNames: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return _toolNames
    }

    var runIDs: [UUID] {
        lock.lock(); defer { lock.unlock() }
        return _runIDs
    }
}

// MARK: - Facade tests

@Suite("CompoundSession")
struct CompoundSessionTests {
    @Test("respond() happy path returns the loop outcome through the facade")
    func respondHappyPath() async throws {
        let model = SessionFakeModel(["hello"])
        let chain = VerifierChain<String>(name: "out", [
            AnyVerifier<String>(name: "pass", cost: .parse) { _, _ in .pass }
        ])
        let session = CompoundSession(.init(
            assembler: DefaultContextAssembler(baseInstructions: "be helpful"),
            outputVerifier: chain,
            makeModel: { _, _, _ in model }
        ))

        let outcome = try await session.respond(to: "hi")
        #expect(outcome.output == "hello")
        #expect(outcome.usage.turns == 1)
        let calls = await model.calls
        #expect(calls == 1)
    }

    @Test("makeModel receives instructions, instantiated tools, and a fresh RunContext per call")
    func seamReceivesRunInputs() async throws {
        let capture = SeamCapture()
        var registry = ToolRegistry()
        try registry.register(CalculatorTool())
        let session = CompoundSession(.init(
            assembler: DefaultContextAssembler(baseInstructions: "be helpful"),
            tools: registry,
            makeModel: { instructions, tools, runContext in
                capture.record(instructions: instructions, tools: tools, runContext: runContext)
                return SessionFakeModel(["ok"])
            }
        ))

        _ = try await session.respond(to: "first")
        _ = try await session.respond(to: "second")

        #expect(capture.instructions.count == 2)
        #expect(capture.instructions.allSatisfy { $0.contains("be helpful") })
        #expect(capture.toolNames == [["calculator"], ["calculator"]])
        // Each call is a fresh run with its own RunContext.
        #expect(Set(capture.runIDs).count == 2)
    }

    @Test("verifier repair flows through the facade")
    func repairThroughFacade() async throws {
        let model = SessionFakeModel(["bad", "fixed"])
        let chain = VerifierChain<String>(name: "out", [
            AnyVerifier<String>(name: "needs-fixed", cost: .parse) { input, _ in
                input == "fixed"
                    ? .pass
                    : .repair(Diagnostic(verifier: "needs-fixed", message: "say fixed"))
            }
        ])
        let session = CompoundSession(.init(
            assembler: DefaultContextAssembler(baseInstructions: "be helpful"),
            outputVerifier: chain,
            makeModel: { _, _, _ in model }
        ))

        let outcome = try await session.respond(to: "hi")
        #expect(outcome.output == "fixed")
        #expect(outcome.usage.repairAttempts == 1)
        // The repair turn carries the diagnostic, not the original prompt.
        let prompts = await model.prompts
        #expect(prompts.count == 2)
        #expect(prompts[1].contains("say fixed"))
    }

    @Test("policy denial on a tool call propagates out of respond()")
    func policyDenialPropagates() async throws {
        var registry = ToolRegistry()
        try registry.register(CalculatorTool(), requiredScopes: ["math"])
        let session = CompoundSession(.init(
            assembler: DefaultContextAssembler(baseInstructions: "be helpful"),
            tools: registry,
            policy: ScopeRequirement(),
            makeModel: { _, tools, _ in
                ToolInvokingFakeModel(tools: tools, expression: "1 + 2")
            }
        ))

        do {
            // Anonymous auth carries no scopes, so the wrapped tool denies.
            _ = try await session.respond(to: "compute")
            Issue.record("expected CompoundError.policyDenied")
        } catch let error as CompoundError {
            guard case .policyDenied(let reason) = error else {
                Issue.record("expected policyDenied, got \(error)")
                return
            }
            #expect(reason.contains("math"))
        }
    }

    @Test("verifier rejection surfaces as verifierRejected through the facade")
    func rejectionPropagates() async throws {
        let model = SessionFakeModel(["anything"])
        let chain = VerifierChain<String>(name: "out", [
            AnyVerifier<String>(name: "always-reject", cost: .parse) { _, _ in
                .reject(Diagnostic(verifier: "always-reject", message: "nope"))
            }
        ])
        let session = CompoundSession(.init(
            assembler: DefaultContextAssembler(baseInstructions: "be helpful"),
            outputVerifier: chain,
            makeModel: { _, _, _ in model }
        ))

        do {
            _ = try await session.respond(to: "hi")
            Issue.record("expected CompoundError.verifierRejected")
        } catch let error as CompoundError {
            guard case .verifierRejected(let reason, let diagnostic) = error else {
                Issue.record("expected verifierRejected, got \(error)")
                return
            }
            #expect(reason == "nope")
            #expect(diagnostic?.verifier == "always-reject")
        }
    }

    @Test("tracer receives runStarted and runEnded through the full stack")
    func tracerThroughFullStack() async throws {
        let tracer = InMemoryTracer()
        let model = SessionFakeModel(["done"])
        let session = CompoundSession(.init(
            assembler: DefaultContextAssembler(baseInstructions: "be helpful"),
            tracer: tracer,
            makeModel: { _, _, _ in model }
        ))

        _ = try await session.respond(to: "hi")

        let events = await tracer.snapshot()
        let started = events.contains { if case .runStarted = $0 { return true }; return false }
        let endedOK = events.contains { ev in
            if case .runEnded(_, let success, _) = ev { return success }
            return false
        }
        #expect(started)
        #expect(endedOK)
    }

    @Test("stream() yields chunks from an injected fake ModelStreaming")
    func streamYieldsChunks() async throws {
        let model = SessionFakeModel(["hello world"])
        let session = CompoundSession(.init(
            assembler: DefaultContextAssembler(baseInstructions: "be helpful"),
            makeModel: { _, _, _ in model }
        ))

        let run = try await session.stream(userPrompt: "hi")
        var chunks: [String] = []
        for try await event in run.stream {
            if case .modelStreamChunk(_, let content) = event {
                chunks.append(content)
            }
        }
        let outcome = try await run.outcome.value
        #expect(outcome.final == "hello world")
        #expect(chunks.count > 1)
        #expect(chunks.joined() == "hello world")
    }
}
