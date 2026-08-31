import Foundation
import Testing
@testable import Compound

private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

private func makeFact(
    thread: String = "t1",
    subject: String = "user",
    predicate: String = "name",
    text: String = "Ada",
    origin: MemoryOrigin = .userStated,
    confidence: Double = 0.9,
    importance: Int = 5,
    tags: Set<String> = [],
    messageIDs: [UUID] = [],
    validFrom: Date = epoch,
    validUntil: Date? = nil,
    recordedAt: Date = epoch,
    invalidatedAt: Date? = nil,
    expiresAt: Date? = nil,
    supersedes: String? = nil,
    accessCount: Int = 0
) -> Fact {
    Fact(
        threadID: thread,
        subject: subject,
        predicate: predicate,
        text: text,
        origin: origin,
        confidence: confidence,
        importance: importance,
        tags: tags,
        provenance: FactProvenance(threadID: thread, messageIDs: messageIDs, extractor: "test"),
        validFrom: validFrom,
        validUntil: validUntil,
        recordedAt: recordedAt,
        invalidatedAt: invalidatedAt,
        expiresAt: expiresAt,
        supersedes: supersedes,
        lastAccessedAt: recordedAt,
        accessCount: accessCount
    )
}

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("compound-facts-\(UUID().uuidString).json")
}

@Suite("MemoryCodable")
struct MemoryCodableTests {
    @Test("fact round-trips through JSON with every field intact")
    func factRoundTrip() throws {
        let ids = [UUID(), UUID()]
        let original = makeFact(
            predicate: "prefers",
            text: "oat milk",
            tags: ["preference", "core"],
            messageIDs: ids,
            validUntil: epoch.addingTimeInterval(100),
            invalidatedAt: epoch.addingTimeInterval(200),
            expiresAt: epoch.addingTimeInterval(300),
            supersedes: "abc123",
            accessCount: 7
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Fact.self, from: try encoder.encode(original))
        #expect(decoded == original)
        #expect(decoded.tags == ["preference", "core"])
        #expect(decoded.provenance.messageIDs == ids.sorted { $0.uuidString < $1.uuidString })
    }

    @Test("tags encode as a sorted array so snapshots are byte-stable")
    func tagsEncodeSorted() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let f = makeFact(tags: ["zeta", "alpha", "mu"])
        var renderings = Set<String>()
        for _ in 0..<20 {
            renderings.insert(String(decoding: try encoder.encode(f), as: UTF8.self))
        }
        #expect(renderings.count == 1)
        #expect(renderings.first?.contains("[\"alpha\",\"mu\",\"zeta\"]") == true)
    }

    @Test("provenance sorts its id arrays for a stable encoding")
    func provenanceSorts() {
        let a = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        let b = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!
        let one = FactProvenance(threadID: "t", messageIDs: [b, a], archivalChunkIDs: ["z", "a"], extractor: "e")
        let two = FactProvenance(threadID: "t", messageIDs: [a, b], archivalChunkIDs: ["a", "z"], extractor: "e")
        #expect(one == two)
        #expect(one.messageIDs == [a, b])
        #expect(one.archivalChunkIDs == ["a", "z"])
    }

    @Test("an out-of-range confidence throws rather than trapping on decode")
    func decodeRejectsOutOfRange() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try JSONSerialization.jsonObject(
            with: try encoder.encode(makeFact()) ) as! [String: Any]
        object["confidence"] = 1.5
        let mutated = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(Fact.self, from: mutated)
        }
        object["confidence"] = 0.9
        object["importance"] = 42
        let mutated2 = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(Fact.self, from: mutated2)
        }
    }
}

