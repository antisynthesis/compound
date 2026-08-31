import Foundation

/// The always-present block of identity-level memory, rendered as one
/// pinned source.
///
/// This is the MemGPT/Letta core-block pattern: a tiny, byte-capped
/// region of the prompt that is not retrieved, not ranked, and not
/// negotiable — the handful of claims that should be in front of the
/// model on *every* turn regardless of what the user just asked. Name,
/// location, hard constraints. In a 4096-token window it is the highest
/// value per token available: zero retrieval cost, zero read-path model
/// calls, and it answers the questions a recall miss would otherwise get
/// wrong silently.
///
/// The block is assembled from facts carrying a designated tag (see
/// ``MemoryContextAssembler/coreBlockFactTag``), so what is "core" is a
/// write-path decision made by the extraction rules, not a ranking
/// accident on the read path.
///
/// ## The nil score is load-bearing
///
/// ``retrievedSource`` returns `score: nil`, which
/// ``TokenBudgetedAssembler`` documents as the evict-last pin: `nil`
/// sources sort to the back of the eviction queue and are only dropped
/// after every scored source has already gone. That is deliberate and
/// stated rather than fudged — the core block is the one part of memory
/// guaranteed to survive budget pressure.
public struct CoreMemoryBlock: Sendable, Equatable {
    /// Thread the block belongs to.
    public let threadID: String
    /// Rendered block text, already truncated to ``maxCharacters``.
    public let text: String
    /// Character cap the text was rendered under.
    public let maxCharacters: Int

    /// Domain-separation tag for core-block identifiers. Fact ids,
    /// archival chunk ids, and core-block ids all live in the same
    /// 32-hex space but in disjoint regions, so ``HybridRetriever``
    /// fusion can never double-credit one piece of content.
    public static let documentIDDomain = "compound.memory.core.v1"

    /// Default character cap. Roughly four times
    /// ``MemoryBudget/coreBlockTokens`` at the framework's
    /// bytes-per-token heuristic, so the character cap is a cheap
    /// pre-trim and the token cap is what actually binds.
    public static let defaultMaxCharacters = 400

    /// Creates a block over already-rendered text.
    ///
    /// - Precondition: `maxCharacters` is positive.
    public init(threadID: String, text: String, maxCharacters: Int = CoreMemoryBlock.defaultMaxCharacters) {
        precondition(maxCharacters > 0, "maxCharacters must be positive")
        self.threadID = threadID
        self.text = text
        self.maxCharacters = maxCharacters
    }

    /// Whether there is nothing to render. An empty block is skipped
    /// entirely rather than emitted as an empty source.
    public var isEmpty: Bool { text.isEmpty }

    /// Deterministic identifier, derived from the thread and the
    /// rendered text. Two assemblies over the same core facts produce
    /// the same id, so a citation to the block is stable across turns.
    public var id: String {
        DocumentChunker.chunkID(
            documentID: "\(Self.documentIDDomain)|\(threadID)",
            ordinal: 0,
            content: text
        )
    }

    /// The block as evidence for context assembly.
    ///
    /// `score` is `nil` — see the type's documentation. Provenance rides
    /// in the title because ``RetrievedSource`` has no metadata field
    /// and adding one was rejected as a source-breaking change to the
    /// package's most widely used struct; ``PromptFrame`` escapes titles
    /// as attributes, so the channel is safe.
    public var retrievedSource: RetrievedSource {
        RetrievedSource(
            id: id,
            title: "core memory (thread \(threadID))",
            content: text,
            score: nil
        )
    }

    /// Renders `facts` into the block text.
    ///
    /// Facts are ordered by importance descending, then ``Fact/validFrom``
    /// descending, then id ascending — a total order, so the rendering is
    /// a pure function of the input set. Each fact becomes one
    /// `"subject predicate: text"` line.
    ///
    /// Truncation is at a **line** boundary: as soon as appending the
    /// next line would exceed `maxCharacters`, rendering stops. The model
    /// therefore never sees half a fact, which mid-string truncation
    /// would produce and which reads as a claim about something the user
    /// never said.
    public static func render(facts: [Fact], maxCharacters: Int) -> String {
        precondition(maxCharacters > 0, "maxCharacters must be positive")
        var text = ""
        for fact in ordered(facts) {
            let candidate = appending(line(for: fact), to: text)
            if candidate.count > maxCharacters { break }
            text = candidate
        }
        return text
    }

    /// The total order rendering uses: importance descending, then
    /// ``Fact/validFrom`` descending, then id ascending. Exposed in-module
    /// so ``MemoryContextAssembler`` can render line by line against a
    /// token counter and still produce byte-identical output.
    static func ordered(_ facts: [Fact]) -> [Fact] {
        facts.sorted { a, b in
            if a.importance != b.importance { return a.importance > b.importance }
            if a.validFrom != b.validFrom { return a.validFrom > b.validFrom }
            return a.id < b.id
        }
    }

    /// One fact as one line.
    static func line(for fact: Fact) -> String {
        "\(fact.subject) \(fact.predicate): \(fact.text)"
    }

    /// Appends `line` to `text` with the joining newline.
    static func appending(_ line: String, to text: String) -> String {
        text.isEmpty ? line : text + "\n" + line
    }
}
