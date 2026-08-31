import Foundation
import Testing
@testable import Compound

/// One exemplar per ``TraceEvent`` case, every string field seeded with a
/// recognizable marker.
///
/// This is the fixture behind both the Codable round-trip suite and the
/// redaction coverage harness: a case that is not represented here is a
/// case nobody is checking. ``caseName(_:)`` switches exhaustively, so
/// adding a case to ``TraceEvent`` fails to compile until it is named,
/// and ``caseCount`` fails the harness until an exemplar is added.
enum TraceExemplars {
    /// Number of cases ``TraceEvent`` declares.
    static let caseCount = 22

    /// Marker seeded into every string-valued field.
    static let secret = "SEEDPII-4c1f9a"

    static func diagnostic(_ secret: String) -> Diagnostic {
        Diagnostic(
            verifier: "verifier-\(secret)",
            message: "message \(secret)",
            suggestion: "try \(secret)",
            location: SourceRange(start: 3, end: 17)
        )
    }

    static func all(runID: UUID, secret: String = TraceExemplars.secret) -> [TraceEvent] {
        let diag = diagnostic(secret)
        var usage = BudgetUsage()
        usage.recordTurn()
        usage.recordTurn()
        usage.recordToolCall()
        usage.recordRepair()
        usage.recordOutputTokens(512)
        usage.recordElapsed(.milliseconds(2500))
        let budget = Budget(
            maxTurns: 3,
            maxToolCalls: 2,
            maxRepairAttempts: 1,
            wallClock: .seconds(30),
            firstToken: .milliseconds(500),
            interChunkGap: .seconds(2),
            maxTotalOutputTokens: 900
        )
        return [
            .runStarted(runID: runID, prompt: "summarize \(secret) please", budget: budget, auth: "user-\(secret)"),
            .runEnded(runID: runID, success: false, usage: usage),
            .modelInvocationStarted(runID: runID, turn: 1, promptBytes: 1234),
            .modelInvocationCompleted(runID: runID, turn: 2, outputBytes: 99, elapsed: .milliseconds(1500)),
            .modelInvocationFailed(runID: runID, turn: 3, reason: "model exploded \(secret)"),
            .toolInvocationRequested(runID: runID, tool: "fetch-\(secret)"),
            .toolInvocationCompleted(runID: runID, tool: "fetch-\(secret)", elapsed: .microseconds(250), succeeded: true),
            .toolPolicyDenied(runID: runID, tool: "shell-\(secret)", reason: "denied \(secret)"),
            .toolArgumentRejected(runID: runID, tool: "sql-\(secret)", diagnostic: diag),
            .toolOutputRejected(runID: runID, tool: "web-\(secret)", diagnostic: diag),
            .verifierEvaluated(runID: runID, verifier: "v-\(secret)", cost: .schema, verdict: .repair(diag), elapsed: .milliseconds(7)),
            .bestOfNSampled(runID: runID, candidates: 3, scores: [0.25, 1, 0.5], agreement: 0.375, selectedIndex: 1),
            .breakerTransitioned(runID: runID, signal: .guardrailViolation, from: .closed, to: .open, failures: 3),
            .degradationApplied(runID: runID, mode: .noTools, reason: "breaker open for \(secret)"),
            .routingEscalated(runID: runID, step: "step-\(secret)", confidence: 0.25, attempt: 2),
            .retrievalRound(
                runID: runID,
                round: 2,
                query: "query \(secret)",
                retrieved: 5,
                newSources: 2,
                verdict: "insufficient missing=[\(secret)]"
            ),
            .retrievalLoopEnded(runID: runID, rounds: 3, sources: 7, reason: "sufficient"),
            .repairScheduled(runID: runID, attempt: 2, diagnostic: diag),
            .budgetExhausted(runID: runID, kind: .wallClock),
            .escalation(runID: runID, reason: "needs a human \(secret)"),
            .info(runID: runID, category: "category-\(secret)", message: "message \(secret)"),
            .unknown(runID: runID, label: "future-\(secret)", payload: ["key-\(secret)": "value-\(secret)"])
        ]
    }

