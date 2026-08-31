import Foundation
import Testing
@testable import Compound

// MARK: - Fixtures

/// Observer that only records. Honors the protocol's contract — it
/// returns immediately and consolidates nothing inline.
private actor SessionRecordingObserver: MemoryTurnObserving {
    private(set) var turns: [MemoryTurn] = []
    private(set) var runIDs: [UUID] = []

    func turnCompleted(_ turn: MemoryTurn, runContext: RunContext) async {
        turns.append(turn)
        runIDs.append(runContext.runID)
    }
}

private let sessionEpoch = Date(timeIntervalSince1970: 1_700_000_000)

private func sessionMemory(
    conversation: InMemoryConversationStore,
    observer: (any MemoryTurnObserving)? = nil,
    recordsTurns: Bool = true
) -> MemorySessionConfiguration {
    MemorySessionConfiguration(
        conversation: conversation,
        recordsTurns: recordsTurns,
        observer: observer,
        clock: { sessionEpoch }
    )
}

// MARK: - Tests

@Suite("MemorySession")
struct MemorySessionTests {
    @Test("a session without a memory surface touches no conversation store")
    func memoryNilChangesNothing() async throws {
        let conversation = InMemoryConversationStore()
        let session = CompoundSession(.init(
            assembler: DefaultContextAssembler(baseInstructions: "x"),
            makeModel: { _, _, _ in SessionFakeModel(["hello"]) }
        ))

        let outcome = try await session.respond(to: "hi")
        #expect(outcome.output == "hello")
        let messages = await conversation.messages()
        #expect(messages.isEmpty)
        #expect(session.configuration.memory == nil)
    }

    // MARK: - Optionality

    // The memory layer is additive: `Configuration.memory == nil` must
    // preserve pre-memory behavior exactly. The three tests below pin that
    // as a falsifiable property rather than an assertion in a doc comment,
    // because the failure mode is silent — a memory call added
    // unconditionally to the hot path costs every existing user latency
    // and emits telemetry they never opted into.

    @Test("a memory-free session emits no memory work on any entry point")
    func memoryFreeSessionEmitsNoMemoryWork() async throws {
        let tracer = InMemoryTracer()
        let session = CompoundSession(.init(
            assembler: DefaultContextAssembler(baseInstructions: "x"),
            tracer: tracer,
            makeModel: { _, _, _ in SessionFakeModel(["hello"]) }
        ))

        // Every path the memory work item touched, plus the two it
        // deliberately does not auto-record.
        _ = try await session.respond(to: "hi")
        _ = try await session.respondRouted(to: "hi")
        let run = try await session.stream(userPrompt: "hi")
        for try await _ in run.stream {}
        _ = try await run.outcome.value

        // And a failing attempt, which is the path that records a user
        // turn but no assistant turn when memory IS configured.
        let failing = CompoundSession(.init(
            assembler: DefaultContextAssembler(baseInstructions: "x"),
            tracer: tracer,
            makeModel: { _, _, _ in throw CompoundError.modelUnavailable(reason: "offline") }
        ))
        _ = try? await failing.respond(to: "hi")

        let events = await tracer.events
        #expect(!events.isEmpty, "the tracer must actually have seen the runs")
        for event in events {
            #expect(event.label != "memory.consolidated")
            if case .info(_, let category, _) = event {
                #expect(category != MemoryTrace.category)
            }
        }
    }

    @Test("a memory-free respond traces exactly the pre-memory event sequence")
    func memoryFreeTraceSequenceIsUnchanged() async throws {
        let tracer = InMemoryTracer()
        let session = CompoundSession(.init(
            assembler: DefaultContextAssembler(baseInstructions: "x"),
            tracer: tracer,
            makeModel: { _, _, _ in SessionFakeModel(["hello"]) }
        ))

        _ = try await session.respond(to: "hi")

        // Pinned literally. Any new step on the non-memory path — a store
        // read, a consolidation hand-off, an extra info line — changes
        // this array, which is the point.
        let labels = await tracer.events.map(\.label)
        #expect(labels == ["run.started", "run.ended"])
    }

