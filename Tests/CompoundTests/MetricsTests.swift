import Foundation
import Testing
@testable import Compound

@Suite("Metrics")
struct MetricsTests {
    @Test("metrics tracer aggregates runs")
    func aggregatesRuns() async throws {
        let tracer = MetricsCollectingTracer()
        let id = UUID()
        await tracer.record(.runStarted(runID: id, prompt: "x", budget: .default, auth: "anon"))
        var usage = BudgetUsage()
        usage.recordTurn(); usage.recordToolCall(); usage.recordRepair()
        await tracer.record(.runEnded(runID: id, success: true, usage: usage))
        let snap = await tracer.current()
        #expect(snap.runsStarted == 1)
        #expect(snap.runsEnded == 1)
        #expect(snap.runsSucceeded == 1)
        #expect(snap.totalTurns == 1)
    }

    @Test("metrics tracer tracks per-tool stats")
    func perToolStats() async throws {
        let tracer = MetricsCollectingTracer()
        let id = UUID()
        await tracer.record(.toolInvocationCompleted(runID: id, tool: "fetch", elapsed: .milliseconds(100), succeeded: true))
        await tracer.record(.toolInvocationCompleted(runID: id, tool: "fetch", elapsed: .milliseconds(200), succeeded: false))
        let snap = await tracer.current()
        #expect(snap.toolInvocations == 2)
        #expect(snap.toolFailures == 1)
        let fetch = snap.perTool["fetch"]
        #expect(fetch != nil)
        #expect(fetch?.count == 2)
        #expect(fetch?.failures == 1)
    }

    @Test("metrics tracer counts verifier verdicts")
    func countsVerifierVerdicts() async throws {
        let tracer = MetricsCollectingTracer()
        let id = UUID()
        await tracer.record(.verifierEvaluated(runID: id, verifier: "v1", cost: .parse, verdict: .pass, elapsed: .milliseconds(1)))
        await tracer.record(.verifierEvaluated(runID: id, verifier: "v1", cost: .parse, verdict: .repair(Diagnostic(verifier: "v1", message: "x")), elapsed: .milliseconds(1)))
        await tracer.record(.verifierEvaluated(runID: id, verifier: "v1", cost: .parse, verdict: .reject("nope"), elapsed: .milliseconds(1)))
        let snap = await tracer.current()
        let v = snap.perVerifier["v1"]
        #expect(v?.passes == 1)
        #expect(v?.repairs == 1)
        #expect(v?.rejects == 1)
        #expect(v?.count == 3)
    }

    @Test("metrics tracer success rate computes")
    func successRateComputes() async throws {
        let tracer = MetricsCollectingTracer()
        for _ in 0..<3 {
            let id = UUID()
            await tracer.record(.runEnded(runID: id, success: true, usage: BudgetUsage()))
        }
        let id = UUID()
        await tracer.record(.runEnded(runID: id, success: false, usage: BudgetUsage()))
        let snap = await tracer.current()
        #expect(abs(snap.successRate - 0.75) < 0.001)
    }

    @Test("latency stats record min/max/avg")
    func latencyMinMaxAvg() {
        var stats = LatencyStats()
        stats.record(.milliseconds(10))
        stats.record(.milliseconds(20))
        stats.record(.milliseconds(30))
        #expect(stats.count == 3)
        #expect(abs(stats.averageMilliseconds - 20.0) < 1.0)
        #expect(abs(stats.minMilliseconds - 10.0) < 1.0)
        #expect(abs(stats.maxMilliseconds - 30.0) < 1.0)
    }

    @Test("latency stats percentiles read after caching")
    func latencyPercentiles() {
        var stats = LatencyStats()
        for v in 1...100 {
            stats.record(.milliseconds(v))
        }
        let p50a = stats.p50ms
        let p50b = stats.percentile(0.5)
        let p99 = stats.p99ms
        #expect(p50a == p50b)
        #expect(p99 >= p50a)
        stats.record(.milliseconds(1_000_000))
        #expect(stats.p99ms >= p99)
    }

    @Test("metrics tracer captures budget exhaustion kind")
    func capturesBudgetExhaustion() async throws {
        let tracer = MetricsCollectingTracer()
        await tracer.record(.budgetExhausted(runID: UUID(), kind: .turns))
        await tracer.record(.budgetExhausted(runID: UUID(), kind: .turns))
        await tracer.record(.budgetExhausted(runID: UUID(), kind: .wallClock))
        let snap = await tracer.current()
        #expect(snap.budgetExhausted[.turns] == 2)
        #expect(snap.budgetExhausted[.wallClock] == 1)
    }
}
