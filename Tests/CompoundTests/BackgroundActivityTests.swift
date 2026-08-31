import Foundation
import Testing
@testable import Compound

/// Fake scheduler seam: `shouldDefer` starts false and flips on demand, so
/// the macOS deferral contract can be exercised off-device.
/// `@unchecked` because the flag is guarded by `lock` (NSLock).
final class FakeDeferralSource: BackgroundDeferralSource, @unchecked Sendable {
    private let lock = NSLock()
    private var deferring: Bool

    init(deferring: Bool = false) { self.deferring = deferring }

    var shouldDefer: Bool {
        lock.lock()
        defer { lock.unlock() }
        return deferring
    }

    func requestDefer() {
        lock.lock()
        deferring = true
        lock.unlock()
    }
}

@Suite("BackgroundActivity")
struct BackgroundActivityTests {
    @Test("activity runNow invokes the body")
    func runNowInvokesBody() async throws {
        actor Flag { var fired = false; func set() { fired = true } }
        let flag = Flag()
        let activity = BackgroundCompoundActivity(identifier: "test.activity") {
            await flag.set()
        }
        try await activity.runNow()
        let fired = await flag.fired
        #expect(fired)
    }

    @Test("activity propagates errors thrown by the body")
    func propagatesErrors() async throws {
        struct E: Error {}
        let activity = BackgroundCompoundActivity(identifier: "test.activity.error") {
            throw E()
        }
        await #expect(throws: E.self) {
            try await activity.runNow()
        }
    }

    @Test("activity identifier is preserved")
    func identifierPreserved() {
        let activity = BackgroundCompoundActivity(identifier: "com.example.refresh") {}
        #expect(activity.identifier == "com.example.refresh")
    }

    @Test("activity body observes cancellation cooperatively")
    func observesCancellation() async throws {
        actor State {
            var sawCancel = false
            var completed = false
            func cancel() { sawCancel = true }
            func complete() { completed = true }
        }
        let state = State()
        let activity = BackgroundCompoundActivity(identifier: "test.activity.cancel") {
            do {
                try await Task.sleep(for: .seconds(60))
                await state.complete()
            } catch is CancellationError {
                await state.cancel()
                throw CancellationError()
            }
        }
        let task = Task<Bool, Never> {
            do {
                try await activity.runNow()
                return true
            } catch {
                return false
            }
        }
        try await Task.sleep(for: .milliseconds(10))
        task.cancel()
        let succeeded = await task.value
        let sawCancel = await state.sawCancel
        let completed = await state.completed
        #expect(!succeeded)
        #expect(sawCancel)
        #expect(!completed)
    }

    @Test("run under a never-deferring scheduler finishes and runs the body")
    func runFinishesWithoutDeferral() async {
        actor Flag { var fired = false; func set() { fired = true } }
        let flag = Flag()
        let activity = BackgroundCompoundActivity(identifier: "test.activity.finish") {
            await flag.set()
        }
        let outcome = await activity.run(deferral: NullDeferralSource())
        #expect(outcome == .finished)
        let fired = await flag.fired
        #expect(fired)
    }

    @Test("a thrown body defers so the scheduler retries")
    func thrownBodyDefers() async {
        struct E: Error {}
        let activity = BackgroundCompoundActivity(identifier: "test.activity.throw") {
            throw E()
        }
        let outcome = await activity.run(deferral: NullDeferralSource())
        #expect(outcome == .deferred)
    }

    @Test("a scheduler already deferring short-circuits without running the body")
    func alreadyDeferringSkipsBody() async {
        actor Flag { var fired = false; func set() { fired = true } }
        let flag = Flag()
        let activity = BackgroundCompoundActivity(identifier: "test.activity.skip") {
            await flag.set()
        }
        let outcome = await activity.run(deferral: FakeDeferralSource(deferring: true))
        #expect(outcome == .deferred)
        let fired = await flag.fired
        #expect(!fired)
    }

    @Test("shouldDefer mid-run cancels the work task and reports deferred")
    func deferralMidRunCancelsWork() async throws {
        actor State {
            var sawCancel = false
            var completed = false
            func cancel() { sawCancel = true }
            func complete() { completed = true }
        }
        let state = State()
        let deferral = FakeDeferralSource()
        let activity = BackgroundCompoundActivity(identifier: "test.activity.defer") {
            do {
                try await Task.sleep(for: .seconds(60))
                await state.complete()
            } catch is CancellationError {
                await state.cancel()
                throw CancellationError()
            }
        }
        let run = Task<BackgroundActivityCompletion, Never> {
            await activity.run(deferral: deferral, pollInterval: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(20))
        deferral.requestDefer()
        let outcome = await run.value
        #expect(outcome == .deferred)
        let sawCancel = await state.sawCancel
        let completed = await state.completed
        #expect(sawCancel)
        #expect(!completed)
    }

    @Test("cancelling the caller cancels the held work task")
    func callerCancellationPropagates() async throws {
        actor State {
            var sawCancel = false
            func cancel() { sawCancel = true }
        }
        let state = State()
        let activity = BackgroundCompoundActivity(identifier: "test.activity.caller") {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch is CancellationError {
                await state.cancel()
                throw CancellationError()
            }
        }
        let run = Task<BackgroundActivityCompletion, Never> {
            await activity.run(deferral: NullDeferralSource(), pollInterval: .seconds(30))
        }
        try await Task.sleep(for: .milliseconds(20))
        run.cancel()
        let outcome = await run.value
        #expect(outcome == .deferred)
        let sawCancel = await state.sawCancel
        #expect(sawCancel)
    }

    @Test("deferral propagates into the run's RunContext and unwinds the loop")
    func deferralPropagatesIntoControlLoop() async throws {
        let tracer = InMemoryTracer()
        let deferral = FakeDeferralSource()
        let chain = VerifierChain<String>(name: "out", [
            AnyVerifier<String>(name: "p", cost: .parse) { _, _ in .pass }
        ])
        let activity = BackgroundCompoundActivity(identifier: "test.activity.loop") {
            let loop = ControlLoop(budget: .default, outputVerifier: chain)
            _ = try await loop.run(
                prompt: "p",
                modelClient: SlowFakeModel(delay: .seconds(30)),
                runContext: RunContext(tracer: tracer)
            )
        }
        let run = Task<BackgroundActivityCompletion, Never> {
            await activity.run(deferral: deferral, pollInterval: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(30))
        deferral.requestDefer()
        let outcome = await run.value
        #expect(outcome == .deferred)
        let events = await tracer.snapshot()
        let sawFailedEnd = events.contains { ev in
            if case .runEnded(_, let success, _) = ev { return success == false }
            return false
        }
        #expect(sawFailedEnd)
    }

    @Test("WorkBox applies a cancel that lands before the task is registered")
    func workBoxRemembersEarlyCancel() {
        let box = WorkBox()
        let cancelled = LockedFlag()
        box.cancel()
        box.set { cancelled.set() }
        #expect(cancelled.value)
    }

    @Test("WorkBox cancels at most once")
    func workBoxCancelsOnce() {
        let box = WorkBox()
        let counter = LockedCounter()
        box.set { counter.bump() }
        box.cancel()
        box.cancel()
        #expect(counter.value == 1)
    }
}

/// Minimal lock-guarded flag for the synchronous `WorkBox` tests.
/// `@unchecked` because state is guarded by `lock` (NSLock).
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}

/// Minimal lock-guarded counter for the synchronous `WorkBox` tests.
/// `@unchecked` because state is guarded by `lock` (NSLock).
final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func bump() { lock.lock(); count += 1; lock.unlock() }
}
