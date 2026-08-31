import Foundation
import FoundationModels

/// Successful result of ``StreamingControlLoop/run(prompt:modelClient:runContext:)``.
public struct StreamingLoopOutcome: Sendable {
    /// Final accumulated output that passed every chain member.
    public let final: String
    /// Resource accounting at run completion.
    public let usage: BudgetUsage
    /// Identifier from the originating ``RunContext``.
    public let runID: UUID
}

/// Streaming variant of ``ControlLoop``. The propose-and-check cycle is
/// unchanged, but model output is exposed token-by-token to the caller
/// while the loop is running. Verification still happens on the complete
/// output once a turn finishes — correctness is preserved by gating on
/// the final aggregate, not on partial chunks.
public struct StreamingControlLoop: Sendable {
    /// Per-run resource caps.
    public let budget: Budget
    /// Cheapest-first verifier chain applied to every completed turn.
    public let outputVerifier: VerifierChain<String>
    /// Generation options passed to the model.
    public let generationOptions: GenerationOptions
    /// Buffer cap for the run's ``ProgressEvent`` stream.
    public let eventBufferLimit: Int
    /// Builds the next prompt when a turn fails verification. The default
    /// (``RepairPromptBuilder/default``) rebuilds a self-contained prompt —
    /// original task, byte-capped failed output, every diagnostic — which
    /// is required for stateless ``ModelStreaming`` conformers; stateful
    /// conformers may use ``RepairPromptBuilder/diagnosticOnly``.
    public let repairPromptBuilder: RepairPromptBuilder

    /// Default upper bound on buffered ``ProgressEvent``s before back-pressure
    /// drops the oldest entry.
    public static let defaultEventBufferLimit: Int = 256

    /// Creates a streaming control loop.
    public init(
        budget: Budget = .default,
        outputVerifier: VerifierChain<String> = .empty(),
        generationOptions: GenerationOptions = GenerationOptions(),
        eventBufferLimit: Int = StreamingControlLoop.defaultEventBufferLimit,
        repairPromptBuilder: RepairPromptBuilder = .default
    ) {
        self.budget = budget
        self.outputVerifier = outputVerifier
        self.generationOptions = generationOptions
        self.eventBufferLimit = max(1, eventBufferLimit)
        self.repairPromptBuilder = repairPromptBuilder
    }

    /// Handle returned by ``StreamingControlLoop/run(prompt:modelClient:runContext:)``.
    /// ``stream`` yields every ``ProgressEvent`` from the run; ``outcome``
    /// resolves to the final result. Cancelling either cancels the other.
    public struct Run: Sendable {
        /// Per-event progress stream.
        public let stream: AsyncThrowingStream<ProgressEvent, Error>
        /// Eventual run outcome.
        public let outcome: Task<StreamingLoopOutcome, Error>
    }

    /// Begins a streaming run. Returns immediately with a ``Run`` whose
    /// stream and outcome track progress and completion.
    ///
    /// - Parameters:
    ///   - prompt: The user prompt.
    ///   - modelClient: Any ``ModelStreaming`` adapter.
    ///   - runContext: Shared run context.
    /// - Returns: A ``Run`` for observing progress and awaiting outcome.
    public func run(
        prompt: String,
        modelClient: any ModelStreaming,
        runContext: RunContext
    ) -> Run {
        let (eventStream, eventCont) = AsyncThrowingStream<ProgressEvent, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(eventBufferLimit)
        )
        let core = LoopCore(
            budget: budget,
            outputVerifier: outputVerifier,
            repairPromptBuilder: repairPromptBuilder
        ) { event in
            _ = eventCont.yield(event)
        }
        let budget = self.budget
        let generationOptions = self.generationOptions

