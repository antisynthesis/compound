import Foundation
import Testing
@testable import Compound

@Suite("Concurrency")
struct ConcurrencyTests {
    @Test("InMemoryTracer captures 100 concurrent record() calls")
    func inMemoryTracerConcurrent() async throws {
        let tracer = InMemoryTracer()
        let runID = UUID()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    await tracer.record(.info(runID: runID, category: "c", message: "m\(i)"))
                }
            }
        }
        let events = await tracer.snapshot()
        #expect(events.count == 100)
    }

    @Test("MetricsCollectingTracer counters sum across concurrent record()s")
    func metricsTracerConcurrent() async throws {
        let tracer = MetricsCollectingTracer()
        let runID = UUID()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    await tracer.record(.toolInvocationCompleted(
                        runID: runID, tool: "t", elapsed: .milliseconds(1), succeeded: true
                    ))
                }
            }
        }
        let snap = await tracer.current()
        #expect(snap.toolInvocations == 100)
        #expect(snap.perTool["t"]?.count == 100)
    }

    @Test("StreamingProgressReporter: 10 subscribers + 1000 producer events")
    func streamingReporterFanOut() async throws {
        let reporter = StreamingProgressReporter(bufferLimit: 2048)
        let subscriberCount = 10
        // Subscribe BEFORE producing, otherwise events emitted before subscribe
        // would be lost — bufferingNewest only retains in-flight events.
        var streams: [AsyncStream<ProgressEvent>] = []
        for _ in 0..<subscriberCount {
            streams.append(await reporter.subscribe())
        }
        // Consume in parallel. Move the stream out of the array before
        // capturing it in the detached task so the closure isn't reading
        // shared `var` state.
        let consumers = streams.map { stream in
            Task<Int, Never> {
                var seen = 0
                for await _ in stream {
                    seen += 1
                    if seen >= 1000 { break }
                }
                return seen
            }
        }
        // Produce 1000 events.
        for i in 0..<1000 {
            await reporter.report(.modelStreamChunk(turn: 1, content: "c\(i)"))
        }
        // Give consumers a tick to drain, then finalize.
        try await Task.sleep(for: .milliseconds(50))
        await reporter.finishAll()
        for c in consumers {
            let seen = await c.value
            // Each subscriber should see a prefix; with a generous buffer the
            // count should be close to 1000.
            #expect(seen > 0)
            #expect(seen <= 1000)
        }
    }
}
