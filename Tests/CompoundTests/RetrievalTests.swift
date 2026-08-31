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

    @Test("bm25 re-indexing the same id leaves corpus statistics untouched")
    func bm25UpsertIsIdempotent() async throws {
        let chunk = DocumentChunk(documentID: "d", ordinal: 0, content: "alpha beta beta gamma")
        let other = DocumentChunk(documentID: "d", ordinal: 1, content: "beta delta")
        let once = BM25Retriever(chunks: [chunk, other])
        let repeated = BM25Retriever(chunks: [chunk, other])
        await repeated.index(chunk)
        await repeated.index([chunk, other, chunk])

        let onceCount = await once.count
        let repeatedCount = await repeated.count
        #expect(onceCount == 2)
        #expect(repeatedCount == onceCount)
        let onceDF = await once.documentFrequency
        let repeatedDF = await repeated.documentFrequency
        #expect(repeatedDF == onceDF, "df must not double-count a re-indexed chunk")
        let onceAvg = await once.averageDocumentLength
        let repeatedAvg = await repeated.averageDocumentLength
        #expect(repeatedAvg == onceAvg)
    }

    @Test("bm25 init deduplicates a corpus containing repeated ids")
    func bm25InitDeduplicates() async throws {
        let chunk = DocumentChunk(documentID: "d", ordinal: 0, content: "alpha beta")
        let single = BM25Retriever(chunks: [chunk])
        let duplicated = BM25Retriever(chunks: [chunk, chunk, chunk])
        let singleCount = await single.count
        let duplicatedCount = await duplicated.count
        #expect(duplicatedCount == singleCount)
        let singleDF = await single.documentFrequency
        let duplicatedDF = await duplicated.documentFrequency
        #expect(duplicatedDF == singleDF)
    }

    @Test("bm25 upsert with new content replaces the old posting")
    func bm25UpsertReplacesContent() async throws {
        let neighbor = DocumentChunk(documentID: "d", ordinal: 9, content: "neighbor text")
        let v1 = DocumentChunk(id: "fixed", documentID: "d", ordinal: 0, content: "alpha alpha beta")
        let v2 = DocumentChunk(id: "fixed", documentID: "d", ordinal: 0, content: "gamma")
        let updated = BM25Retriever(chunks: [neighbor, v1])
        await updated.index(v2)
        let fresh = BM25Retriever(chunks: [neighbor, v2])

        let updatedDF = await updated.documentFrequency
        let freshDF = await fresh.documentFrequency
        #expect(updatedDF == freshDF, "stale terms must be retracted, not left at df 0")
        #expect(updatedDF["alpha"] == nil)
        let updatedAvg = await updated.averageDocumentLength
        let freshAvg = await fresh.averageDocumentLength
        #expect(updatedAvg == freshAvg)

        // The superseded content is genuinely unreachable.
        let stale = try await updated.retrieve(query: "alpha", limit: 5)
        #expect(stale.isEmpty)
        let current = try await updated.retrieve(query: "gamma", limit: 5)
        #expect(current.map(\.id) == ["fixed"])
        #expect(current[0].content == "gamma")
    }

    @Test("bm25 remove restores statistics to a never-indexed state")
    func bm25RemoveRestoresStats() async throws {
        let a = DocumentChunk(documentID: "d", ordinal: 0, content: "foo bar")
        let b = DocumentChunk(documentID: "d", ordinal: 1, content: "bar baz baz qux")
        let c = DocumentChunk(documentID: "d", ordinal: 2, content: "qux foo")
        let pruned = BM25Retriever(chunks: [a, b, c])
        let removed = await pruned.remove(id: b.id)
        #expect(removed)
        let fresh = BM25Retriever(chunks: [a, c])

        let prunedCount = await pruned.count
        let freshCount = await fresh.count
        #expect(prunedCount == freshCount)
        let prunedDF = await pruned.documentFrequency
        let freshDF = await fresh.documentFrequency
        #expect(prunedDF == freshDF)
        #expect(prunedDF["baz"] == nil, "a term unique to the removed doc must leave no residue")
        let prunedAvg = await pruned.averageDocumentLength
        let freshAvg = await fresh.averageDocumentLength
        #expect(prunedAvg == freshAvg)
        let prunedOrder = await pruned.documents.map(\.chunk.id)
        let freshOrder = await fresh.documents.map(\.chunk.id)
        #expect(prunedOrder == freshOrder, "removal preserves insertion order of survivors")

        let contains = await pruned.contains(id: b.id)
        #expect(!contains)
        let missing = await pruned.remove(id: "not-indexed")
        #expect(!missing)
    }

    @Test("bm25 removeAll resets the index to empty")
    func bm25RemoveAll() async throws {
        let bm25 = BM25Retriever(chunks: [
            DocumentChunk(documentID: "d", ordinal: 0, content: "foo bar"),
            DocumentChunk(documentID: "d", ordinal: 1, content: "baz"),
        ])
        await bm25.removeAll()
        let count = await bm25.count
        #expect(count == 0)
        let df = await bm25.documentFrequency
        #expect(df.isEmpty)
        let avg = await bm25.averageDocumentLength
        #expect(avg == 0)
        let results = try await bm25.retrieve(query: "foo", limit: 5)
        #expect(results.isEmpty)
    }

    @Test("bm25 remove(ids:) reports how many were indexed")
    func bm25RemoveBatch() async throws {
        let a = DocumentChunk(documentID: "d", ordinal: 0, content: "foo")
        let b = DocumentChunk(documentID: "d", ordinal: 1, content: "bar")
        let bm25 = BM25Retriever(chunks: [a, b])
        let n = await bm25.remove(ids: [a.id, "absent", b.id])
        #expect(n == 2)
        let count = await bm25.count
        #expect(count == 0)
    }

    @Test("bm25 breaks score ties by chunk id")
    func bm25TieBreak() async throws {
        // Identical content at different ordinals scores identically; only
        // the id can order them, and it must do so the same way every run.
        let chunks = (0..<5).map { DocumentChunk(documentID: "d", ordinal: $0, content: "same tokens here") }
        let bm25 = BM25Retriever(chunks: chunks)
        let first = try await bm25.retrieve(query: "tokens", limit: 5).map(\.id)
        let second = try await bm25.retrieve(query: "tokens", limit: 5).map(\.id)
        #expect(first.count == 5)
        #expect(first == second)
        #expect(first == first.sorted())
    }

    @Test("dense retriever re-indexing the same id replaces rather than duplicates")
    func denseUpsertReplaces() async throws {
        struct CannedProvider: EmbeddingProvider {
            let vectors: [String: [Double]]
            func embed(_ text: String) async throws -> [Double] {
                vectors[text] ?? [0, 0, 1]
            }
        }
        let provider = CannedProvider(vectors: [
            "old": [1, 0, 0],
            "new": [0, 1, 0],
            "q":   [0, 1, 0],
        ])
        let retriever = DenseRetriever(provider: provider)
        let v1 = DocumentChunk(id: "fixed", documentID: "d", ordinal: 0, content: "old")
        let v2 = DocumentChunk(id: "fixed", documentID: "d", ordinal: 0, content: "new")
        try await retriever.index(v1)
        try await retriever.index(v2)
        let count = await retriever.count
        #expect(count == 1, "same id must not produce a second entry")
        let results = try await retriever.retrieve(query: "q", limit: 5)
        #expect(results.count == 1)
        #expect(results[0].content == "new")

        // Batch indexing carries the same semantics.
        try await retriever.index([v1, v2])
        let afterBatch = await retriever.count
        #expect(afterBatch == 1)
    }

    @Test("dense retriever remove and removeAll match a fresh index")
    func denseRemoveParity() async throws {
        struct CannedProvider: EmbeddingProvider {
            func embed(_ text: String) async throws -> [Double] {
                [Double(text.count), 1, 0]
            }
        }
        let a = DocumentChunk(documentID: "d", ordinal: 0, content: "a")
        let b = DocumentChunk(documentID: "d", ordinal: 1, content: "bb")
        let c = DocumentChunk(documentID: "d", ordinal: 2, content: "ccc")
        let pruned = DenseRetriever(provider: CannedProvider())
        try await pruned.index([a, b, c])
        let removed = await pruned.remove(id: b.id)
        #expect(removed)
        let fresh = DenseRetriever(provider: CannedProvider())
        try await fresh.index([a, c])

        let prunedResults = try await pruned.retrieve(query: "aa", limit: 10)
        let freshResults = try await fresh.retrieve(query: "aa", limit: 10)
        #expect(prunedResults.map(\.id) == freshResults.map(\.id))
        #expect(prunedResults.map(\.score) == freshResults.map(\.score))

        let stillThere = await pruned.contains(id: b.id)
        #expect(!stillThere)
        let missing = await pruned.remove(id: "absent")
        #expect(!missing)

        await pruned.removeAll()
        let count = await pruned.count
        #expect(count == 0)
        let dim = await pruned.indexedDimension
        #expect(dim == nil, "an emptied index must accept a new dimension")
    }

    @Test("dense retriever breaks score ties by chunk id")
    func denseTieBreak() async throws {
        struct CannedProvider: EmbeddingProvider {
            func embed(_: String) async throws -> [Double] { [1, 0, 0] }
        }
        let retriever = DenseRetriever(provider: CannedProvider())
        try await retriever.index((0..<5).map { DocumentChunk(documentID: "d", ordinal: $0, content: "c\($0)") })
        let first = try await retriever.retrieve(query: "q", limit: 5).map(\.id)
        let second = try await retriever.retrieve(query: "q", limit: 5).map(\.id)
        #expect(first.count == 5)
        #expect(first == second)
        #expect(first == first.sorted())
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

    @Test("hybrid fusion dedupes overlapping ids and ranks deterministically")
    func hybridFusesStableChunkIDs() async throws {
        struct CannedProvider: EmbeddingProvider {
            let vectors: [String: [Double]]
            func embed(_ text: String) async throws -> [Double] {
                vectors[text] ?? [0, 0, 1]
            }
        }
        // Both retrievers see the *same* chunks, so the deterministic ids
        // are what let a document reached by both paths fuse instead of
        // appearing twice at half weight.
        let chunks = [
            DocumentChunk(documentID: "d", ordinal: 0, content: "quick brown fox"),
            DocumentChunk(documentID: "d", ordinal: 1, content: "lazy sleeping dog"),
            DocumentChunk(documentID: "d", ordinal: 2, content: "astronomy and telescopes"),
        ]
        let bm25 = BM25Retriever(chunks: chunks)
        let dense = DenseRetriever(provider: CannedProvider(vectors: [
            "quick brown fox":         [1, 0, 0],
            "lazy sleeping dog":       [0.8, 0.6, 0],
            "astronomy and telescopes": [0, 0, 1],
            "quick fox":               [1, 0, 0],
        ]))
        try await dense.index(chunks)
        let hybrid = HybridRetriever(retrievers: [bm25, dense])

        let first = try await hybrid.retrieve(query: "quick fox", limit: 10)
        let second = try await hybrid.retrieve(query: "quick fox", limit: 10)
        #expect(first.map(\.id) == second.map(\.id), "fusion must be reproducible")
        #expect(Set(first.map(\.id)).count == first.count, "ids must fuse, not duplicate")
        #expect(first[0].id == chunks[0].id, "the chunk both retrievers rank first must win")
        // Agreement beats a single retriever's lone top hit: chunk 0 is
        // rank 1 in both members, so its fused score must exceed anything
        // credited by only one.
        let top = try #require(first.first?.score)
        let runnerUp = try #require(first.dropFirst().first?.score)
        #expect(top > runnerUp)
    }

    @Test("hybrid fusion credits a repeated id once per retriever")
    func hybridDedupesWithinRetriever() async throws {
        struct CannedRetriever: Retriever {
            let order: [String]
            func retrieve(query _: String, limit: Int) async throws -> [RetrievedSource] {
                order.prefix(limit).map { RetrievedSource(id: $0, title: $0, content: $0, score: nil) }
            }
        }
        // "dupe" appears three times in one member's list. Without
        // within-member dedupe it would collect 1/61 + 1/62 + 1/63 and
        // outrank "solo", which a second member also endorses.
        let noisy = CannedRetriever(order: ["dupe", "dupe", "dupe", "solo"])
        let clean = CannedRetriever(order: ["solo", "dupe"])
        let hybrid = HybridRetriever(retrievers: [noisy, clean])
        let fused = try await hybrid.retrieve(query: "_", limit: 10)
        #expect(fused.map(\.id).sorted() == ["dupe", "solo"])
        let dupeScore = try #require(fused.first { $0.id == "dupe" }?.score)
        let expected = 1.0 / 61.0 + 1.0 / 62.0
        #expect(abs(dupeScore - expected) < 1e-12, "one credit per retriever, at its best rank")
    }

    @Test("hybrid k constant controls how sharply rank is discounted")
    func hybridKConstant() async throws {
        struct CannedRetriever: Retriever {
            let order: [String]
            func retrieve(query _: String, limit: Int) async throws -> [RetrievedSource] {
                order.prefix(limit).map { RetrievedSource(id: $0, title: $0, content: $0, score: nil) }
            }
        }
        let a = CannedRetriever(order: ["solo"])
        let b = CannedRetriever(order: ["agreed", "other"])
        let c = CannedRetriever(order: ["agreed", "other"])
        // k sets how steeply weight falls off with rank. At k = 0 rank 1 is
        // worth double rank 2; at k = 1000 they are within 0.1% of each
        // other and fusion degenerates into counting endorsements.
        let sharp = try await HybridRetriever(retrievers: [a, b, c], k: 0).retrieve(query: "_", limit: 10)
        let sharpAgreed = try #require(sharp.first { $0.id == "agreed" }?.score)
        let sharpOther = try #require(sharp.first { $0.id == "other" }?.score)
        #expect(abs(sharpAgreed - 2.0) < 1e-12)
        #expect(abs(sharpOther - 1.0) < 1e-12)

        let flat = try await HybridRetriever(retrievers: [a, b, c], k: 1000).retrieve(query: "_", limit: 10)
        let flatAgreed = try #require(flat.first { $0.id == "agreed" }?.score)
        let flatOther = try #require(flat.first { $0.id == "other" }?.score)
        #expect(flatAgreed / flatOther < 1.01)
        #expect(sharpAgreed / sharpOther > 1.9)
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