        let task = Task<StreamingLoopOutcome, Error> {
            var usage = BudgetUsage()
            let started = ContinuousClock.now

            await runContext.tracer.record(
                .runStarted(runID: runContext.runID, prompt: prompt, budget: budget, auth: runContext.auth.principal)
            )
            eventCont.yield(.runStarted(runID: runContext.runID))

            var nextPrompt = prompt

            do {
                while true {
                    try await core.beginTurn(usage: &usage, started: started, runContext: runContext)

                    let streamingResult = await modelClient.stream(to: nextPrompt, options: generationOptions)

                    // The chunk loop races a watchdog so an in-flight turn is
                    // bounded even while awaiting the next chunk: the watchdog
                    // trips on time-to-first-chunk (Budget.firstToken), on the
                    // gap between chunks (Budget.interChunkGap), and on the
                    // run's cumulative wall clock. The consumer itself still
                    // cuts the turn off the moment the output-token budget is
                    // breached mid-stream.
                    let progress = StreamProgress(startedAt: ContinuousClock.now)
                    let wallDeadline = started + budget.wallClock
                    let turnNumber = usage.turns
                    let priorTokens = usage.outputTokens
                    let tokenCap = budget.maxTotalOutputTokens
                    let firstToken = budget.firstToken
                    let interChunkGap = budget.interChunkGap
                    let stream = streamingResult.stream

                    let race: ChunkRace
                    do {
                        race = try await withThrowingTaskGroup(of: ChunkRace.self) { group in
                            group.addTask {
                                var turnTokens = 0
                                for try await chunk in stream {
                                    try Task.checkCancellation()
                                    await progress.record(chunk)
                                    eventCont.yield(.modelStreamChunk(turn: turnNumber, content: chunk))
                                    if let tokenCap {
                                        turnTokens += Budget.approximateTokens(chunk)
                                        if priorTokens + turnTokens >= tokenCap {
                                            return .consumed(tokenCapTripped: true, turnTokens: turnTokens)
                                        }
                                    }
                                }
                                return .consumed(tokenCapTripped: false, turnTokens: turnTokens)
                            }
                            group.addTask {
                                // Watchdog: sleep until the earliest active
                                // deadline, then re-check against fresh chunk
                                // state — a chunk that arrived mid-sleep pushes
                                // the gap deadline forward, so a trip is only
                                // declared when a freshly computed deadline has
                                // genuinely passed.
                                let clock = ContinuousClock()
                                while true {
                                    let state = await progress.state
                                    var earliest = (instant: wallDeadline, stall: BudgetExhaustion.wallClock)
                                    if state.chunkCount == 0 {
                                        if let firstToken {
                                            let d = state.startedAt.advanced(by: firstToken)
                                            if d < earliest.instant { earliest = (d, .firstToken) }
                                        }
                                    } else if let interChunkGap {
                                        let d = state.lastChunkAt.advanced(by: interChunkGap)
                                        if d < earliest.instant { earliest = (d, .interChunkGap) }
                                    }
                                    if clock.now >= earliest.instant {
                                        return .stalled(earliest.stall)
                                    }
                                    // The first chunk's arrival *activates* the
                                    // gap deadline, which can be much earlier
                                    // than whatever is active right now — so
                                    // while no chunk has arrived, never sleep
                                    // past one gap length (a gap trip can never
                                    // fire earlier than now + interChunkGap).
                                    var wake = earliest.instant
                                    if state.chunkCount == 0, let interChunkGap {
                                        let horizon = clock.now.advanced(by: interChunkGap)
                                        if horizon < wake { wake = horizon }
                                    }
                                    try await clock.sleep(until: wake, tolerance: nil)
                                }
                            }
                            // First child to finish decides the turn; the
                            // loser is cancelled (a throw out of the group
                            // cancels the survivor too).
                            guard let first = try await group.next() else {
                                group.cancelAll()
                                return .consumed(tokenCapTripped: false, turnTokens: 0)
                            }
                            group.cancelAll()
                            return first
                        }
                    } catch {
                        streamingResult.final.cancel()
                        _ = try? await streamingResult.final.value
                        let mapped = await core.modelFailure(error, usage: usage, runContext: runContext)
                        eventCont.finish(throwing: mapped)
                        throw mapped
                    }

                    switch race {
                    case .consumed(tokenCapTripped: true, turnTokens: let turnTokens):
                        // Enforce the cap deterministically. The breach was
                        // measured on chunks actually received, so the run
                        // fails regardless of whether the model's final task
                        // observed the cancellation or had already finished
                        // producing (its yields buffer ahead of consumption).
                        streamingResult.final.cancel()
                        _ = try? await streamingResult.final.value
                        usage.recordOutputTokens(turnTokens)
                        throw await core.exhausted(.outputTokens, usage: usage, runContext: runContext)

                    case .stalled(let stall):
                        // Mid-stream timeout. Deliberately no await on the
                        // stalled final task — it may never resolve. Salvage:
                        // non-empty partial output that passes the full
                        // verifier chain completes the run; anything else is
                        // a budget exhaustion on the tripped dimension.
                        streamingResult.final.cancel()
                        usage.recordElapsed(ContinuousClock.now - started)
                        let partial = await progress.text
                        if !partial.isEmpty {
                            usage.recordOutputTokens(Budget.approximateTokens(partial))
                            if await core.salvage(partial: partial, usage: usage, runContext: runContext) {
                                eventCont.finish()
                                return StreamingLoopOutcome(final: partial, usage: usage, runID: runContext.runID)
                            }
                        }
                        throw await core.exhausted(stall, usage: usage, runContext: runContext)

                    case .consumed(tokenCapTripped: false, turnTokens: _):
                        break
                    }

                    // The chunk stream ended; the final task normally resolves
                    // immediately, but it too is capped at the remaining wall
                    // clock so a transport whose final never settles cannot
                    // hang the run.
                    usage.recordElapsed(ContinuousClock.now - started)
                    let remainingWall = budget.wallClock - usage.elapsed
                    guard remainingWall > .zero else {
                        streamingResult.final.cancel()
                        throw await core.exhausted(.wallClock, usage: usage, runContext: runContext)
                    }
                    let output: String
                    do {
                        let final = streamingResult.final
                        // Awaiting Task.value is not itself responsive to the
                        // waiter's cancellation, so on deadline expiry the
                        // cancellation handler cancels the final task directly
                        // — a cooperative transport then settles promptly
                        // instead of pinning the deadline's task group open.
                        output = try await withDeadline(remainingWall) {
                            try await withTaskCancellationHandler {
                                try await final.value
                            } onCancel: {
                                final.cancel()
                            }
                        }
                    } catch is DeadlineExceededError {
                        streamingResult.final.cancel()
                        usage.recordElapsed(ContinuousClock.now - started)
                        throw await core.exhausted(.wallClock, usage: usage, runContext: runContext)
                    } catch {
                        let mapped = await core.modelFailure(error, usage: usage, runContext: runContext)
                        eventCont.finish(throwing: mapped)
                        throw mapped
                    }
                    try Task.checkCancellation()
                    usage.recordOutputTokens(Budget.approximateTokens(output))
                    eventCont.yield(.modelTurnCompleted(turn: usage.turns, content: output))

                    switch try await core.settle(
                        output: output,
                        originalTask: prompt,
                        usage: &usage,
                        started: started,
                        runContext: runContext
                    ) {
                    case .done(let final):
                        eventCont.finish()
                        return StreamingLoopOutcome(final: final, usage: usage, runID: runContext.runID)
                    case .repair(let next):
                        nextPrompt = next
                    }
                }
            } catch let error as CompoundError {
                // LoopCore already emitted runCompleted(success: false) for the
                // budget exhaustion and terminal verdicts it produces; transport
                // paths finished the continuation at their throw site. finish()
                // is idempotent, so both cases are safe here.
                eventCont.finish()
                throw error
            } catch {
                eventCont.finish(throwing: error)
                throw error
            }
        }

