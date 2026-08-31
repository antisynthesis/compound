import Foundation

/// Pure-Swift, in-memory BM25 lexical retriever. Suitable for
/// tens-of-thousands of chunks; for larger corpora plug in a
/// SQLite-FTS-backed retriever instead.
///
/// Implements Robertson/Zaragoza BM25 with default `k1 = 1.2` and
/// `b = 0.75`, matching the textbook configuration most off-the-shelf
/// implementations use.
public actor BM25Retriever: Retriever {
    /// Indexed wrapper around a single ``DocumentChunk``.
    public struct Document: Sendable {
        /// Source chunk.
        public let chunk: DocumentChunk
        /// Tokenized content.
        public let tokens: [String]
        /// Token count for length normalization.
        public let length: Int
        /// Precomputed per-document term frequencies. Built at index time
        /// so ``BM25Retriever/retrieve(query:limit:)`` does not pay an
        /// O(L) scan per (query, doc).
        public let termCounts: [String: Int]
    }

    /// The index proper, factored out of the actor so ``init`` can build
    /// it without calling actor-isolated methods on a partially
    /// initialized `self` — and so every mutation goes through one place
    /// that keeps `documentFrequency`, `totalLength`, and `averageLength`
    /// in lockstep with `documents`.
    internal struct Store: Sendable {
        var documents: [Document] = []
        /// chunk id -> position in `documents`. Makes upsert and remove
        /// O(1) lookups instead of a linear scan.
        var positions: [String: Int] = [:]
        var documentFrequency: [String: Int] = [:]  // term -> doc count
        // Running sum of document lengths so average length is an O(1)
        // division instead of an O(D) reduce per index.
        var totalLength: Int = 0
        var averageLength: Double = 0

        /// Inserts `document`, replacing any existing entry with the same
        /// chunk id. Replacement retracts the old posting's contribution
        /// first, so `documentFrequency` and the length statistics end up
        /// exactly as if only the new version had ever been indexed.
        mutating func upsert(_ document: Document) {
            if let i = positions[document.chunk.id] {
                retract(documents[i])
                documents[i] = document
            } else {
                positions[document.chunk.id] = documents.count
                documents.append(document)
            }
            apply(document)
            recomputeAverage()
        }

        /// Removes the document with `id`. Returns `true` if one was
        /// present. Insertion order of the survivors is preserved so
        /// downstream iteration stays predictable.
        @discardableResult
        mutating func remove(id: String) -> Bool {
            guard let i = positions.removeValue(forKey: id) else { return false }
            retract(documents[i])
            documents.remove(at: i)
            // Everything after the hole shifted down by one.
            for j in i..<documents.count { positions[documents[j].chunk.id] = j }
            recomputeAverage()
            return true
        }

        mutating func removeAll() {
            documents.removeAll()
            positions.removeAll()
            documentFrequency.removeAll()
            totalLength = 0
            averageLength = 0
        }

        // `apply` and `retract` adjust the term and length totals only.
        // The average is a function of `documents.count` as well, so it is
        // recomputed by the caller *after* the array has been resized —
        // recomputing here would divide by a stale count.
        private mutating func apply(_ document: Document) {
            for term in document.termCounts.keys {
                documentFrequency[term, default: 0] += 1
            }
            totalLength += document.length
        }

        private mutating func retract(_ document: Document) {
            for term in document.termCounts.keys {
                guard let count = documentFrequency[term] else { continue }
                // Drop the key outright at zero rather than leaving a 0
                // entry behind: an index that has had a document removed
                // must be indistinguishable from one that never saw it.
                if count <= 1 {
                    documentFrequency.removeValue(forKey: term)
                } else {
                    documentFrequency[term] = count - 1
                }
            }
            totalLength -= document.length
        }

        private mutating func recomputeAverage() {
            averageLength = documents.isEmpty ? 0 : Double(totalLength) / Double(documents.count)
        }
    }

    // `internal` so the test target (which imports @testable) can assert on
    // the precomputed termCounts invariant. External callers should not
    // depend on these fields — the public surface is retrieve / count.
    internal var store = Store()
    internal var documents: [Document] { store.documents }
    internal var documentFrequency: [String: Int] { store.documentFrequency }
    private let k1: Double
    private let b: Double
    private let tokenizer: @Sendable (String) -> [String]

    /// Creates a BM25 index over `chunks`.
    ///
    /// Chunks are upserted, so a corpus containing the same chunk id
    /// twice indexes it once — the last occurrence wins.
    ///
    /// - Parameters:
    ///   - chunks: Initial corpus.
    ///   - k1: Term-frequency saturation parameter.
    ///   - b: Length-normalization parameter.
    ///   - tokenizer: Function used to split documents and queries into
    ///     tokens. Defaults to ``defaultTokenize``.
    public init(
        chunks: [DocumentChunk] = [],
        k1: Double = 1.2,
        b: Double = 0.75,
        tokenizer: @escaping @Sendable (String) -> [String] = BM25Retriever.defaultTokenize
    ) {
        self.k1 = k1
        self.b = b
        self.tokenizer = tokenizer
        // Build into a local so the init never touches actor-isolated
        // methods on a partially initialized self.
        var store = Store()
        for chunk in chunks {
            store.upsert(BM25Retriever.makeDocument(chunk, tokenizer: tokenizer))
        }
        self.store = store
    }

    /// Indexes a single chunk, replacing any previously indexed chunk
    /// with the same ``DocumentChunk/id``.
    ///
    /// Replacement is a true upsert: the superseded posting's
    /// contribution to document frequency and to the average document
    /// length is retracted first, so the index is identical to one that
    /// only ever saw the new version.
    public func index(_ chunk: DocumentChunk) {
        store.upsert(BM25Retriever.makeDocument(chunk, tokenizer: tokenizer))
    }

    /// Indexes multiple chunks in a batch, each with the upsert
    /// semantics of ``index(_:)-3l3qj``.
    public func index(_ chunks: [DocumentChunk]) {
        for c in chunks {
            store.upsert(BM25Retriever.makeDocument(c, tokenizer: tokenizer))
        }
    }

    /// Removes the chunk with `id` from the index.
    ///
    /// Document frequency and the average document length are restored
    /// exactly to what they would be had the chunk never been indexed.
    ///
    /// - Returns: `true` if a chunk was removed, `false` if `id` was not
    ///   indexed.
    @discardableResult
    public func remove(id: String) -> Bool {
        store.remove(id: id)
    }

    /// Removes several chunks. Returns the number actually removed.
    @discardableResult
    public func remove(ids: [String]) -> Int {
        ids.reduce(0) { $0 + (store.remove(id: $1) ? 1 : 0) }
    }

    /// Empties the index, resetting all corpus statistics.
    public func removeAll() {
        store.removeAll()
    }

    /// Whether a chunk with `id` is currently indexed.
    public func contains(id: String) -> Bool {
        store.positions[id] != nil
    }

    private static func makeDocument(_ chunk: DocumentChunk, tokenizer: @Sendable (String) -> [String]) -> Document {
        let tokens = tokenizer(chunk.content)
        var counts: [String: Int] = [:]
        counts.reserveCapacity(tokens.count)
        for t in tokens { counts[t, default: 0] += 1 }
        return Document(chunk: chunk, tokens: tokens, length: tokens.count, termCounts: counts)
    }

    /// Scores every indexed document against `query` and returns the
    /// top-`limit` results ordered by descending BM25 score.
    ///
    /// Equal scores break by chunk id ascending, so the ranking is a
    /// function of the corpus contents alone — not of insertion order,
    /// and not of `sort`'s unspecified behaviour on equal elements. That
    /// matters for ``HybridRetriever``, which fuses by rank.
    public func retrieve(query: String, limit: Int) async throws -> [RetrievedSource] {
        let documents = store.documents
        let documentFrequency = store.documentFrequency
        let averageLength = store.averageLength
        let qTokens = tokenizer(query)
        guard !documents.isEmpty, !qTokens.isEmpty else { return [] }
        let N = Double(documents.count)
        // De-duplicate query terms so a query like "quick quick fox" doesn't
        // double-count the contribution from "quick". BM25 scores are
        // additive across distinct query terms.
        let uniqueQueryTerms = Array(Set(qTokens))
        var scored: [(Document, Double)] = []
        scored.reserveCapacity(documents.count)
        for doc in documents {
            var score: Double = 0
            let docLen = Double(doc.length)
            for term in uniqueQueryTerms {
                guard let tfRaw = doc.termCounts[term], tfRaw > 0 else { continue }
                let tf = Double(tfRaw)
                let df = Double(documentFrequency[term] ?? 0)
                guard df > 0 else { continue }
                let idf = log((N - df + 0.5) / (df + 0.5) + 1.0)
                let normalized = tf * (k1 + 1) / (tf + k1 * (1 - b + b * docLen / max(averageLength, 1)))
                score += idf * normalized
            }
            if score > 0 { scored.append((doc, score)) }
        }
        scored.sort { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            return a.0.chunk.id < b.0.chunk.id
        }
        return scored.prefix(limit).map { entry in
            RetrievedSource(
                id: entry.0.chunk.id,
                title: entry.0.chunk.documentID + "#\(entry.0.chunk.ordinal)",
                content: entry.0.chunk.content,
                score: entry.1
            )
        }
    }

    /// Number of indexed documents.
    public var count: Int { store.documents.count }

    /// Mean document length in tokens, or `0` when the index is empty.
    /// Exposed because it is the statistic upsert and remove must keep
    /// honest.
    public var averageDocumentLength: Double { store.averageLength }

    /// Number of indexed documents containing `term`, after the index's
    /// own tokenizer normalization. `0` when the term is absent.
    public func documentFrequency(of term: String) -> Int {
        store.documentFrequency[term] ?? 0
    }

    /// Default tokenizer. Lowercases, NFC-normalizes, and splits on
    /// non-alphanumeric characters. Diacritics are preserved (use
    /// ``makeTokenizer(foldDiacritics:)`` to fold them).
    ///
    /// Single-character tokens are retained so technical terms like
    /// `"C"` (language) or `"R"` (tree) remain queryable.
    public static let defaultTokenize: @Sendable (String) -> [String] = { text in
        tokenize(text, foldDiacritics: false)
    }

    /// Builds a tokenizer with optional diacritic folding. Pass `true`
    /// to collapse "résumé" and "resume" into the same token.
    public static func makeTokenizer(foldDiacritics: Bool) -> @Sendable (String) -> [String] {
        { @Sendable text in tokenize(text, foldDiacritics: foldDiacritics) }
    }

    private static func tokenize(_ text: String, foldDiacritics: Bool) -> [String] {
        var normalized = text.precomposedStringWithCanonicalMapping
        if foldDiacritics {
            // To fold diacritics off precomposed characters (e.g. U+00E9
            // "é") we must first decompose to base + combining mark and
            // then strip the combining marks. Stripping in NFC form is a
            // no-op for precomposed characters.
            let decomposed = normalized.decomposedStringWithCanonicalMapping
            normalized = decomposed.applyingTransform(.stripCombiningMarks, reverse: false) ?? decomposed
        }
        return normalized
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
