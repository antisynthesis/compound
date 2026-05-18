import Foundation
import Testing
@testable import Compound

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
}
