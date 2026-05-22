import Foundation

#if canImport(BackgroundTasks) && (os(iOS) || os(tvOS) || os(visionOS))
import BackgroundTasks
#endif

/// Work that survives the app being closed. A compound run packaged for the
/// platform's background scheduler, so the hard things keep happening when no
/// one is watching the screen.
///
/// On iOS-family platforms (iOS, iPadOS, tvOS, visionOS) this wraps Apple's
/// `BGTaskScheduler` — register the activity at app launch with
/// ``registerWithBGTaskScheduler()``, then ``submit(earliestBegin:requiresNetworkConnectivity:requiresExternalPower:)``
/// from anywhere in your app. On macOS this wraps
/// `NSBackgroundActivityScheduler` via ``scheduleAsBackgroundActivity(interval:repeats:tolerance:qualityOfService:)``.
///
/// The activity owns the cancellation contract: when the system signals
/// expiration, the in-flight `Task` is cancelled, the compound loop's
/// cooperative cancellation kicks in, and `setTaskCompleted(success:)` is
/// reported with the appropriate outcome via a single completion path.
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
                let success: Bool
                do {
                    try await self.perform()
                    success = !Task.isCancelled
                } catch is CancellationError {
                    success = false
                } catch {
                    success = false
                }
                completion.complete(success: success)
            }
            workBox.set(work)
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
    /// the exact deadline depends on system power and thermal state.
    /// Throws or cancellation resolve to `.deferred`, which asks the
    /// scheduler to retry; clean completion resolves to `.finished`.
    /// Completion is reported exactly once via the structured `await`
    /// path below.
    @discardableResult
    public func scheduleAsBackgroundActivity(
        interval: TimeInterval,
        repeats: Bool = true,
        tolerance: TimeInterval = 60,
        qualityOfService: QualityOfService = .background
    ) -> NSBackgroundActivityScheduler {
        let scheduler = NSBackgroundActivityScheduler(identifier: identifier)
        scheduler.interval = interval
        scheduler.repeats = repeats
        scheduler.tolerance = tolerance
        scheduler.qualityOfService = qualityOfService
        scheduler.schedule { completion in
            // The scheduler holds the activity slot until `completion` is
            // invoked, so a single-path await is sufficient: any thrown
            // error (including cooperative cancellation) maps to
            // `.deferred` so the scheduler retries.
            Task {
                do {
                    try await self.perform()
                    completion(.finished)
                } catch is CancellationError {
                    completion(.deferred)
                } catch {
                    completion(.deferred)
                }
            }
        }
        return scheduler
    }
    #endif
}

#if canImport(BackgroundTasks) && (os(iOS) || os(tvOS) || os(visionOS))
/// A box that holds the work `Task` so the expiration handler — installed
/// before the task even exists — can still reach in and cancel it. The
/// handler captures the box, not the task, which is what breaks the ordering
/// dependency cleanly. `@unchecked` because mutable state is guarded by
/// `lock` (NSLock).
private final class WorkBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func set(_ task: Task<Void, Never>) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let t = task
        lock.unlock()
        t?.cancel()
    }
}

/// A single-shot gate that guarantees `setTaskCompleted(success:)` fires
/// exactly once, no matter which path — clean completion or expiration —
/// gets there first. Two completions is a bug the OS punishes; this makes
/// it impossible. Uses a plain lock because `BGTask` is not `Sendable` and
/// cannot cross an actor boundary. `@unchecked` because mutable state is
/// guarded by `lock` (NSLock).
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

