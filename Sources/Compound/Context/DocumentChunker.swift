import Foundation
import CryptoKit

/// One retrievable chunk of a source document, produced by
/// ``DocumentChunker``.
public struct DocumentChunk: Sendable, Equatable, Hashable, Identifiable {
    /// Stable per-chunk identifier. Unless supplied explicitly this is
    /// derived deterministically from `documentID`, `ordinal`, and
    /// `content` — see ``DocumentChunker/chunkID(documentID:ordinal:content:)``.
    public let id: String
    /// Identifier of the source document.
    public let documentID: String
    /// Zero-based index within the document.
    public let ordinal: Int
    /// Chunk text.
    public let content: String
    /// Free-form per-chunk metadata propagated to retrievers.
    public let metadata: [String: String]

    /// Creates a chunk.
    ///
    /// - Parameter id: Explicit identifier. When `nil` (the default) the
    ///   id is derived from `documentID`, `ordinal`, and `content` via
    ///   ``DocumentChunker/chunkID(documentID:ordinal:content:)``, so
    ///   re-chunking the same document always yields the same ids. Pass
    ///   an explicit value only when an external system owns the id
    ///   space.
    public init(id: String? = nil, documentID: String, ordinal: Int, content: String, metadata: [String: String] = [:]) {
        self.id = id ?? DocumentChunker.chunkID(documentID: documentID, ordinal: ordinal, content: content)
        self.documentID = documentID
        self.ordinal = ordinal
        self.content = content
        self.metadata = metadata
    }
}

/// Pure-function chunkers that split a document into ``DocumentChunk``
/// values. Embeddings and indexing happen downstream. Two strategies
/// are bundled: ``slidingWindow(text:documentID:windowSize:overlap:metadata:)``
/// (fixed-size with overlap) and
/// ``paragraphs(text:documentID:softMaxChars:metadata:)`` (paragraph-
/// aligned).
public enum DocumentChunker {
    /// Domain-separation tag mixed into every derived chunk id. Bump the
    /// suffix if the derivation ever changes so stored ground truth can
    /// detect the mismatch instead of silently mis-joining.
    public static let chunkIDDomain = "compound.chunk.v1"

    /// Derives the deterministic identifier for a chunk.
    ///
    /// The id is the first 16 bytes of
    /// `SHA256(domain ‖ documentID ‖ ordinal ‖ content)`, rendered as 32
    /// lowercase hex characters. Every component is length-prefixed with
    /// its big-endian `UInt64` byte count so no two distinct triples can
    /// produce the same pre-image (a plain concatenation would let
    /// `("ab", 0, "c")` and `("a", 0, "bc")` collide).
    ///
    /// `documentID` and `content` are NFC-normalized first, matching the
    /// normalization ``BM25Retriever/defaultTokenize`` applies, so the
    /// same text delivered in NFD and NFC forms lands on one id.
    ///
    /// Metadata is deliberately *not* part of the derivation: the id
    /// names a position in a document's content, not the annotations a
    /// pipeline hangs off it. Re-chunking with different metadata is an
    /// update to the same chunk, and retrievers treat it as one.
    ///
    /// This is the derivation eval ground truth should use to name
    /// expected chunks — it is stable across processes, machines, and
    /// runs.
    public static func chunkID(documentID: String, ordinal: Int, content: String) -> String {
        var hasher = SHA256()
        func absorb(_ bytes: [UInt8]) {
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
            bytes.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        }
        absorb(Array(chunkIDDomain.utf8))
        absorb(Array(documentID.precomposedStringWithCanonicalMapping.utf8))
        absorb(Array(String(ordinal).utf8))
        absorb(Array(content.precomposedStringWithCanonicalMapping.utf8))
        return hasher.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Splits `text` into fixed-size grapheme-cluster windows with
    /// `overlap` characters of context between successive chunks.
    ///
    /// Walks the input via `String.Index` instead of materializing
    /// `Array(text)` so multi-MB inputs do not allocate up front.
    ///
    /// - Parameters:
    ///   - text: The source text.
    ///   - documentID: Identifier propagated to every emitted chunk.
    ///   - windowSize: Window size in grapheme clusters; must be positive.
    ///   - overlap: Number of grapheme clusters shared between adjacent
    ///     chunks; must be in `[0, windowSize)`.
    ///   - metadata: Metadata propagated to every emitted chunk.
    /// - Returns: Chunks in document order.
    public static func slidingWindow(
        text: String,
        documentID: String,
        windowSize: Int = 800,
        overlap: Int = 80,
        metadata: [String: String] = [:]
    ) -> [DocumentChunk] {
        precondition(windowSize > 0, "windowSize must be positive")
        precondition(overlap >= 0 && overlap < windowSize, "overlap must be in [0, windowSize)")
        guard !text.isEmpty else { return [] }
        var out: [DocumentChunk] = []
        var cursor = text.startIndex
        var ordinal = 0
        let step = windowSize - overlap
        let end = text.endIndex
        while cursor < end {
            let windowEnd = text.index(cursor, offsetBy: windowSize, limitedBy: end) ?? end
            let content = String(text[cursor..<windowEnd])
            out.append(DocumentChunk(
                documentID: documentID,
                ordinal: ordinal,
                content: content,
                metadata: metadata
            ))
            if windowEnd == end { break }
            cursor = text.index(cursor, offsetBy: step, limitedBy: end) ?? end
            ordinal += 1
        }
        return out
    }

    /// Splits `text` on blank lines, then re-merges paragraphs while
    /// respecting a soft size cap. Paragraphs larger than `softMaxChars`
    /// pass through unchanged rather than being cut mid-sentence.
    ///
    /// Line endings are normalized (`\r\n` and lone `\r` collapse to
    /// `\n`) so the blank-line split is consistent across input sources.
    public static func paragraphs(
        text: String,
        documentID: String,
        softMaxChars: Int = 800,
        metadata: [String: String] = [:]
    ) -> [DocumentChunk] {
        // Normalize line endings first: CRLF and lone CR (classic Mac) both
        // collapse to "\n" so the blank-line split that follows is
        // consistent across input sources. We then split on a blank line
        // that may contain horizontal whitespace, because hand-written
        // text often leaves stray spaces or tabs on otherwise "empty"
        // separator lines.
        let unified = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let separator = #/\n[ \t]*\n+/#
        var splits: [Substring] = []
        var cursor = unified.startIndex
        for match in unified.matches(of: separator) {
            splits.append(unified[cursor..<match.range.lowerBound])
            cursor = match.range.upperBound
        }
        splits.append(unified[cursor..<unified.endIndex])
        let paragraphs = splits
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var chunks: [DocumentChunk] = []
        var current = ""
        var ordinal = 0
        func flush() {
            if !current.isEmpty {
                chunks.append(DocumentChunk(
                    documentID: documentID,
                    ordinal: ordinal,
                    content: current,
                    metadata: metadata
                ))
                ordinal += 1
                current = ""
            }
        }
        for p in paragraphs {
            if p.count >= softMaxChars {
                flush()
                chunks.append(DocumentChunk(
                    documentID: documentID,
                    ordinal: ordinal,
                    content: p,
                    metadata: metadata
                ))
                ordinal += 1
                continue
            }
            if current.isEmpty {
                current = p
            } else if current.count + p.count + 2 <= softMaxChars {
                current += "\n\n" + p
            } else {
                flush()
                current = p
            }
        }
        flush()
        return chunks
    }
}
