import Foundation

#if canImport(BackgroundTasks) && (os(iOS) || os(tvOS) || os(visionOS))
import BackgroundTasks
#endif

/// Terminal outcome of one background activity run.
///
/// Mirrors `NSBackgroundActivityScheduler.Result` so the macOS scheduler
/// path is a direct translation, and doubles as the iOS-family
/// `setTaskCompleted(success:)` value (`.finished` is success).
public enum BackgroundActivityCompletion: String, Sendable, Equatable {
    /// The body ran to completion without cancellation.
    case finished
    /// The body threw, was cancelled, or the scheduler asked the activity
    /// to wind down. The scheduler should retry later.
    case deferred
}

/// Minimal seam over a scheduler's "please wind down" signal.
///
/// `NSBackgroundActivityScheduler.shouldDefer` is the only supported way to
/// learn that macOS wants the activity's slot back, and it is a poll — there
/// is no callback. Reading it through this protocol keeps the deferral and
/// cancellation contract testable off-device with a fake.
public protocol BackgroundDeferralSource: Sendable {
    /// `true` once the scheduler has asked the activity to stop, or once the
    /// scheduler is no longer alive to ask.
    var shouldDefer: Bool { get }
}

/// A deferral source that never asks the activity to wind down. Used when a
/// run has no scheduler behind it (`runNow`, tests, manual invocation).
public struct NullDeferralSource: BackgroundDeferralSource {
    public init() {}
    public var shouldDefer: Bool { false }
}

/// A compound run packaged for the platform's background scheduler.
///
/// On iOS-family platforms (iOS, iPadOS, tvOS, visionOS) this wraps Apple's
/// `BGTaskScheduler` — register the activity at app launch with
/// ``registerWithBGTaskScheduler()``, then ``submit(earliestBegin:requiresNetworkConnectivity:requiresExternalPower:)``
/// from anywhere in your app. On macOS this wraps
/// `NSBackgroundActivityScheduler` via ``scheduleAsBackgroundActivity(interval:repeats:tolerance:qualityOfService:)``.
///
/// The activity owns the cancellation contract on both platforms: when the
/// system signals expiration (iOS) or asks the activity to defer (macOS),
/// the in-flight `Task` is cancelled, the compound loop's cooperative
/// cancellation kicks in, and the outcome is reported exactly once via a
/// single completion path. ``run(deferral:pollInterval:)`` is the shared
/// core both scheduler paths funnel through.
public struct BackgroundCompoundActivity: Sendable {
    /// The reverse-DNS identifier registered with the platform scheduler.
    /// Must match an entry in the app's `Info.plist`
    /// `BGTaskSchedulerPermittedIdentifiers` list on iOS-family platforms.
    public let identifier: String

    private let perform: @Sendable () async throws -> Void

    /// Construct an activity that runs a single `CompoundSession.respond`
    /// call when invoked, then hands the resulting outcome to a callback.
    public init(
        identifier: String,
        session: CompoundSession,
        prompt: String,
        auth: AuthContext = .anonymous,
        metadata: [String: String] = [:],
        onResult: @escaping @Sendable (LoopOutcome) async -> Void
    ) {
        self.identifier = identifier
        self.perform = {
            let outcome = try await session.respond(
                to: prompt,
                auth: auth,
                progress: NullProgressReporter(),
                metadata: metadata
            )
            await onResult(outcome)
        }
    }

    /// Construct an activity that runs an arbitrary `body` closure. Use this
    /// for multi-step background work — periodic eval suite runs, RAG index
    /// refreshes, scheduled diagnostic flushes.
    public init(
        identifier: String,
        body: @escaping @Sendable () async throws -> Void
    ) {
        self.identifier = identifier
        self.perform = body
    }

    /// Run the activity directly without going through a scheduler. Useful
    /// for testing the activity's body in isolation.
    public func runNow() async throws {
        try await perform()
    }

    /// Run the activity's body once and map the result onto a completion
    /// outcome. Cancellation — thrown or observed cooperatively — and any
    /// other error resolve to ``BackgroundActivityCompletion/deferred`` so
    /// the scheduler retries the work later.
    ///
    /// This is the single result-mapping path both platform schedulers use.
    public func runToCompletion() async -> BackgroundActivityCompletion {
        do {
            try await perform()
            return Task.isCancelled ? .deferred : .finished
        } catch {
            return .deferred
        }
    }

