import Foundation
import FoundationModels
import Testing
@testable import Compound

// Records every prompt it receives. Stateless by design: each respond()
// call sees only the prompt it was handed — exactly the conformer class
// the default RepairPromptBuilder exists for.
actor PromptRecordingModel: ModelResponding {
    private(set) var prompts: [String] = []
    private let respondWith: @Sendable (_ prompt: String, _ call: Int) -> String

    init(respondWith: @escaping @Sendable (_ prompt: String, _ call: Int) -> String) {
        self.respondWith = respondWith
    }

    func respond(to prompt: String, options _: GenerationOptions) async throws -> String {
        prompts.append(prompt)
        return respondWith(prompt, prompts.count)
    }

    func respondGenerating<T: Generable & Sendable>(
        _ type: T.Type,
        to prompt: String,
        options: GenerationOptions
    ) async throws -> T {
        fatalError("unused in tests")
    }
}

// Streaming counterpart: records prompts into a shared recorder, streams
// canned chunks per turn.
actor StreamPromptRecorder {
    private(set) var prompts: [String] = []
    func record(_ prompt: String) -> Int {
        prompts.append(prompt)
        return prompts.count
    }
}

struct PromptRecordingStreamingModel: ModelStreaming {
    let recorder: StreamPromptRecorder
    let turns: [[String]]

    func stream(to prompt: String, options _: GenerationOptions) async -> ModelStreamResult {
        let call = await recorder.record(prompt)
        let chunks = turns[min(call - 1, turns.count - 1)]
        let (stream, cont) = AsyncThrowingStream<String, Error>.makeStream()
        let final = Task<String, Error> {
            var acc = ""
            for chunk in chunks {
                cont.yield(chunk)
                acc += chunk
            }
            cont.finish()
            return acc
        }
        return ModelStreamResult(stream: stream, final: final)
    }
}

@Suite("RepairPrompt")
struct RepairPromptTests {
    private func wantGoodChain() -> VerifierChain<String> {
        VerifierChain<String>(name: "out", [
            AnyVerifier<String>(name: "needs-good", cost: .parse) { input, _ in
                input.contains("good")
                    ? .pass
                    : .repair(Diagnostic(
                        verifier: "needs-good",
                        message: "output must contain the word good",
                        suggestion: "include the word good"
                    ))
            }
        ])
    }

    @Test("stateless model succeeds only because the repair prompt carries the original task")
    func statelessModelNeedsTaskInRepairPrompt() async throws {
        let task = "Summarize the Q3 report in one sentence."
        // Stateless fake: it can only produce "good" when the prompt it is
        // handed still contains the original task AND the concrete
        // validation error — it has no memory of the first call.
        let model = PromptRecordingModel { prompt, call in
            if call == 1 { return "bad first draft" }
            let selfContained = prompt.contains(task)
                && prompt.contains("output must contain the word good")
                && prompt.contains("bad first draft")
            return selfContained ? "good rewrite" : "still bad"
        }
        let loop = ControlLoop(budget: .default, outputVerifier: wantGoodChain())
        let outcome = try await loop.run(prompt: task, modelClient: model, runContext: RunContext())
        #expect(outcome.output == "good rewrite")
        #expect(outcome.usage.repairAttempts == 1)

        let prompts = await model.prompts
        #expect(prompts.count == 2)
        let repair = try #require(prompts.last)
        #expect(repair.contains(task))
        #expect(repair.contains("bad first draft"))
        #expect(repair.contains("output must contain the word good"))
        #expect(repair.contains("include the word good"))
    }

    @Test("diagnosticOnly builder preserves the legacy diagnostic-only prompt")
    func diagnosticOnlyPreservesLegacyBehavior() async throws {
        let model = PromptRecordingModel { _, call in call == 1 ? "bad" : "good" }
        let loop = ControlLoop(
            budget: .default,
            outputVerifier: wantGoodChain(),
            repairPromptBuilder: .diagnosticOnly
        )
        _ = try await loop.run(prompt: "the task", modelClient: model, runContext: RunContext())
        let prompts = await model.prompts
        let repair = try #require(prompts.last)
        #expect(repair == "The previous response failed verification: output must contain the word good. include the word good Produce a corrected response.")
        // The legacy shape deliberately omits task and failed output.
        #expect(!repair.contains("the task"))
        #expect(!repair.contains("bad"))
    }

