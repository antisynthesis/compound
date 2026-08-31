import Foundation
import Testing
@testable import Compound

@Suite("Tracer")
struct TracerTests {
    @Test("in-memory tracer records events")
    func recordsEvents() async throws {
        let tracer = InMemoryTracer()
        let runID = UUID()
        await tracer.record(.runStarted(runID: runID, prompt: "hi", budget: .default, auth: "anonymous"))
        await tracer.record(.runEnded(runID: runID, success: true, usage: BudgetUsage()))
        let events = await tracer.snapshot()
        #expect(events.count == 2)
        #expect(events.first?.label == "run.started")
        #expect(events.last?.label == "run.ended")
    }

    @Test("in-memory tracer filters by run id")
    func filtersByRunID() async throws {
        let tracer = InMemoryTracer()
        let a = UUID()
        let b = UUID()
        await tracer.record(.info(runID: a, category: "x", message: "first"))
        await tracer.record(.info(runID: b, category: "x", message: "second"))
        await tracer.record(.info(runID: a, category: "x", message: "third"))
        let onlyA = await tracer.events(for: a)
        #expect(onlyA.count == 2)
    }

    @Test("in-memory tracer respects capacity")
    func respectsCapacity() async throws {
        let tracer = InMemoryTracer(capacity: 2)
        let id = UUID()
        for i in 0..<5 {
            await tracer.record(.info(runID: id, category: "x", message: "m\(i)"))
        }
        let events = await tracer.snapshot()
        #expect(events.count == 2)
    }

    @Test("null tracer accepts events silently")
    func nullTracerAccepts() async throws {
        let tracer = NullTracer()
        await tracer.record(.info(runID: UUID(), category: "x", message: "y"))
    }

    @Test("redacting tracer scrubs secret-bearing reject reason")
    func redactingTracerScrubs() async throws {
        let inner = InMemoryTracer()
        let bearer = try CommonRedactors.bearerToken()
        let aws = try CommonRedactors.awsAccessKey()
        let tracer = RedactingTracer(inner: inner, redactors: [bearer, aws])
        let id = UUID()
        let raw = "denied because Bearer ABCDEFGHIJKLMNOP123456 and AKIAABCDEFGHIJKLMNOP"
        await tracer.record(.toolPolicyDenied(runID: id, tool: "fetch", reason: raw))
        await tracer.record(.escalation(runID: id, reason: raw))
        await tracer.record(.info(runID: id, category: "policy", message: raw))
        let events = await inner.snapshot()
        #expect(events.count == 3)
        for ev in events {
            switch ev {
            case .toolPolicyDenied(_, _, let reason),
                 .escalation(_, let reason),
                 .info(_, _, let reason):
                #expect(!reason.contains("ABCDEFGHIJKLMNOP123456"), "bearer token leaked: \(reason)")
                #expect(!reason.contains("AKIAABCDEFGHIJKLMNOP"), "aws key leaked: \(reason)")
                #expect(reason.contains("⟨token⟩") || reason.contains("⟨aws-key⟩"), "no redaction placeholder in \(reason)")
            default:
                Issue.record("unexpected event")
            }
        }
    }

    @Test("redacting tracer leaves numeric ids and counts intact")
    func redactingTracerNumericIntact() async throws {
        let inner = InMemoryTracer()
        let bearer = try CommonRedactors.bearerToken()
        let tracer = RedactingTracer(inner: inner, redactors: [bearer])
        let id = UUID()
        var usage = BudgetUsage()
        usage.recordTurn(); usage.recordTurn(); usage.recordToolCall()
        await tracer.record(.runEnded(runID: id, success: true, usage: usage))
        await tracer.record(.toolInvocationCompleted(runID: id, tool: "fetch", elapsed: .milliseconds(50), succeeded: true))
        let events = await inner.snapshot()
        #expect(events.count == 2)
        switch events[0] {
        case .runEnded(let outID, let ok, let u):
            #expect(outID == id)
            #expect(ok == true)
            #expect(u.turns == 2)
            #expect(u.toolCalls == 1)
        default:
            Issue.record("wrong event")
        }
    }

    @Test("composite tracer fans out concurrently")
    func compositeFansOutConcurrently() async throws {
        let a = SleepyTracer(delay: .milliseconds(150))
        let b = SleepyTracer(delay: .milliseconds(150))
        let c = SleepyTracer(delay: .milliseconds(150))
        let composite = CompositeTracer([a, b, c])
        let start = ContinuousClock.now
        await composite.record(.info(runID: UUID(), category: "x", message: "y"))
        let elapsed = ContinuousClock.now - start
        let ms = TracerTestHelpers.ms(elapsed)
        #expect(ms < 300, "expected parallel composite (<300ms), got \(ms)ms")
    }

