import Foundation
import Testing
@testable import Compound

@Suite("Retrieval")
struct RetrievalTests {
    @Test("sliding window chunker produces overlapping chunks")
    func slidingWindowOverlap() {
        let text = String(repeating: "a", count: 1000)
        let chunks = DocumentChunker.slidingWindow(text: text, documentID: "doc", windowSize: 400, overlap: 80)
        #expect(chunks.count == 3)
        #expect(chunks[0].ordinal == 0)
        #expect(chunks[0].content.count == 400)
    }

    @Test("paragraph chunker respects soft cap")
    func paragraphSoftCap() {
        let text = "p1\n\np2 long " + String(repeating: "x", count: 500) + "\n\np3"
        let chunks = DocumentChunker.paragraphs(text: text, documentID: "doc", softMaxChars: 400)
        #expect(chunks.count >= 2)
        #expect(chunks.contains { $0.content.contains("p1") })
        #expect(chunks.contains { $0.content.contains("p3") })
    }

    @Test("paragraph chunker handles bare CR line endings")
    func paragraphBareCR() {
        let text = "first\r\rsecond\r\rthird"
        let chunks = DocumentChunker.paragraphs(text: text, documentID: "doc", softMaxChars: 5)
        #expect(chunks.count == 3)
        #expect(chunks[0].content == "first")
        #expect(chunks[1].content == "second")
        #expect(chunks[2].content == "third")
    }

    @Test("paragraph chunker treats whitespace-only blank lines as separators")
    func paragraphBlankWhitespace() {
        let text = "alpha\n \t \nbeta\n\t\ngamma"
        let chunks = DocumentChunker.paragraphs(text: text, documentID: "doc", softMaxChars: 5)
        #expect(chunks.count == 3)
        #expect(chunks[0].content == "alpha")
        #expect(chunks[1].content == "beta")
        #expect(chunks[2].content == "gamma")
    }

    @Test("bm25 ranks more-relevant chunk higher")
    func bm25Ranks() async throws {
        let chunks = [
            DocumentChunk(documentID: "d", ordinal: 0, content: "the quick brown fox jumps over the lazy dog"),
            DocumentChunk(documentID: "d", ordinal: 1, content: "a totally unrelated sentence about astronomy"),
            DocumentChunk(documentID: "d", ordinal: 2, content: "another sentence with quick fox quick"),
        ]
        let bm25 = BM25Retriever(chunks: chunks)
        let results = try await bm25.retrieve(query: "quick fox", limit: 3)
        #expect(results.count == 2)
        #expect(!results.contains { $0.id == chunks[1].id })
        #expect(results[0].id == chunks[2].id)
    }

    @Test("bm25 surfaces single-character query terms")
    func bm25SingleCharTerm() async throws {
        let chunks = [
            DocumentChunk(documentID: "d", ordinal: 0, content: "I program in C every day"),
            DocumentChunk(documentID: "d", ordinal: 1, content: "Swift is my favorite language"),
        ]
        let bm25 = BM25Retriever(chunks: chunks)
        let results = try await bm25.retrieve(query: "c", limit: 5)
        #expect(results.count == 1)
        #expect(results[0].id == chunks[0].id)
    }

    @Test("bm25 NFC-normalizes so NFD inputs match composed queries")
    func bm25NFCNormalizes() async throws {
        let decomposed = "cafe\u{0301}"
        let composedScalars = "caf\u{00E9}".unicodeScalars.map { $0.value }
        let tokens = BM25Retriever.defaultTokenize("the \(decomposed) is open")
        let cafeToken = tokens.first { $0 == "caf\u{00E9}" }
        #expect(cafeToken != nil, "tokenizer should emit a cafe-token, got: \(tokens)")
        let tokenScalars = cafeToken!.unicodeScalars.map { $0.value }
        #expect(tokenScalars == composedScalars)
        let chunks = [
            DocumentChunk(documentID: "d", ordinal: 0, content: "we love the \(decomposed) downtown"),
        ]
        let bm25 = BM25Retriever(chunks: chunks)
        let results = try await bm25.retrieve(query: "caf\u{00E9}", limit: 5)
        #expect(results.count == 1)
    }

    @Test("bm25 optional diacritic folding collapses resume/résumé")
    func bm25DiacriticFold() {
        let folder = BM25Retriever.makeTokenizer(foldDiacritics: true)
        let folded = folder("R\u{00E9}sum\u{00E9}")
        #expect(folded.contains("resume"), "diacritic fold should produce 'resume', got: \(folded)")
    }

    @Test("bm25 termCounts precomputed at index time")
    func bm25TermCountsPrecomputed() async throws {
        let bm25 = BM25Retriever()
        await bm25.index(DocumentChunk(documentID: "d", ordinal: 0, content: "foo bar foo baz foo"))
        await bm25.index(DocumentChunk(documentID: "d", ordinal: 1, content: "bar bar baz"))
        let docs = await bm25.documents
        #expect(docs.count == 2)
        #expect(docs[0].termCounts["foo"] == 3)
        #expect(docs[0].termCounts["bar"] == 1)
        #expect(docs[0].termCounts["baz"] == 1)
        #expect((docs[1].termCounts["foo"] ?? 0) == 0)
        #expect(docs[1].termCounts["bar"] == 2)
    }