    /// Exhaustive case name; the compiler forces this to be updated when
    /// ``TraceEvent`` grows a case.
    static func caseName(_ event: TraceEvent) -> String {
        switch event {
        case .runStarted: return "runStarted"
        case .runEnded: return "runEnded"
        case .modelInvocationStarted: return "modelInvocationStarted"
        case .modelInvocationCompleted: return "modelInvocationCompleted"
        case .modelInvocationFailed: return "modelInvocationFailed"
        case .toolInvocationRequested: return "toolInvocationRequested"
        case .toolInvocationCompleted: return "toolInvocationCompleted"
        case .toolPolicyDenied: return "toolPolicyDenied"
        case .toolArgumentRejected: return "toolArgumentRejected"
        case .toolOutputRejected: return "toolOutputRejected"
        case .verifierEvaluated: return "verifierEvaluated"
        case .bestOfNSampled: return "bestOfNSampled"
        case .breakerTransitioned: return "breakerTransitioned"
        case .degradationApplied: return "degradationApplied"
        case .routingEscalated: return "routingEscalated"
        case .retrievalRound: return "retrievalRound"
        case .retrievalLoopEnded: return "retrievalLoopEnded"
        case .repairScheduled: return "repairScheduled"
        case .budgetExhausted: return "budgetExhausted"
        case .escalation: return "escalation"
        case .info: return "info"
        case .unknown: return "unknown"
        }
    }
}

/// Replaces one literal needle wherever it appears.
struct LiteralRedactor: Redactor {
    let name = "seeded-pii"
    let needle: String
    func redact(_ text: String) -> String {
        text.replacingOccurrences(of: needle, with: "⟨redacted⟩")
    }
}

/// Destroys every string it is handed. Used to prove that the trace wire
/// format's structural keys survive redaction: if a new case introduces a
/// key the redactor is allowed to rewrite, the event stops decoding and
/// the structure test fails.
struct BlanketRedactor: Redactor {
    let name = "blanket"
    func redact(_: String) -> String { "⟨x⟩" }
}

@Suite("Trace round-trip")
struct TraceRoundTripTests {
    // MARK: - Codable

