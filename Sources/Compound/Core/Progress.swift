import Foundation

/// High-frequency, UI-facing notification emitted by the control loop and
/// model client during a run. Separate from ``TraceEvent``: traces are
/// structured-log diagnostics for operators and audits, whereas progress
/// is the live signal a SwiftUI view binds to. Both are emitted in
/// parallel — neither replaces the other.
public enum ProgressEvent: Sendable {
    /// Emitted once at the start of a run.
    case runStarted(runID: UUID)
    /// Emitted at the start of each model turn (1-based).
    case turnStarted(turn: Int)
    /// A delta chunk of streamed model output.
    case modelStreamChunk(turn: Int, content: String)
    /// Final accumulated content for a turn once streaming finishes.
    case modelTurnCompleted(turn: Int, content: String)
    /// Emitted before a verifier runs.
    case verifierStarted(name: String, cost: VerifierCost)
    /// Emitted after a verifier returns a verdict.
    case verifierCompleted(name: String, verdict: Verdict)
    /// A repair turn was scheduled in response to a `.repair` verdict.
    case repairScheduled(attempt: Int, diagnostic: Diagnostic)
    /// A tool was requested by the model.
    case toolInvocationRequested(name: String)
    /// A tool invocation finished, with the outcome.
    case toolInvocationCompleted(name: String, succeeded: Bool)
    /// Emitted once at the end of a run.
    case runCompleted(success: Bool)
}

/// Sink for ``ProgressEvent`` values. Implementations should be cheap and
/// non-blocking; the control loop emits progress on the critical path.
public protocol ProgressReporter: Sendable {
    /// Records a progress event. Implementations may buffer, fan out, or
    /// discard at will.
    func report(_ event: ProgressEvent) async
}

/// A no-op ``ProgressReporter``; the default in ``RunContext``.
public struct NullProgressReporter: ProgressReporter {
    /// Creates an instance.
    public init() {}
    /// Drops the event.
    public func report(_: ProgressEvent) async {}
}

/// Buffered reporter useful in unit tests: events accumulate in arrival
/// order and can be inspected via ``snapshot()``.
public actor RecordingProgressReporter: ProgressReporter {
    /// Events captured so far, in order.
    public private(set) var events: [ProgressEvent] = []
    /// Creates an empty recorder.
    public init() {}
    /// Appends the event to ``events``.
    public func report(_ event: ProgressEvent) async {
        events.append(event)
    }
    /// Returns a copy of the recorded events.
    public func snapshot() -> [ProgressEvent] { events }
    /// Discards all recorded events.
    public func clear() { events.removeAll() }
}

/// Stream-based reporter for SwiftUI. ``subscribe()`` returns an
/// `AsyncStream` and every ``report(_:)`` fans the event out to all live
/// subscribers. Subscribers are cleaned up on cancellation.
///
/// # Example
/// ```swift
/// let reporter = StreamingProgressReporter()
/// let stream = await reporter.subscribe()
/// Task {
///     for await event in stream { handle(event) }
/// }
/// ```
public actor StreamingProgressReporter: ProgressReporter {
    private var continuations: [UUID: AsyncStream<ProgressEvent>.Continuation] = [:]
    /// Per-subscriber buffer cap before back-pressure drops the oldest entry.
    public let bufferLimit: Int

    /// Default upper bound on buffered ``ProgressEvent``s per subscriber before
    /// back-pressure drops the oldest entry.
    public static let defaultBufferLimit: Int = 256

    /// Creates a reporter with the supplied per-subscriber buffer limit.
    /// Values below 1 are clamped to 1.
    public init(bufferLimit: Int = StreamingProgressReporter.defaultBufferLimit) {
        self.bufferLimit = max(1, bufferLimit)
    }

    /// Registers a new subscriber synchronously within the actor before
    /// returning its stream. The previous non-async variant spawned the
    /// registration in a child task which raced consumer cancellation; this
    /// shape guarantees the subscriber is in the fan-out map before any
    /// caller can possibly drop the stream.
    public func subscribe() async -> AsyncStream<ProgressEvent> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: ProgressEvent.self,
            bufferingPolicy: .bufferingNewest(bufferLimit)
        )
        let id = UUID()
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.remove(id: id) }
        }
        return stream
    }

    /// Fans `event` out to every live subscriber.
    public func report(_ event: ProgressEvent) async {
        for c in continuations.values { c.yield(event) }
    }

    /// Finishes every subscriber's stream and clears the subscriber list.
    public func finishAll() {
        for c in continuations.values { c.finish() }
        continuations.removeAll()
    }

    private func remove(id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