    @Test("dense retriever throws on dimension mismatch")
    func denseDimensionMismatch() async throws {
        actor StubProvider: EmbeddingProvider {
            var nextDim: Int = 4
            func setDim(_ d: Int) { nextDim = d }
            func embed(_: String) async throws -> [Double] {
                Array(repeating: 0.5, count: nextDim)
            }
        }
        let provider = StubProvider()
        let retriever = DenseRetriever(provider: provider)
        try await retriever.index(DocumentChunk(documentID: "d", ordinal: 0, content: "first"))
        await provider.setDim(8)
        await #expect(throws: EmbeddingError.self) {
            try await retriever.index(DocumentChunk(documentID: "d", ordinal: 1, content: "second"))
        }
    }

    @Test("dense retriever returns ranked results with pre-normalized vectors")
    func denseRanked() async throws {
        struct CannedProvider: EmbeddingProvider {
            let vectors: [String: [Double]]
            func embed(_ text: String) async throws -> [Double] {
                vectors[text] ?? [0, 0, 0]
            }
        }
        let provider = CannedProvider(vectors: [
            "match":   [1, 0, 0],
            "near":    [0.9, 0.1, 0],
            "far":     [0, 1, 0],
            "match q": [1, 0, 0],
        ])
        let retriever = DenseRetriever(provider: provider)
        try await retriever.index([
            DocumentChunk(documentID: "d", ordinal: 0, content: "match"),
            DocumentChunk(documentID: "d", ordinal: 1, content: "near"),
            DocumentChunk(documentID: "d", ordinal: 2, content: "far"),
        ])
        let results = try await retriever.retrieve(query: "match q", limit: 3)
        #expect(results.count == 3)
        #expect(results[0].content == "match")
        #expect(results[1].content == "near")
        #expect(results[2].content == "far")
    }

    @Test("hybrid retriever fuses two retrievers with RRF")
    func hybridFusesRRF() async throws {
        struct CannedRetriever: Retriever {
            let order: [String]
            func retrieve(query _: String, limit: Int) async throws -> [RetrievedSource] {
                order.prefix(limit).map { RetrievedSource(id: $0, title: $0, content: $0, score: nil) }
            }
        }
        let r1 = CannedRetriever(order: ["top", "mid", "bot"])
        let r2 = CannedRetriever(order: ["top", "x", "mid"])
        let hybrid = HybridRetriever(retrievers: [r1, r2])
        let fused = try await hybrid.retrieve(query: "_", limit: 4)
        #expect(Set(fused.map(\.id)).isSuperset(of: ["top", "mid"]))
        #expect(fused[0].id == "top")
    }

    @Test("hybrid retriever runs member retrievers in parallel")
    func hybridParallel() async throws {
        struct SlowRetriever: Retriever {
            let id: String
            let delay: Duration
            func retrieve(query _: String, limit _: Int) async throws -> [RetrievedSource] {
                try await Task.sleep(for: delay)
                return [RetrievedSource(id: id, title: id, content: id, score: nil)]
            }
        }
        let r1 = SlowRetriever(id: "a", delay: .milliseconds(100))
        let r2 = SlowRetriever(id: "b", delay: .milliseconds(100))
        let hybrid = HybridRetriever(retrievers: [r1, r2])
        let start = ContinuousClock().now
        _ = try await hybrid.retrieve(query: "_", limit: 5)
        let elapsed = ContinuousClock().now - start
        #expect(elapsed < .milliseconds(180), "parallel fan-out expected, took \(elapsed)")
    }

    @Test("hybrid retriever breaks ties deterministically by source id")
    func hybridDeterministicTiebreak() async throws {
        struct CannedRetriever: Retriever {
            let order: [String]
            func retrieve(query _: String, limit: Int) async throws -> [RetrievedSource] {
                order.prefix(limit).map { RetrievedSource(id: $0, title: $0, content: $0, score: nil) }
            }
        }
        let r = CannedRetriever(order: ["zebra", "apple", "mango"])
        let hybrid = HybridRetriever(retrievers: [r])
        let first = try await hybrid.retrieve(query: "_", limit: 3).map(\.id)
        let second = try await hybrid.retrieve(query: "_", limit: 3).map(\.id)
        #expect(first == second)
    }

    @Test("identity reranker returns top N")
    func identityRerankerTopN() async throws {
        let reranker = IdentityReranker()
        let inputs = (0..<10).map { RetrievedSource(id: "\($0)", title: "", content: "", score: Double($0)) }
        let out = try await reranker.rerank(query: "_", candidates: inputs, limit: 3)
        #expect(out.count == 3)
    }

    @Test("token-budgeted assembler drops low-score sources")
    func tokenBudgetedDropsLowScore() async throws {
        struct StaticAssembler: ContextAssembler {
            let sources: [RetrievedSource]
            func assemble(userPrompt: String, runContext _: RunContext) async throws -> AssembledContext {
                AssembledContext(instructions: "", userPrompt: userPrompt, sources: sources, redactionsApplied: [])
            }
        }
        let big = String(repeating: "x", count: 1000)
        let sources = [
            RetrievedSource(id: "a", title: "A", content: big, score: 0.9),
            RetrievedSource(id: "b", title: "B", content: big, score: 0.1),
            RetrievedSource(id: "c", title: "C", content: big, score: 0.5),
        ]
        let inner = StaticAssembler(sources: sources)
        let assembler = TokenBudgetedAssembler(wrapping: inner, maxPromptTokens: 400)
        let assembled = try await assembler.assemble(userPrompt: "hi", runContext: RunContext())
        #expect(assembled.sources.count < sources.count)
        #expect(assembled.sources.contains { $0.id == "a" })
    }
}