    @Test("trace event visitor dispatches to right method")
    func visitorDispatches() async throws {
        let recorder = VisitorRecorder()
        let id = UUID()
        let events: [TraceEvent] = [
            .runStarted(runID: id, prompt: "p", budget: .default, auth: "anon"),
            .toolInvocationCompleted(runID: id, tool: "fetch", elapsed: .milliseconds(1), succeeded: true),
            .verifierEvaluated(runID: id, verifier: "v", cost: .parse, verdict: .pass, elapsed: .milliseconds(1)),
            .unknown(runID: id, label: "future.thing", payload: ["k": "v"])
        ]
        for e in events { await e.accept(recorder) }
        let calls = await recorder.calls
        #expect(calls == ["runStarted", "toolInvocationCompleted", "verifierEvaluated", "unknown"])
    }

    @Test("trace event unknown round-trips through default switch")
    func unknownRoundTrips() async throws {
        let id = UUID()
        let payload = ["k1": "v1", "k2": "v2"]
        let ev: TraceEvent = .unknown(runID: id, label: "future.event", payload: payload)
        #expect(ev.runID == id)
        #expect(ev.label == "future.event")
        var sawDefault = false
        switch ev {
        case .runStarted, .runEnded, .modelInvocationStarted, .modelInvocationCompleted,
             .modelInvocationFailed, .toolInvocationRequested, .toolInvocationCompleted,
             .toolPolicyDenied, .verifierEvaluated, .repairScheduled, .budgetExhausted,
             .escalation, .info:
            Issue.record("unexpected match")
        default:
            sawDefault = true
        }
        #expect(sawDefault)
    }

    @Test("JSONL tracer never-flush writes lines")
    func jsonlNeverFlush() async throws {
        let url = TracerTestHelpers.tempFile(name: "jsonl-never.log")
        defer { try? FileManager.default.removeItem(at: url) }
        let tracer = try JSONLTracer(fileURL: url, flushPolicy: .never)
        let id = UUID()
        await tracer.record(.info(runID: id, category: "c", message: "hello"))
        await tracer.record(.info(runID: id, category: "c", message: "world"))
        try await tracer.close()
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 2)
        #expect(lines[0].contains("\"type\":\"info\""))
        #expect(lines[0].contains("\"message\":\"hello\""))
    }

    @Test("JSONL tracer every-event flush writes lines")
    func jsonlEveryEventFlush() async throws {
        let url = TracerTestHelpers.tempFile(name: "jsonl-every.log")
        defer { try? FileManager.default.removeItem(at: url) }
        let tracer = try JSONLTracer(fileURL: url, flushPolicy: .everyEvent)
        let id = UUID()
        for i in 0..<3 {
            await tracer.record(.info(runID: id, category: "c", message: "m\(i)"))
        }
        try await tracer.close()
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 3)
    }

    @Test("JSONL tracer every-N flush writes lines")
    func jsonlEveryNFlush() async throws {
        let url = TracerTestHelpers.tempFile(name: "jsonl-everyN.log")
        defer { try? FileManager.default.removeItem(at: url) }
        let tracer = try JSONLTracer(fileURL: url, flushPolicy: .everyN(2))
        let id = UUID()
        for i in 0..<5 {
            await tracer.record(.info(runID: id, category: "c", message: "m\(i)"))
        }
        try await tracer.close()
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 5)
    }
}

enum TracerTestHelpers {
    static func tempFile(name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("compound-\(UUID().uuidString)-\(name)")
    }

    static func ms(_ d: Duration) -> Int {
        let parts = d.components
        return Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)
    }
}

struct SleepyTracer: Tracer {
    let delay: Duration
    func record(_: TraceEvent) async {
        try? await Task.sleep(for: delay)
    }
}

actor VisitorRecorder: TraceEventVisitor {
    private(set) var calls: [String] = []
    func visitRunStarted(runID _: UUID, prompt _: String, budget _: Budget, auth _: String) async {
        calls.append("runStarted")
    }
    func visitToolInvocationCompleted(runID _: UUID, tool _: String, elapsed _: Duration, succeeded _: Bool) async {
        calls.append("toolInvocationCompleted")
    }
    func visitVerifierEvaluated(runID _: UUID, verifier _: String, cost _: VerifierCost, verdict _: Verdict, elapsed _: Duration) async {
        calls.append("verifierEvaluated")
    }
    func visitUnknown(runID _: UUID, label _: String, payload _: [String: String]) async {
        calls.append("unknown")
    }
}