    /// Run the activity's body while honoring a scheduler's deferral signal.
    ///
    /// The body runs in its own `Task`, held so it can be cancelled. A poller
    /// samples `deferral.shouldDefer` every `pollInterval`; the moment the
    /// scheduler asks the activity to wind down — or the scheduler goes away
    /// entirely — the work `Task` is cancelled. Cancellation of the *calling*
    /// task is forwarded the same way. Because the control loop is
    /// cancellation-correct, the in-flight `RunContext` observes the
    /// cancellation and unwinds rather than running past its slot.
    ///
    /// A scheduler that is already deferring when the run starts short-circuits
    /// to ``BackgroundActivityCompletion/deferred`` without invoking the body.
    public func run(
        deferral: some BackgroundDeferralSource,
        pollInterval: Duration = .milliseconds(200)
    ) async -> BackgroundActivityCompletion {
        if deferral.shouldDefer { return .deferred }

        let box = WorkBox()
        let work = Task<BackgroundActivityCompletion, Never> {
            await self.runToCompletion()
        }
        box.set { work.cancel() }

        let poller = Task<Void, Never> {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: pollInterval)
                } catch {
                    return  // poller cancelled: work already resolved
                }
                if deferral.shouldDefer {
                    box.cancel()
                    return
                }
            }
        }

        let outcome = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            box.cancel()
        }
        poller.cancel()
        return outcome
    }

    #if canImport(BackgroundTasks) && (os(iOS) || os(tvOS) || os(visionOS))
    /// Register the activity with `BGTaskScheduler.shared`. Call once at
    /// app launch (typically from a SwiftUI `App` `init` or the App
    /// Delegate's `application(_:didFinishLaunchingWithOptions:)`).
    ///
    /// Wiring matches Apple's documented order: install the expiration
    /// handler before starting work, do the work inside a single
    /// `Task` whose `value` we always await, and report completion exactly
    /// once. On expiration the work `Task` is cancelled, the cooperative
    /// `CancellationError` propagates up, and the same await path reports
    /// `setTaskCompleted(success: false)`.
    @discardableResult
    public func registerWithBGTaskScheduler() -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { systemTask in
            // Single completion gate: whichever path resolves first wins,
            // and `setTaskCompleted` is called exactly once.
            let completion = TaskCompletionGate(systemTask: systemTask)

            // Install the expiration handler BEFORE spawning work so the
            // system has a valid hook before any await suspension. The
            // handler cancels `work` (cooperative cancellation surfaces
            // as `CancellationError` inside `perform`) and also marks
            // the task complete directly — if `work` never gets a chance
            // to run, the gate still resolves exactly once.
            let workBox = WorkBox()
            systemTask.expirationHandler = {
                workBox.cancel()
                completion.complete(success: false)
            }

            let work = Task<Void, Never> {
                let outcome = await self.runToCompletion()
                completion.complete(success: outcome == .finished)
            }
            workBox.set { work.cancel() }
        }
    }

    /// Submit a `BGProcessingTaskRequest` for this identifier. Defaults
    /// match what most Compound use cases want: no network requirement,
    /// no external-power requirement, no earliest-begin date.
    public func submit(
        earliestBegin: TimeInterval? = nil,
        requiresNetworkConnectivity: Bool = false,
        requiresExternalPower: Bool = false
    ) throws {
        let request = BGProcessingTaskRequest(identifier: identifier)
        if let earliestBegin {
            request.earliestBeginDate = Date(timeIntervalSinceNow: earliestBegin)
        }
        request.requiresNetworkConnectivity = requiresNetworkConnectivity
        request.requiresExternalPower = requiresExternalPower
        try BGTaskScheduler.shared.submit(request)
    }

    /// Submit a `BGAppRefreshTaskRequest` for this identifier — short-form
    /// background refresh, capped at around 30 seconds by the system.
    public func submitRefresh(earliestBegin: TimeInterval? = nil) throws {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        if let earliestBegin {
            request.earliestBeginDate = Date(timeIntervalSinceNow: earliestBegin)
        }
        try BGTaskScheduler.shared.submit(request)
    }
    #endif

    #if os(macOS)
    /// Schedule this activity as a repeating `NSBackgroundActivityScheduler`.
    /// The returned scheduler is retained for you to invalidate later
    /// (`scheduler.invalidate()`).
    ///
    /// The scheduler reclaims the activity's slot if work runs beyond its
    /// allotted window — short tasks are budgeted around 30 seconds, but
    /// the exact deadline depends on system power and thermal state. It
    /// announces this by flipping `shouldDefer`, which is a poll rather than
    /// a callback, so the run samples it at cooperative checkpoints via
    /// ``run(deferral:pollInterval:)`` and cancels the work `Task` as soon as
    /// it goes true — the same contract the iOS expiration handler provides.
    /// Invalidating the scheduler drops the last strong reference the block
    /// holds, which the deferral source also reads as "wind down".
    ///
    /// Throws, cancellation, and deferral all resolve to `.deferred`, which
    /// asks the scheduler to retry; clean completion resolves to `.finished`.
    /// Completion is reported exactly once via the structured `await` path.
    @discardableResult
    public func scheduleAsBackgroundActivity(
        interval: TimeInterval,
        repeats: Bool = true,
        tolerance: TimeInterval = 60,
        qualityOfService: QualityOfService = .background,
        deferralPollInterval: Duration = .milliseconds(200)
    ) -> NSBackgroundActivityScheduler {
        let scheduler = NSBackgroundActivityScheduler(identifier: identifier)
        scheduler.interval = interval
        scheduler.repeats = repeats
        scheduler.tolerance = tolerance
        scheduler.qualityOfService = qualityOfService
        // The source holds the scheduler weakly: the scheduler retains this
        // block, so a strong capture would be a cycle — and a deallocated
        // scheduler is exactly the "activity was invalidated" case the
        // source reports as deferring. Built outside the block so only the
        // `Sendable` source, never the scheduler, is captured.
        let deferral = SchedulerDeferralSource(scheduler: scheduler)
        scheduler.schedule { completion in
            Task {
                let outcome = await self.run(
                    deferral: deferral,
                    pollInterval: deferralPollInterval
                )
                completion(outcome == .finished ? .finished : .deferred)
            }
        }
        return scheduler
    }
    #endif
}