    @Test("a configured surface with recording off and no observer writes nothing")
    func inertMemorySurfaceWritesNothing() async throws {
        // Opting out *within* memory, as an application that owns its own
        // transcript writes would. The guards must be on `recordsTurns`
        // and on the observer's presence, not merely on `memory == nil`.
        let conversation = InMemoryConversationStore()
        let session = CompoundSession(.init(
            assembler: DefaultContextAssembler(baseInstructions: "x"),
            makeModel: { _, _, _ in SessionFakeModel(["hello"]) },
            memory: sessionMemory(conversation: conversation, observer: nil, recordsTurns: false)
        ))

        let outcome = try await session.respond(to: "hi")
        #expect(outcome.output == "hello")
        #expect(await conversation.messages().isEmpty)
    }

    @Test("one respond records the user turn then the assistant turn and notifies once")
    func respondRecordsBothTurns() async throws {
        let conversation = InMemoryConversationStore()
        let observer = SessionRecordingObserver()
        let session = CompoundSession(.init(
            assembler: DefaultContextAssembler(baseInstructions: "x"),
            makeModel: { _, _, _ in SessionFakeModel(["hello"]) },
            memory: sessionMemory(conversation: conversation, observer: observer)
        ))

        let outcome = try await session.respond(
            to: "hi",
            metadata: [MemorySessionConfiguration.defaultThreadIDMetadataKey: "thread-7"]
        )

        let messages = await conversation.messages()
        #expect(messages.count == 2)
        #expect(messages[0].role == .user)
        #expect(messages[0].content == "hi")
        #expect(messages[1].role == .assistant)
        #expect(messages[1].content == "hello")
        // The injected clock stamps both, so a transcript is reproducible.
        #expect(messages.allSatisfy { $0.createdAt == sessionEpoch })

        let turns = await observer.turns
        #expect(turns.count == 1)
        #expect(turns[0].threadID == "thread-7")
        #expect(turns[0].userMessage.content == "hi")
        #expect(turns[0].assistantMessage.content == "hello")
        #expect(turns[0].recent.isEmpty)
        let runIDs = await observer.runIDs
        #expect(runIDs == [outcome.runID])
    }

    @Test("an absent thread key falls back to the default thread")
    func defaultThreadID() async throws {
        let conversation = InMemoryConversationStore()
        let observer = SessionRecordingObserver()
        let session = CompoundSession(.init(
            assembler: DefaultContextAssembler(baseInstructions: "x"),
            makeModel: { _, _, _ in SessionFakeModel(["ok"]) },
            memory: sessionMemory(conversation: conversation, observer: observer)
        ))

        _ = try await session.respond(to: "hi")
        let turns = await observer.turns
        #expect(turns.first?.threadID == MemorySessionConfiguration.defaultThreadID)
    }