    @Test("custom builder receives originalTask, failed output, diagnostics, and attempt")
    func customBuilderReceivesRepairContext() async throws {
        let captured = CapturedContexts()
        let builder = RepairPromptBuilder { context in
            captured.append(context)
            return "custom repair: \(context.originalTask)"
        }
        let model = PromptRecordingModel { prompt, call in
            call == 1 ? "bad" : (prompt.hasPrefix("custom repair:") ? "good" : "bad")
        }
        let loop = ControlLoop(
            budget: .default,
            outputVerifier: wantGoodChain(),
            repairPromptBuilder: builder
        )
        _ = try await loop.run(prompt: "task-42", modelClient: model, runContext: RunContext())

        let contexts = captured.snapshot()
        let context = try #require(contexts.first)
        #expect(context.originalTask == "task-42")
        #expect(context.failedOutput == "bad")
        #expect(!context.failedOutputTruncated)
        #expect(context.attempt == 1)
        #expect(context.diagnostics.count == 1)
        #expect(context.diagnostics.first?.verifier == "needs-good")
    }

    @Test("repair prompt after a second failure carries the ORIGINAL task, not the prior repair prompt")
    func repairAlwaysCarriesOriginalTask() async throws {
        let task = "original assignment"
        let model = PromptRecordingModel { _, call in
            switch call {
            case 1, 2: return "bad \(call)"
            default: return "good"
            }
        }
        let loop = ControlLoop(budget: .default, outputVerifier: wantGoodChain())
        let outcome = try await loop.run(prompt: task, modelClient: model, runContext: RunContext())
        #expect(outcome.usage.repairAttempts == 2)
        let prompts = await model.prompts
        #expect(prompts.count == 3)
        let secondRepair = try #require(prompts.last)
        #expect(secondRepair.contains("Original task:\n\(task)"))
        // The failed output echoed is the second failure, not the first.
        #expect(secondRepair.contains("bad 2"))
        #expect(secondRepair.contains("repair attempt 2"))
    }

    @Test("failed output is truncated to the builder's byte cap on a character boundary")
    func failedOutputTruncatedToByteCap() async throws {
        // 2-byte UTF-8 character; an odd byte cap must not split it.
        let big = String(repeating: "é", count: 200) // 400 bytes
        let builder = RepairPromptBuilder(failedOutputByteCap: 101) { context in
            #expect(context.failedOutputTruncated)
            #expect(context.failedOutput.utf8.count <= 101)
            #expect(context.failedOutput == String(repeating: "é", count: 50))
            return "retry: fixed"
        }
        let chain = VerifierChain<String>(name: "out", [
            AnyVerifier<String>(name: "no-e", cost: .parse) { input, _ in
                input.contains("é")
                    ? .repair(Diagnostic(verifier: "no-e", message: "too many accents"))
                    : .pass
            }
        ])
        let model = PromptRecordingModel { prompt, call in
            call == 1 ? big : (prompt.hasPrefix("retry:") ? "clean" : big)
        }
        let loop = ControlLoop(budget: .default, outputVerifier: chain, repairPromptBuilder: builder)
        let outcome = try await loop.run(prompt: "task", modelClient: model, runContext: RunContext())
        #expect(outcome.output == "clean")
    }

    @Test("truncate helper respects UTF-8 boundaries and reports truncation")
    func truncateHelper() {
        let (untouched, wasTruncated) = RepairPromptBuilder.truncate("abc", toUTF8Bytes: 3)
        #expect(untouched == "abc")
        #expect(!wasTruncated)

        let (cut, cutFlag) = RepairPromptBuilder.truncate("abcdef", toUTF8Bytes: 4)
        #expect(cut == "abcd")
        #expect(cutFlag)

        // "🙂" is 4 bytes; a 5-byte cap keeps only "a🙂".
        let (emoji, emojiFlag) = RepairPromptBuilder.truncate("a🙂🙂", toUTF8Bytes: 5)
        #expect(emoji == "a🙂")
        #expect(emojiFlag)

        let (empty, emptyFlag) = RepairPromptBuilder.truncate("abc", toUTF8Bytes: 0)
        #expect(empty == "")
        #expect(emptyFlag)
    }

