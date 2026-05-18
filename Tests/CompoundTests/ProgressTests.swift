import Foundation
import Testing
@testable import Compound

@Suite("Progress")
struct ProgressTests {
    @Test("recording reporter accumulates events")
    func recordingAccumulates() async throws {
        let reporter = RecordingProgressReporter()
        await reporter.report(.runStarted(runID: UUID()))
        await reporter.report(.modelTurnCompleted(turn: 1, content: "hi"))
        await reporter.report(.runCompleted(success: true))
        let events = await reporter.snapshot()
        #expect(events.count == 3)
    }

    @Test("streaming reporter fans out to subscribers")
    func streamingFansOut() async throws {
        let reporter = StreamingProgressReporter()
        let stream = await reporter.subscribe()
        let task = Task {
            var seen = 0
            for await _ in stream {
                seen += 1
                if seen >= 2 { break }
            }
            return seen
        }
        await reporter.report(.runStarted(runID: UUID()))
        await reporter.report(.runCompleted(success: true))
        let count = await task.value
        #expect(count == 2)
        await reporter.finishAll()
    }
}