    @Test("every trace event case round-trips through Codable")
    func everyCaseRoundTrips() throws {
        let runID = UUID()
        let exemplars = TraceExemplars.all(runID: runID)
        #expect(exemplars.count == TraceExemplars.caseCount, "one exemplar per TraceEvent case is required")
        #expect(Set(exemplars.map(TraceExemplars.caseName)).count == TraceExemplars.caseCount)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for event in exemplars {
            let data = try encoder.encode(event)
            let decoded = try decoder.decode(TraceEvent.self, from: data)
            #expect(decoded == event, "round-trip lost fidelity for \(TraceExemplars.caseName(event))")
            #expect(decoded.runID == runID)
        }
    }

    @Test("encoded events carry a stable type discriminator")
    func stableDiscriminator() throws {
        let event = TraceEvent.toolInvocationCompleted(runID: UUID(), tool: "fetch", elapsed: .milliseconds(3), succeeded: true)
        let json = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        #expect(json.contains("\"type\":\"tool.completed\""))
        #expect(json.contains("\"elapsed_ns\":3000000"))
    }

    @Test("trace record round-trips with its timestamp")
    func recordRoundTrips() throws {
        let runID = UUID()
        let stamp = Date(timeIntervalSince1970: 1_770_000_000.25)
        for event in TraceExemplars.all(runID: runID) {
            let record = TraceRecord(event: event, timestamp: stamp)
            let data = try JSONEncoder().encode(record)
            let decoded = try JSONDecoder().decode(TraceRecord.self, from: data)
            #expect(decoded.event == event)
            #expect(abs(decoded.timestamp.timeIntervalSince(stamp)) < 0.000_01)
            #expect(decoded.runID == runID)
        }
    }

    @Test("verdicts and budgets round-trip")
    func verdictAndBudgetRoundTrip() throws {
        let diag = TraceExemplars.diagnostic("x")
        let verdicts: [Verdict] = [.pass, .repair(diag), .reject(diag), .escalate(diag)]
        for verdict in verdicts {
            let data = try JSONEncoder().encode(verdict)
            #expect(try JSONDecoder().decode(Verdict.self, from: data) == verdict)
        }
        let budgets: [Budget] = [
            .default,
            .strict,
            Budget(maxTurns: 1, maxToolCalls: 0, maxRepairAttempts: 0, wallClock: .milliseconds(1500),
                   firstToken: .milliseconds(250), interChunkGap: nil, maxTotalOutputTokens: 42)
        ]
        for budget in budgets {
            let data = try JSONEncoder().encode(budget)
            #expect(try JSONDecoder().decode(Budget.self, from: data) == budget)
        }
        var usage = BudgetUsage()
        usage.recordTurn()
        usage.recordElapsed(.milliseconds(90))
        let usageData = try JSONEncoder().encode(usage)
        #expect(try JSONDecoder().decode(BudgetUsage.self, from: usageData) == usage)
    }

    @Test("a corrupt budget throws instead of trapping")
    func corruptBudgetThrows() throws {
        let json = Data(#"{"max_turns":0,"max_tool_calls":1,"max_repair_attempts":1,"wall_clock_ns":1000}"#.utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(Budget.self, from: json)
        }
    }

    // MARK: - JSONL write → read

    @Test("JSONL tracer write-read round-trips every case")
    func jsonlRoundTrip() async throws {
        let url = TracerTestHelpers.tempFile(name: "roundtrip.jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let runID = UUID()
        let exemplars = TraceExemplars.all(runID: runID)
        let before = Date()
        let tracer = try JSONLTracer(fileURL: url, flushPolicy: .everyEvent)
        for event in exemplars { await tracer.record(event) }
        try await tracer.close()
        let after = Date()

        let batch = try TraceReader.read(fileURL: url)
        #expect(batch.skippedLines == 0)
        #expect(batch.events == exemplars)
        #expect(batch.records(for: runID).count == exemplars.count)
        for record in batch.records {
            #expect(record.timestamp >= before.addingTimeInterval(-1))
            #expect(record.timestamp <= after.addingTimeInterval(1))
        }
    }

    @Test("reader skips corrupt lines and keeps the good ones")
    func readerSkipsCorruptLines() throws {
        let runID = UUID()
        let good = TraceRecord(event: .info(runID: runID, category: "c", message: "hello"))
        let encoder = JSONEncoder()
        var data = Data()
        data.append(try encoder.encode(good)); data.append(0x0A)
        data.append(Data("{not json at all".utf8)); data.append(0x0A)
        data.append(Data("   ".utf8)); data.append(0x0A)
        data.append(0x0A)
        data.append(Data(#"{"type":"info","run":"not-a-uuid","ts":1.0}"#.utf8)); data.append(0x0A)
        data.append(try encoder.encode(good)); data.append(0x0A)
        // Truncated tail, as a process killed mid-write would leave.
        data.append(Data(#"{"type":"info","run":""#.utf8))

        let batch = TraceReader.decode(data)
        #expect(batch.records.count == 2)
        #expect(batch.skippedLines == 3)
        #expect(batch.events.allSatisfy { $0.label == "info" })
    }

    @Test("reader decodes an unrecognized event type as unknown")
    func readerToleratesFutureEvents() throws {
        let runID = UUID()
        let line = """
        {"type":"quantum.entangled","run":"\(runID.uuidString)","ts":1770000000.5,"note":"from the future","count":7,"ok":true}
        """
        let batch = TraceReader.decode(Data(line.utf8))
        #expect(batch.skippedLines == 0)
        #expect(batch.records.count == 1)
        guard case .unknown(let id, let label, let payload) = try #require(batch.events.first) else {
            Issue.record("expected .unknown for an unrecognized type")
            return
        }
        #expect(id == runID)
        #expect(label == "quantum.entangled")
        #expect(payload["note"] == "from the future")
        #expect(payload["count"] == "7")
        #expect(payload["ok"] == "true")
        #expect(payload["run"] == nil, "the run id is structural, not payload")
    }

    @Test("an empty trace file reads as an empty batch")
    func emptyFileReads() throws {
        let url = TracerTestHelpers.tempFile(name: "empty.jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let batch = try TraceReader.read(fileURL: url)
        #expect(batch.records.isEmpty)
        #expect(batch.skippedLines == 0)
    }

    // MARK: - Rotation

    @Test("JSONL tracer rotates and bounds total on-disk size")
    func rotationBoundsSize() async throws {
        let url = TracerTestHelpers.tempFile(name: "rotating.jsonl")
        let generations = 3
        defer {
            try? FileManager.default.removeItem(at: url)
            for i in 1..<generations {
                try? FileManager.default.removeItem(at: JSONLTracer.archiveURL(base: url, generation: i))
            }
        }
        let cap = 400
        let tracer = try JSONLTracer(fileURL: url, flushPolicy: .everyEvent, maxFileBytes: cap, maxFiles: generations)
        let runID = UUID()
        for i in 0..<40 {
            await tracer.record(.info(runID: runID, category: "rotation", message: "event-\(i)"))
        }
        try await tracer.close()

        #expect(FileManager.default.fileExists(atPath: JSONLTracer.archiveURL(base: url, generation: 1).path))
        #expect(FileManager.default.fileExists(atPath: JSONLTracer.archiveURL(base: url, generation: 2).path))
        #expect(
            !FileManager.default.fileExists(atPath: JSONLTracer.archiveURL(base: url, generation: 3).path),
            "generation beyond maxFiles must be discarded"
        )
        for generation in 0..<generations {
            let file = generation == 0 ? url : JSONLTracer.archiveURL(base: url, generation: generation)
            let size = try Data(contentsOf: file).count
            #expect(size <= cap, "generation \(generation) grew to \(size) bytes, cap is \(cap)")
        }

        let batch = try TraceReader.readRotated(baseURL: url, maxFiles: generations)
        #expect(batch.skippedLines == 0)
        #expect(!batch.records.isEmpty)
        #expect(batch.records.count < 40, "rotation is expected to drop the oldest generations")
        // The newest event always survives, and the timeline is ordered.
        if case .info(_, _, let message) = try #require(batch.events.last) {
            #expect(message == "event-39")
        } else {
            Issue.record("unexpected trailing event")
        }
        let timestamps = batch.records.map(\.timestamp)
        #expect(timestamps == timestamps.sorted(), "rotated reads must be chronological")
    }

    @Test("rotation loses nothing while the set stays within capacity")
    func rotationLosslessWithinCapacity() async throws {
        let url = TracerTestHelpers.tempFile(name: "rotating-lossless.jsonl")
        let generations = 6
        defer {
            try? FileManager.default.removeItem(at: url)
            for i in 1..<generations {
                try? FileManager.default.removeItem(at: JSONLTracer.archiveURL(base: url, generation: i))
            }
        }
        let tracer = try JSONLTracer(fileURL: url, flushPolicy: .everyEvent, maxFileBytes: 1000, maxFiles: generations)
        let runID = UUID()
        let messages = (0..<20).map { "event-\($0)" }
        for message in messages {
            await tracer.record(.info(runID: runID, category: "rotation", message: message))
        }
        try await tracer.close()

        #expect(
            FileManager.default.fileExists(atPath: JSONLTracer.archiveURL(base: url, generation: 1).path),
            "the test is only meaningful if rotation actually happened"
        )
        let batch = try TraceReader.readRotated(baseURL: url, maxFiles: generations)
        #expect(batch.skippedLines == 0)
        let read = batch.events.compactMap { event -> String? in
            if case .info(_, _, let message) = event { return message }
            return nil
        }
        #expect(read == messages)
    }

    @Test("a single oversized event still gets written")
    func oversizedEventWrites() async throws {
        let url = TracerTestHelpers.tempFile(name: "oversized.jsonl")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: JSONLTracer.archiveURL(base: url, generation: 1))
        }
        let tracer = try JSONLTracer(fileURL: url, flushPolicy: .everyEvent, maxFileBytes: 64, maxFiles: 2)
        let runID = UUID()
        await tracer.record(.info(runID: runID, category: "big", message: String(repeating: "x", count: 500)))
        try await tracer.close()
        let batch = try TraceReader.readRotated(baseURL: url, maxFiles: 2)
        #expect(batch.records.count == 1)
        #expect(batch.skippedLines == 0)
    }

    // MARK: - Redaction coverage

    @Test("redaction covers every trace event case")
    func redactionCoversEveryCase() async throws {
        let runID = UUID()
        let exemplars = TraceExemplars.all(runID: runID)
        #expect(exemplars.count == TraceExemplars.caseCount)
        let inner = InMemoryTracer()
        let tracer = RedactingTracer(inner: inner, redactors: [LiteralRedactor(needle: TraceExemplars.secret)])
        for event in exemplars { await tracer.record(event) }
        let out = await inner.snapshot()
        #expect(out.count == exemplars.count)

        let encoder = JSONEncoder()
        for (original, redacted) in zip(exemplars, out) {
            let name = TraceExemplars.caseName(original)
            #expect(TraceExemplars.caseName(redacted) == name, "\(name) was not forwarded intact")
            #expect(redacted.runID == runID, "\(name) lost its run correlation")
            let json = String(decoding: try encoder.encode(redacted), as: UTF8.self)
            #expect(!json.contains(TraceExemplars.secret), "seeded PII survived redaction in \(name): \(json)")
        }

        // Sanity: the exemplars really do carry the marker in the cases
        // that have string payloads, so the assertion above has teeth.
        let seeded = try exemplars.filter {
            String(decoding: try encoder.encode($0), as: UTF8.self).contains(TraceExemplars.secret)
        }
        #expect(seeded.count >= 11, "exemplars must seed PII into every string-bearing case")
    }

    @Test("redaction keeps the wire format decodable under a blanket redactor")
    func redactionPreservesStructure() async throws {
        let runID = UUID()
        let exemplars = TraceExemplars.all(runID: runID)
        let inner = InMemoryTracer()
        let tracer = RedactingTracer(inner: inner, redactors: [BlanketRedactor()])
        for event in exemplars { await tracer.record(event) }
        let out = await inner.snapshot()
        for (original, redacted) in zip(exemplars, out) {
            let name = TraceExemplars.caseName(original)
            #expect(TraceExemplars.caseName(redacted) == name, "\(name) failed closed — a structural key was rewritten")
            #expect(redacted.label != TraceEvent.redactionFailedLabel)
        }
        // Structured, non-textual telemetry must survive scrubbing.
        guard case .runEnded(_, let success, let usage) = try #require(out.first(where: { $0.label == "run.ended" })) else {
            Issue.record("missing run.ended")
            return
        }
        #expect(success == false)
        #expect(usage.turns == 2)
        #expect(usage.toolCalls == 1)
        #expect(usage.elapsed == .milliseconds(2500))
        guard case .budgetExhausted(_, let kind) = try #require(out.first(where: { $0.label == "budget.exhausted" })) else {
            Issue.record("missing budget.exhausted")
            return
        }
        #expect(kind == .wallClock)
    }

    @Test("redaction scrubs free-form payload keys as well as values")
    func redactionScrubsPayloadKeys() async throws {
        let inner = InMemoryTracer()
        let tracer = RedactingTracer(inner: inner, redactors: [LiteralRedactor(needle: "hunter2")])
        let runID = UUID()
        await tracer.record(.unknown(runID: runID, label: "custom", payload: ["password-hunter2": "hunter2"]))
        let out = await inner.snapshot()
        guard case .unknown(let id, let label, let payload) = try #require(out.first) else {
            Issue.record("expected .unknown")
            return
        }
        #expect(id == runID)
        #expect(label == "custom")
        #expect(payload.keys.allSatisfy { !$0.contains("hunter2") })
        #expect(payload.values.allSatisfy { !$0.contains("hunter2") })
    }

    @Test("redaction with no redactors is a pass-through")
    func redactionNoOpWithoutRedactors() async throws {
        let inner = InMemoryTracer()
        let tracer = RedactingTracer(inner: inner, redactors: [])
        let exemplars = TraceExemplars.all(runID: UUID())
        for event in exemplars { await tracer.record(event) }
        let out = await inner.snapshot()
        #expect(out == exemplars)
    }

    // MARK: - Timestamps at emission

    @Test("in-memory tracer stamps records at emission")
    func inMemoryStamps() async throws {
        let tracer = InMemoryTracer()
        let runID = UUID()
        let before = Date()
        await tracer.record(.info(runID: runID, category: "c", message: "first"))
        try await Task.sleep(for: .milliseconds(10))
        await tracer.record(.info(runID: runID, category: "c", message: "second"))
        let records = await tracer.recordSnapshot()
        #expect(records.count == 2)
        #expect(records[0].timestamp >= before)
        #expect(records[1].timestamp > records[0].timestamp)
        #expect(await tracer.records(for: runID).count == 2)
    }
}