    @Test("collectAll folds three seeded diagnostics into one repair prompt")
    func collectAllFoldsDiagnosticsIntoOnePrompt() async throws {
        // Three independent defects, each caught by its own verifier. In
        // collectAll mode a single repair round reports all three, so the
        // model can fix them together.
        func requires(_ word: String, name: String, cost: VerifierCost) -> AnyVerifier<String> {
            AnyVerifier<String>(name: name, cost: cost) { input, _ in
                input.contains(word)
                    ? .pass
                    : .repair(Diagnostic(verifier: name, message: "missing \(word)"))
            }
        }
        let chain = VerifierChain<String>(
            name: "out",
            mode: .collectAll(maxDiagnostics: 8),
            [
                requires("alpha", name: "a", cost: .parse),
                requires("beta", name: "b", cost: .schema),
                requires("gamma", name: "c", cost: .types),
            ]
        )
        let model = PromptRecordingModel { prompt, call in
            if call == 1 { return "nothing here" }
            // The single repair prompt must name all three defects.
            let sawAll = prompt.contains("missing alpha")
                && prompt.contains("missing beta")
                && prompt.contains("missing gamma")
            return sawAll ? "alpha beta gamma" : "nothing here"
        }
        let loop = ControlLoop(budget: .default, outputVerifier: chain)
        let outcome = try await loop.run(prompt: "task", modelClient: model, runContext: RunContext())
        #expect(outcome.output == "alpha beta gamma")
        // One repair round fixed all three defects.
        #expect(outcome.usage.repairAttempts == 1)
        let prompts = await model.prompts
        #expect(prompts.count == 2)
    }

    @Test("streaming loop repair prompt is self-contained too")
    func streamingRepairPromptCarriesTask() async throws {
        let task = "stream me a poem"
        let recorder = StreamPromptRecorder()
        let model = PromptRecordingStreamingModel(
            recorder: recorder,
            turns: [["bad ", "draft"], ["good ", "poem"]]
        )
        let loop = StreamingControlLoop(budget: .default, outputVerifier: wantGoodChain())
        let run = loop.run(prompt: task, modelClient: model, runContext: RunContext())
        for try await _ in run.stream {}
        let outcome = try await run.outcome.value
        #expect(outcome.final == "good poem")
        #expect(outcome.usage.repairAttempts == 1)

        let prompts = await recorder.prompts
        #expect(prompts.count == 2)
        let repair = try #require(prompts.last)
        #expect(repair.contains(task))
        #expect(repair.contains("bad draft"))
        #expect(repair.contains("output must contain the word good"))
    }

    @Test("streaming loop honors a custom repair prompt builder")
    func streamingLoopHonorsCustomBuilder() async throws {
        let recorder = StreamPromptRecorder()
        let model = PromptRecordingStreamingModel(
            recorder: recorder,
            turns: [["bad"], ["good"]]
        )
        let builder = RepairPromptBuilder { context in
            "REPAIR[\(context.attempt)]: \(context.originalTask)"
        }
        let loop = StreamingControlLoop(
            budget: .default,
            outputVerifier: wantGoodChain(),
            repairPromptBuilder: builder
        )
        let run = loop.run(prompt: "t", modelClient: model, runContext: RunContext())
        for try await _ in run.stream {}
        _ = try await run.outcome.value
        let prompts = await recorder.prompts
        #expect(prompts.last == "REPAIR[1]: t")
    }
}

// NSLock-guarded so a synchronous @Sendable builder closure can record
// contexts without hopping to an actor.
final class CapturedContexts: @unchecked Sendable {
    private let lock = NSLock()
    private var contexts: [RepairContext] = []

    func append(_ context: RepairContext) {
        lock.lock()
        defer { lock.unlock() }
        contexts.append(context)
    }

    func snapshot() -> [RepairContext] {
        lock.lock()
        defer { lock.unlock() }
        return contexts
    }
}