/// Holds the work `Task`'s cancel handle so a signal that arrives before —
/// or independently of — the task's own scope can cancel it: the iOS
/// expiration handler is installed before the task is spawned, and the macOS
/// deferral poller lives beside it. Callers capture the box, not the task,
/// which breaks the ordering dependency; a `cancel()` that lands before
/// `set(_:)` is remembered and applied on registration.
/// `@unchecked` because mutable state is guarded by `lock` (NSLock).
final class WorkBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelWork: (@Sendable () -> Void)?
    private var cancelled = false

    func set(_ cancel: @escaping @Sendable () -> Void) {
        lock.lock()
        if cancelled {
            lock.unlock()
            cancel()
            return
        }
        cancelWork = cancel
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        if cancelled {
            lock.unlock()
            return
        }
        cancelled = true
        let cancelWork = self.cancelWork
        self.cancelWork = nil
        lock.unlock()
        cancelWork?()
    }
}

#if os(macOS)
/// Reads deferral state from a live `NSBackgroundActivityScheduler`. Held
/// weakly so the scheduler's own retain of the work block is not a cycle; a
/// scheduler that has been deallocated (or invalidated and released) counts
/// as deferring, which is the safe direction — the activity winds down.
/// `@unchecked` because the reference is only ever read, never mutated.
struct SchedulerDeferralSource: BackgroundDeferralSource, @unchecked Sendable {
    weak var scheduler: NSBackgroundActivityScheduler?

    var shouldDefer: Bool { scheduler?.shouldDefer ?? true }
}
#endif

#if canImport(BackgroundTasks) && (os(iOS) || os(tvOS) || os(visionOS))
/// Single-shot gate that guarantees `setTaskCompleted(success:)` runs
/// exactly once regardless of which path (normal completion vs.
/// expiration) reaches it first. Uses a plain lock because `BGTask`
/// is not `Sendable` and cannot cross an actor boundary.
/// `@unchecked` because mutable state is guarded by `lock` (NSLock).
private final class TaskCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let systemTask: BGTask

    init(systemTask: BGTask) {
        self.systemTask = systemTask
    }

    func complete(success: Bool) {
        lock.lock()
        if done {
            lock.unlock()
            return
        }
        done = true
        lock.unlock()
        systemTask.setTaskCompleted(success: success)
    }
}
#endif