@Suite("MemoryDurability")
struct MemoryDurabilityTests {
    @Test("a fresh instance on the same URL sees everything")
    func roundTripsAcrossInstances() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let a = makeFact(predicate: "name", text: "Ada", tags: ["core"])
        let b = makeFact(predicate: "location", text: "Dublin")
        do {
            let store = try FileFactStore(fileURL: url)
            try await store.upsert([a, b])
            try await store.flush()
        }
        let reopened = try FileFactStore(fileURL: url)
        let ids = try await reopened.allIDs()
        #expect(ids == [a.id, b.id].sorted())
        let read = try await reopened.fact(id: a.id)
        #expect(read == a)
    }

    @Test("invalidation and purge survive a reopen")
    func lifecyclePersists() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let kept = makeFact(predicate: "p1", text: "kept")
        let retired = makeFact(predicate: "p2", text: "retired")
        let gone = makeFact(predicate: "p3", text: "gone")
        do {
            let store = try FileFactStore(fileURL: url)
            try await store.upsert([kept, retired, gone])
            _ = try await store.invalidate(ids: [retired.id], validUntil: epoch, at: epoch, reason: .superseded)
            _ = try await store.purge(ids: [gone.id])
        }
        let reopened = try FileFactStore(fileURL: url)
        #expect(try await reopened.allIDs() == [kept.id, retired.id].sorted())
        let live = try await reopened.query(MemoryQuery(now: epoch))
        #expect(live.map(\.id) == [kept.id])
        let recovered = try await reopened.fact(id: retired.id)
        #expect(recovered?.invalidatedAt == epoch)
    }

    @Test("an absent file is created holding an empty envelope")
    func createsEmptyEnvelope() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try FileFactStore(fileURL: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try await store.allIDs().isEmpty)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\"schemaVersion\""))
        // Reopening an empty store is not an error.
        let again = try FileFactStore(fileURL: url)
        #expect(try await again.allIDs().isEmpty)
    }

    @Test("a zero-byte file is treated as empty, not corrupt")
    func zeroByteFileIsEmpty() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let store = try FileFactStore(fileURL: url)
        #expect(try await store.allIDs().isEmpty)
    }

    @Test("a garbage file throws corruptStore rather than silently resetting")
    func garbageThrows() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{ this is not json".utf8).write(to: url)
        var caught: MemoryError?
        do {
            _ = try FileFactStore(fileURL: url)
        } catch let error as MemoryError {
            caught = error
        }
        guard case let .corruptStore(path, _)? = caught else {
            Issue.record("expected corruptStore, got \(String(describing: caught))")
            return
        }
        #expect(path == url.path)
    }

    @Test("a truncated snapshot throws corruptStore")
    func truncatedThrows() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let store = try FileFactStore(fileURL: url)
            try await store.upsert([makeFact(text: "Ada")])
        }
        let full = try Data(contentsOf: url)
        try full.prefix(full.count / 2).write(to: url)
        #expect(throws: MemoryError.self) { _ = try FileFactStore(fileURL: url) }
    }

    @Test("an unknown schema version throws schemaVersionUnsupported")
    func schemaVersionThrows() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let store = try FileFactStore(fileURL: url)
            try await store.upsert([makeFact(text: "Ada")])
        }
        var object = try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as! [String: Any]
        object["schemaVersion"] = 99
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        var caught: MemoryError?
        do {
            _ = try FileFactStore(fileURL: url)
        } catch let error as MemoryError {
            caught = error
        }
        #expect(caught == .schemaVersionUnsupported(found: 99, supported: FileFactStore.schemaVersion))
    }

    @Test("a fact with an impossible field makes the whole store corrupt")
    func badFactCorruptsStore() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let store = try FileFactStore(fileURL: url)
            try await store.upsert([makeFact(text: "Ada")])
        }
        var object = try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as! [String: Any]
        var facts = object["facts"] as! [[String: Any]]
        facts[0]["importance"] = 0
        object["facts"] = facts
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        #expect(throws: MemoryError.self) { _ = try FileFactStore(fileURL: url) }
    }

    @Test("sequential mutations always leave a decodable file")
    func sequentialMutationsStayDecodable() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try FileFactStore(fileURL: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for i in 0..<12 {
            try await store.upsert([makeFact(predicate: "p\(i)", text: "fact \(i)")])
            let snapshot = try decoder.decode(FileFactStore.Snapshot.self, from: try Data(contentsOf: url))
            #expect(snapshot.schemaVersion == FileFactStore.schemaVersion)
            #expect(snapshot.facts.count == i + 1)
            // Facts are written in id order, which is what makes the file diff cleanly.
            #expect(snapshot.facts.map(\.id) == snapshot.facts.map(\.id).sorted())
        }
    }

    @Test("re-persisting an unchanged store is byte-identical")
    func rewriteIsByteStable() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try FileFactStore(fileURL: url)
        try await store.upsert([
            makeFact(predicate: "p1", text: "one", tags: ["b", "a", "c"]),
            makeFact(predicate: "p2", text: "two"),
        ])
        let first = try Data(contentsOf: url)
        for _ in 0..<5 {
            try await store.flush()
            #expect(try Data(contentsOf: url) == first)
        }
    }

    @Test("touching unknown ids writes nothing")
    func touchUnknownSkipsWrite() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try FileFactStore(fileURL: url)
        try await store.upsert([makeFact(text: "Ada")])
        let before = try Data(contentsOf: url)
        try await store.touch(ids: ["missing"], at: epoch.addingTimeInterval(9999))
        #expect(try Data(contentsOf: url) == before)
    }

    @Test("the file store answers queries identically to the in-memory one")
    func semanticsMatchInMemory() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let facts = [
            makeFact(predicate: "p1", text: "green tea", tags: ["preference"]),
            makeFact(predicate: "p2", text: "Dublin", confidence: 0.4),
            makeFact(predicate: "p3", text: "derived thing", origin: .derived),
        ]
        let memory = InMemoryFactStore()
        let file = try FileFactStore(fileURL: url)
        try await memory.upsert(facts)
        try await file.upsert(facts)
        for query in [
            MemoryQuery(now: epoch),
            MemoryQuery(now: epoch, tagsAny: ["preference"]),
            MemoryQuery(now: epoch, minConfidence: 0.5),
            MemoryQuery(now: epoch, minimumOrigin: .assistantStated),
            MemoryQuery(now: epoch, order: .idAscending),
        ] {
            let a = try await memory.query(query).map(\.id)
            let b = try await file.query(query).map(\.id)
            #expect(a == b)
        }
        let simA = try await memory.similar(to: "green tea", slot: nil, threadID: nil, limit: 5, now: epoch)
        let simB = try await file.similar(to: "green tea", slot: nil, threadID: nil, limit: 5, now: epoch)
        #expect(simA.map(\.fact.id) == simB.map(\.fact.id))
    }
}
