import Foundation
import Testing
@testable import Compound

@Suite("DocumentChunker determinism")
struct ChunkerTests {
    private static let document = """
    Retrieval starts with chunking. A chunk is the unit a retriever scores,
    so the boundaries decide what can ever be recalled.

    Chunk identity is separate from chunk content. An id that changes run to
    run cannot be referenced by eval ground truth and cannot be fused across
    retrievers.

    Deriving the id from the content closes both gaps at once.
    """

    @Test("chunking the same document twice yields identical ids")
    func sameDocumentSameIDs() {
        let first = DocumentChunker.paragraphs(text: Self.document, documentID: "doc", softMaxChars: 40)
        let second = DocumentChunker.paragraphs(text: Self.document, documentID: "doc", softMaxChars: 40)
        #expect(!first.isEmpty)
        #expect(first.map(\.id) == second.map(\.id))
        // Not just equal to each other — equal to a fresh derivation, so an
        // eval fixture can name chunks without running the chunker.
        for chunk in first {
            let derived = DocumentChunker.chunkID(
                documentID: chunk.documentID,
                ordinal: chunk.ordinal,
                content: chunk.content
            )
            #expect(chunk.id == derived)
        }
    }

    @Test("sliding window chunker is deterministic across runs")
    func slidingWindowDeterministic() {
        let text = String(repeating: "lorem ipsum dolor ", count: 200)
        let first = DocumentChunker.slidingWindow(text: text, documentID: "doc", windowSize: 400, overlap: 80)
        let second = DocumentChunker.slidingWindow(text: text, documentID: "doc", windowSize: 400, overlap: 80)
        #expect(first.count > 1)
        #expect(first.map(\.id) == second.map(\.id))
        #expect(Set(first.map(\.id)).count == first.count, "overlapping windows must still get distinct ids")
    }

    @Test("changed content changes the id")
    func changedContentChangesID() {
        let original = DocumentChunker.paragraphs(text: Self.document, documentID: "doc", softMaxChars: 40)
        let edited = DocumentChunker.paragraphs(
            text: Self.document.replacingOccurrences(of: "Deriving", with: "Computing"),
            documentID: "doc",
            softMaxChars: 40
        )
        #expect(original.count == edited.count)
        let changed = zip(original, edited).filter { $0.content != $1.content }
        #expect(!changed.isEmpty, "the edit should have landed in some chunk")
        for (before, after) in changed {
            #expect(before.id != after.id)
        }
        // Untouched chunks keep their ids: an edit late in a document must
        // not invalidate ground truth for the paragraphs before it.
        let unchanged = zip(original, edited).filter { $0.content == $1.content }
        for (before, after) in unchanged {
            #expect(before.id == after.id)
        }
    }

    @Test("document id, ordinal, and content each participate in the derivation")
    func everyComponentParticipates() {
        let base = DocumentChunker.chunkID(documentID: "doc", ordinal: 3, content: "body")
        #expect(base != DocumentChunker.chunkID(documentID: "other", ordinal: 3, content: "body"))
        #expect(base != DocumentChunker.chunkID(documentID: "doc", ordinal: 4, content: "body"))
        #expect(base != DocumentChunker.chunkID(documentID: "doc", ordinal: 3, content: "other"))
        #expect(base == DocumentChunker.chunkID(documentID: "doc", ordinal: 3, content: "body"))
    }

    @Test("length prefixes keep the derivation unambiguous")
    func lengthPrefixedFields() {
        // Without length prefixing these two would hash the same byte
        // stream: "ab" + "c" versus "a" + "bc".
        let left = DocumentChunker.chunkID(documentID: "ab", ordinal: 0, content: "c")
        let right = DocumentChunker.chunkID(documentID: "a", ordinal: 0, content: "bc")
        #expect(left != right)
        // Same trick across the ordinal boundary: ordinal 1 with content
        // "2x" versus ordinal 12 with content "x".
        let a = DocumentChunker.chunkID(documentID: "d", ordinal: 1, content: "2x")
        let b = DocumentChunker.chunkID(documentID: "d", ordinal: 12, content: "x")
        #expect(a != b)
    }

    @Test("unicode-equivalent content lands on one id")
    func nfcNormalized() {
        let composed = "caf\u{00E9} au lait"
        let decomposed = "cafe\u{0301} au lait"
        // Swift's String == is canonical-equivalence based, so these two
        // compare equal as strings. They differ as UTF-8, which is what
        // the hash actually consumes — that is the difference NFC
        // normalization has to erase.
        #expect(
            Array(composed.utf8) != Array(decomposed.utf8),
            "inputs must differ at the byte level for this test to mean anything"
        )
        #expect(
            DocumentChunker.chunkID(documentID: "d", ordinal: 0, content: composed)
                == DocumentChunker.chunkID(documentID: "d", ordinal: 0, content: decomposed)
        )
        #expect(
            DocumentChunker.chunkID(documentID: composed, ordinal: 0, content: "x")
                == DocumentChunker.chunkID(documentID: decomposed, ordinal: 0, content: "x")
        )
    }

    @Test("metadata is not part of the derivation")
    func metadataExcluded() {
        let bare = DocumentChunk(documentID: "d", ordinal: 0, content: "body")
        let annotated = DocumentChunk(documentID: "d", ordinal: 0, content: "body", metadata: ["source": "wiki"])
        #expect(bare.id == annotated.id)
    }

    @Test("derived ids are fixed-width lowercase hex")
    func idFormat() {
        let id = DocumentChunker.chunkID(documentID: "d", ordinal: 0, content: "body")
        #expect(id.count == 32)
        #expect(id.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    @Test("explicit ids override the derivation")
    func explicitIDWins() {
        let chunk = DocumentChunk(id: "external-key", documentID: "d", ordinal: 0, content: "body")
        #expect(chunk.id == "external-key")
    }

    @Test("empty content still derives a stable id")
    func emptyContent() {
        let a = DocumentChunker.chunkID(documentID: "d", ordinal: 0, content: "")
        let b = DocumentChunker.chunkID(documentID: "d", ordinal: 0, content: "")
        #expect(a == b)
        #expect(a.count == 32)
        #expect(a != DocumentChunker.chunkID(documentID: "", ordinal: 0, content: "d"))
    }

    @Test("derivation is pinned to a declared domain version")
    func domainTag() {
        #expect(DocumentChunker.chunkIDDomain == "compound.chunk.v1")
    }
}