    @Test("a failed run leaves the user turn and notifies nobody")
    func failedRunRecordsUserTurnOnly() async throws {
        let conversation = InMemoryConversationStore()
        let observer = SessionRecordingObserver()
        let session = CompoundSession(.init(
            assembler: DefaultContextAssembler(baseInstructions: "x"),
            makeModel: { _, _, _ in throw CompoundError.modelUnavailable(reason: "offline") },
            memory: sessionMemory(conversation: conversation, observer: observer)
        ))

        await #expect(throws: CompoundError.self) {
            _ = try await session.respond(to: "hi")
        }
        // A failed turn is real history; an unanswered turn is not a
        // consolidation unit.
        let messages = await conversation.messages()
        #expect(messages.count == 1)
        #expect(messages[0].role == .user)
        let turns = await observer.turns
        #expect(turns.isEmpty)
    }

    @Test("a routed call with three rungs still records exactly one turn")
    func routedRecordsOnce() async throws {
        let conversation = InMemoryConversationStore()
        let observer = SessionRecordingObserver()
        let model = SessionFakeModel(["a", "b", "c", "d"])
        let session = CompoundSession(.init(
            assembler: DefaultContextAssembler(baseInstructions: "x"),
            makeModel: { _, _, _ in model },
            routing: RoutingPolicy(
                minConfidence: 0.9,
                escalation: [
                    EscalationStep(label: "one"),
                    EscalationStep(label: "two"),
                    EscalationStep(label: "three"),
                ]
            ),
            memory: sessionMemory(conversation: conversation, observer: observer)
        ))

        let routed = try await session.respondRouted(to: "hi")
        #expect(routed.appliedSteps == ["one", "two", "three"])
        // Four attempts, one recorded exchange: the ladder produced one
        // answer, not one answer per rung.
        let calls = await model.calls
        #expect(calls == 4)
        let messages = await conversation.messages()
        #expect(messages.count == 2)
        #expect(messages[1].content == routed.output)
        let turns = await observer.turns
        #expect(turns.count == 1)
        #expect(turns[0].assistantMessage.content == routed.output)
    }

    @Test("a routed call without a routing policy records exactly once")
    func routedWithoutPolicyRecordsOnce() async throws {
        let conversation = InMemoryConversationStore()
        let observer = SessionRecordingObserver()
        let session = CompoundSession(.init(
            assembler: DefaultContextAssembler(baseInstructions: "x"),
            makeModel: { _, _, _ in SessionFakeModel(["only"]) },
            memory: sessionMemory(conversation: conversation, observer: observer)
        ))

        _ = try await session.respondRouted(to: "hi")
        let messages = await conversation.messages()
        #expect(messages.count == 2)
        let turns = await observer.turns
        #expect(turns.count == 1)
    }

    @Test("recordsTurns off skips the appends but still hands over the turn")
    func recordsTurnsOffStillNotifies() async throws {
        let conversation = InMemoryConversationStore()
        let observer = SessionRecordingObserver()
        let session = CompoundSession(.init(
            assembler: DefaultContextAssembler(baseInstructions: "x"),
            makeModel: { _, _, _ in SessionFakeModel(["hello"]) },
            memory: sessionMemory(conversation: conversation, observer: observer, recordsTurns: false)
        ))

        _ = try await session.respond(to: "hi")
        let messages = await conversation.messages()
        #expect(messages.isEmpty)
        let turns = await observer.turns
        #expect(turns.count == 1)
        #expect(turns[0].userMessage.content == "hi")
    }

    @Test("the user turn is visible to the assembler while the run is assembling")
    func userTurnIsVisibleDuringAssembly() async throws {
        let conversation = InMemoryConversationStore()
        let store = InMemoryFactStore()
        let assembler = MemoryContextAssembler(
            baseInstructions: "x",
            conversation: conversation,
            memory: store,
            coreBlockFactTag: nil,
            clock: { sessionEpoch }
        )
        let model = SessionFakeModel(["done"])
        let session = CompoundSession(.init(
            assembler: assembler,
            makeModel: { _, _, _ in model },
            memory: sessionMemory(conversation: conversation)
        ))

        _ = try await session.respond(to: "remember this")
        // Recording before the attempt is what puts this turn into the
        // transcript the model actually saw.
        let prompts = await model.prompts
        #expect(prompts.count == 1)
        #expect(prompts[0].contains("Conversation so far:"))
        #expect(prompts[0].contains("remember this"))
    }

    @Test("preceding history rides along as bounded turn context")
    func precedingHistoryIsBounded() async throws {
        let conversation = InMemoryConversationStore()
        for i in 0..<20 { await conversation.append(.user("old-\(i)")) }
        let observer = SessionRecordingObserver()
        let session = CompoundSession(.init(
            assembler: DefaultContextAssembler(baseInstructions: "x"),
            makeModel: { _, _, _ in SessionFakeModel(["ok"]) },
            memory: sessionMemory(conversation: conversation, observer: observer)
        ))

        _ = try await session.respond(to: "new")
        let turns = await observer.turns
        let recent = try #require(turns.first?.recent)
        #expect(recent.count == CompoundSession.memoryTurnRecentLimit)
        // The two messages this turn recorded are the turn, not its context.
        #expect(recent.last?.content == "old-19")
    }

    @Test("thread ids resolve identically for the session and the assembler")
    func threadResolutionIsShared() {
        let key = MemorySessionConfiguration.defaultThreadIDMetadataKey
        #expect(MemorySessionConfiguration.threadID(in: [key: "abc"], key: key) == "abc")
        #expect(MemorySessionConfiguration.threadID(in: [:], key: key) == "default")
        let config = MemorySessionConfiguration(conversation: InMemoryConversationStore())
        #expect(config.threadID(in: [key: "xyz"]) == "xyz")
        #expect(config.threadID(in: [:]) == MemorySessionConfiguration.defaultThreadID)
    }
}
