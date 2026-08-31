import Foundation

// A minimal, general-purpose deadline combinator. Anything in the framework
// that needs "run this, but give up after N" — eval cases, tool invocations,
// model calls — should route through `withDeadline` rather than hand-rolling
// its own TaskGroup race.

/// Thrown by ``withDeadline(_:clock:operation:)`` when the deadline elapses
/// before the operation produces a value.
public struct DeadlineExceededError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The deadline that elapsed.
    public let duration: Duration

    /// Creates an error describing an elapsed deadline of `duration`.
    public init(duration: Duration) {
        self.duration = duration
    }

    public var description: String { "deadline of \(duration) exceeded" }
}

/// Races `operation` against a deadline, cancelling the loser.
///
/// Two child tasks run in a task group: one executes `operation`, the other
/// sleeps on `clock` for `duration`. Whichever finishes first wins and the
/// other is cancelled:
///
/// - If `operation` finishes first, its value is returned (or its error is
///   rethrown) and the timer is cancelled.
/// - If the timer fires first, `operation` is cancelled and `onTimeout` is
///   invoked to produce the result — typically it throws a domain-specific
///   error, but it may also return a fallback value.
///
/// Cancellation of the *calling* task propagates into both children, so a
/// cancelled caller surfaces `CancellationError` from `operation` (or from
/// the sleeping timer) rather than waiting out the deadline.
///
/// `operation` must be cooperatively cancellable for the deadline to have
/// teeth: a child task that never suspends nor checks `Task.isCancelled`
/// keeps running in the background even after the timeout result has been
/// returned to the caller.
///
/// - Parameters:
///   - duration: How long `operation` may run before it is cancelled.
///   - clock: Clock the deadline is measured on. Defaults to
///     `ContinuousClock`; inject a test clock to make timeouts deterministic.
///   - onTimeout: Invoked after `operation` has been cancelled because the
///     deadline elapsed. Produces the call's result — return a fallback or
///     throw.
///   - operation: The work to race against the deadline.
/// - Returns: The value produced by `operation`, or by `onTimeout` when the
///   deadline elapsed first.
/// - Throws: Whatever `operation` throws when it finishes (or is cancelled)
///   before the deadline, or whatever `onTimeout` throws after a timeout.
public func withDeadline<T: Sendable>(
    _ duration: Duration,
    clock: some Clock<Duration> = ContinuousClock(),
    onTimeout: @escaping @Sendable () async throws -> T,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await clock.sleep(for: duration, tolerance: nil)
            return nil
        }
        // The first child to finish decides the outcome; cancel the loser.
        // `next()` rethrows if the winner threw (including CancellationError
        // when the calling task was cancelled).
        guard let first = try await group.next() else {
            // Unreachable: the group always holds two children.
            group.cancelAll()
            return try await onTimeout()
        }
        group.cancelAll()
        if let value = first {
            return value
        }
        return try await onTimeout()
    }
}

/// Races `operation` against a deadline, throwing ``DeadlineExceededError``
/// on timeout.
///
/// Convenience over ``withDeadline(_:clock:onTimeout:operation:)`` for the
/// common case where a timeout is simply an error.
///
/// - Parameters:
///   - duration: How long `operation` may run before it is cancelled.
///   - clock: Clock the deadline is measured on.
///   - operation: The work to race against the deadline.
/// - Returns: The value produced by `operation`.
/// - Throws: ``DeadlineExceededError`` if the deadline elapses first,
///   otherwise whatever `operation` throws.
public func withDeadline<T: Sendable>(
    _ duration: Duration,
    clock: some Clock<Duration> = ContinuousClock(),
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withDeadline(
        duration,
        clock: clock,
        onTimeout: { throw DeadlineExceededError(duration: duration) },
        operation: operation
    )
}