        eventCont.onTermination = { _ in task.cancel() }
        return Run(stream: eventStream, outcome: task)
    }
}

/// Outcome of racing the chunk-consumption loop against the stall watchdog
/// for one streaming turn.
private enum ChunkRace: Sendable {
    /// The chunk stream ended (or the mid-stream token cap tripped) before
    /// any deadline fired. `turnTokens` is the running per-chunk token
    /// estimate for the turn (tracked only when a cap is set).
    case consumed(tokenCapTripped: Bool, turnTokens: Int)
    /// The watchdog fired first: `.firstToken`, `.interChunkGap`, or
    /// `.wallClock`, whichever deadline was breached.
    case stalled(BudgetExhaustion)
}

/// Per-turn chunk accounting shared between the consumer and the watchdog.
/// Accumulates the partial text so a stalled turn can be salvaged, and
/// timestamps each chunk so gap deadlines are computed from fresh state.
private actor StreamProgress {
    /// Concatenated chunks received so far.
    private(set) var text = ""
    private var chunkCount = 0
    private let startedAt: ContinuousClock.Instant
    private var lastChunkAt: ContinuousClock.Instant

    init(startedAt: ContinuousClock.Instant) {
        self.startedAt = startedAt
        self.lastChunkAt = startedAt
    }

    /// Appends a received chunk and stamps its arrival time.
    func record(_ chunk: String) {
        text += chunk
        chunkCount += 1
        lastChunkAt = ContinuousClock.now
    }

    /// Snapshot for the watchdog's deadline computation.
    var state: (chunkCount: Int, startedAt: ContinuousClock.Instant, lastChunkAt: ContinuousClock.Instant) {
        (chunkCount, startedAt, lastChunkAt)
    }
}
