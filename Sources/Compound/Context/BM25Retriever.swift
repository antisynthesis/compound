import Foundation

/// Pure-Swift, in-memory BM25 lexical retriever. No service, no network,
/// no third party between you and your own corpus — the index lives where
/// the data lives. Suitable for tens-of-thousands of chunks; for larger
/// corpora plug in a SQLite-FTS-backed retriever instead.
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

    // `internal` so the test target (which imports @testable) can assert on
    // the precomputed termCounts invariant. External callers should not
    // depend on these fields — the public surface is retrieve / count.
    internal var documents: [Document] = []
    internal var documentFrequency: [String: Int] = [:]  // term -> doc count
    // Running sum of document lengths, kept in lockstep with `documents` so
    // average length is an O(1) division instead of an O(D) reduce per index.
    private var totalLength: Int = 0
    private var averageLength: Double = 0
    private let k1: Double
    private let b: Double
    private let tokenizer: @Sendable (String) -> [String]

    /// Creates a BM25 index over `chunks`.
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
        // Inline indexing so the init avoids actor-isolated self calls.
        for chunk in chunks {
            let tokens = tokenizer(chunk.content)
            var counts: [String: Int] = [:]
            counts.reserveCapacity(tokens.count)
            for t in tokens { counts[t, default: 0] += 1 }
            for term in counts.keys {
                documentFrequency[term, default: 0] += 1
            }
            documents.append(Document(chunk: chunk, tokens: tokens, length: tokens.count, termCounts: counts))
            totalLength += tokens.count
        }
        if !documents.isEmpty {
            averageLength = Double(totalLength) / Double(documents.count)
        }
    }

    /// Indexes a single chunk. Updates the running average document length.
    public func index(_ chunk: DocumentChunk) {
        indexInternal(chunk)
        updateAverageLength()
    }

    /// Indexes multiple chunks in a batch. Faster than calling
    /// ``index(_:)-3l3qj`` per chunk because the average length is
    /// recomputed once.
    public func index(_ chunks: [DocumentChunk]) {
        for c in chunks { indexInternal(c) }
        updateAverageLength()
    }

    private func indexInternal(_ chunk: DocumentChunk) {
        let tokens = tokenizer(chunk.content)
        var counts: [String: Int] = [:]
        counts.reserveCapacity(tokens.count)
        for t in tokens { counts[t, default: 0] += 1 }
        for term in counts.keys {
            documentFrequency[term, default: 0] += 1
        }
        documents.append(Document(chunk: chunk, tokens: tokens, length: tokens.count, termCounts: counts))
        totalLength += tokens.count
    }

    private func updateAverageLength() {
        guard !documents.isEmpty else { averageLength = 0; return }
        averageLength = Double(totalLength) / Double(documents.count)
    }

    /// Scores every indexed document against `query` and surfaces only the
    /// top-`limit`, ordered by descending BM25 score. Precision over a sea
    /// of irrelevance — the rest stays out of the model's way.
    public func retrieve(query: String, limit: Int) async throws -> [RetrievedSource] {
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
        scored.sort { $0.1 > $1.1 }
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
    public var count: Int { documents.count }

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
