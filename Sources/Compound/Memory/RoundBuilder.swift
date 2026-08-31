import Foundation

/// One conversational round that has aged out of the working window and
/// been committed to archival storage.
///
/// A round is the archival unit because it is the granularity that
/// measured best: LongMemEval reports round-level chunking at 0.615
/// against 0.592 for session-level chunking. Sessions are too coarse (a
/// single hit drags in unrelated turns and burns the budget), individual
/// messages too fine (an assistant answer retrieved without its question
/// is unusable evidence).
///
/// ## Index text and display text
///
/// ``indexText`` is what the retrieval indexes see; ``displayText`` is
/// what the model is served. They differ by exactly one appended line —
/// ``RoundBuilder/keyLine(for:maxCharacters:)`` — which implements the
/// LongMemEval "K = V + facts" key expansion (+9.4% Recall@5) without a
/// model call and without touching ``DocumentChunk``.
///
/// The raw round is what is served, deliberately. LongMemEval found that
/// indexing *summaries or extracted facts as the value* **hurt**
/// accuracy: the expansion belongs in the key, never in the value. So the
/// key line steers retrieval and then disappears before the model reads
/// anything.
public struct ArchivedRound: Sendable, Equatable, Codable, Identifiable {
    /// Deterministic chunk id, shared with the index posting.
    ///
    /// Derived through ``DocumentChunker/chunkID(documentID:ordinal:content:)``
    /// over ``indexText``, so a round archived twice lands on one id and
    /// the second write is an upsert rather than a duplicate posting.
    public let id: String
    /// Thread this round belongs to.
    public let threadID: String
    /// Monotonic per-thread position, assigned by ``RoundBuilder`` and
    /// reused on every re-run (see
    /// ``RoundBuilder/rounds(from:threadID:ordinals:nextOrdinal:)``).
    public let ordinal: Int
    /// Ids of the ``ConversationMessage``s this round was built from, in
    /// transcript order. This is the provenance link back to the
    /// conversation store.
    public let messageIDs: [UUID]
    /// Round text as served to the model: role-prefixed lines, unfenced.
    public let displayText: String
    /// Round text as indexed: ``displayText`` plus the derived key line.
    public let indexText: String
    /// `createdAt` of the round's first message.
    public let startedAt: Date
    /// `createdAt` of the round's last message.
    public let endedAt: Date

    /// Creates a round and derives its id from `threadID`, `ordinal`, and
    /// `indexText`.
    public init(
        threadID: String,
        ordinal: Int,
        messageIDs: [UUID],
        displayText: String,
        indexText: String,
        startedAt: Date,
        endedAt: Date
    ) {
        self.id = DocumentChunker.chunkID(
            documentID: RoundBuilder.documentID(threadID: threadID),
            ordinal: ordinal,
            content: indexText
        )
        self.threadID = threadID
        self.ordinal = ordinal
        self.messageIDs = messageIDs
        self.displayText = displayText
        self.indexText = indexText
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    /// The ``DocumentChunk`` this round is indexed as.
    ///
    /// The chunk carries ``indexText`` as its content — the store serves
    /// ``displayText`` from its own journal instead, which is how the
    /// index-text/display-text split ships with zero edits to
    /// ``DocumentChunk``, ``BM25Retriever``, or ``DenseRetriever``.
    ///
    /// Metadata carries thread, ordinal, and the ISO-8601 window purely
    /// for debuggability: both bundled retrievers drop metadata on the
    /// way to ``RetrievedSource``, and that is fine because the store
    /// owns the side table and re-joins on the chunk id.
    public var chunk: DocumentChunk {
        let formatter = ISO8601DateFormatter()
        return DocumentChunk(
            id: id,
            documentID: RoundBuilder.documentID(threadID: threadID),
            ordinal: ordinal,
            content: indexText,
            metadata: [
                "thread": threadID,
                "ordinal": String(ordinal),
                "startedAt": formatter.string(from: startedAt),
                "endedAt": formatter.string(from: endedAt),
            ]
        )
    }
}

/// Groups ``ConversationMessage``s into ``ArchivedRound``s and derives
/// their retrieval keys. Every function here is pure: same messages in,
/// byte-identical rounds out.
public enum RoundBuilder {
    /// Domain-separation tag mixed into every archival document id. It
    /// keeps archival chunk ids in a disjoint region of the same 32-hex
    /// space ``DocumentChunker`` uses for document chunks, so an archival
    /// round and a document chunk can never fuse into one another inside
    /// ``HybridRetriever``.
    public static let documentIDDomain = "compound.memory.archive.v1"

    /// Document id for a thread's archive.
    public static func documentID(threadID: String) -> String {
        "\(documentIDDomain)|\(threadID)"
    }

    /// Splits `messages` into rounds.
    ///
    /// A round starts at a `.user` message and runs up to (not including)
    /// the next `.user` message, absorbing the `.assistant`, `.tool`, and
    /// `.system` turns in between. Messages preceding the first user turn
    /// form their own leading round. Empty input yields no rounds.
    ///
    /// ## Ordinal idempotence
    ///
    /// Archival runs from ``BackgroundCompoundActivity``, whose deferral
    /// semantics re-run the body from the top after a throw or a
    /// cancellation. If ordinals were assigned by position in the input
    /// slice, a re-run over a shifted window would renumber every round
    /// and mint a fresh set of chunk ids — the archive would silently
    /// double.
    ///
    /// So ordinals are assigned through a persisted ledger keyed by the
    /// round's **first message id**: a round whose first message is
    /// already in `ordinals` reuses its number, and only genuinely new
    /// rounds consume `nextOrdinal`. Re-running over the same messages is
    /// therefore a no-op that produces byte-identical rounds.
    ///
    /// - Parameters:
    ///   - messages: Transcript slice to archive, in order.
    ///   - threadID: Thread the messages belong to.
    ///   - ordinals: Previously assigned first-message-id → ordinal map.
    ///   - nextOrdinal: Next unused ordinal for this thread.
    /// - Returns: The rounds plus the updated ledger.
    public static func rounds(
        from messages: [ConversationMessage],
        threadID: String,
        ordinals: [UUID: Int] = [:],
        nextOrdinal: Int = 0
    ) -> (rounds: [ArchivedRound], ordinals: [UUID: Int], nextOrdinal: Int) {
        guard !messages.isEmpty else { return ([], ordinals, nextOrdinal) }
        var groups: [[ConversationMessage]] = []
        var current: [ConversationMessage] = []
        for message in messages {
            if message.role == .user, !current.isEmpty {
                groups.append(current)
                current = [message]
            } else {
                current.append(message)
            }
        }
        if !current.isEmpty { groups.append(current) }

        var ledger = ordinals
        var next = nextOrdinal
        var out: [ArchivedRound] = []
        out.reserveCapacity(groups.count)
        for group in groups {
            guard let first = group.first, let last = group.last else { continue }
            let ordinal: Int
            if let existing = ledger[first.id] {
                ordinal = existing
            } else {
                ordinal = next
                ledger[first.id] = ordinal
                next += 1
            }
            let display = displayText(for: group)
            let key = keyLine(for: display)
            let index = key.isEmpty ? display : display + "\n" + key
            out.append(ArchivedRound(
                threadID: threadID,
                ordinal: ordinal,
                messageIDs: group.map(\.id),
                displayText: display,
                indexText: index,
                startedAt: first.createdAt,
                endedAt: last.createdAt
            ))
        }
        return (out, ledger, next)
    }

    /// Renders a round as role-prefixed lines.
    ///
    /// Deliberately plain text, **not** fenced. Fencing is
    /// ``PromptFrame``'s job at render time; fencing here would nest one
    /// frame inside another and show the model raw escape sequences
    /// instead of the conversation.
    static func displayText(for messages: [ConversationMessage]) -> String {
        messages.map { message in
            switch message.role {
            case .user: return "user: \(message.content)"
            case .assistant: return "assistant: \(message.content)"
            case .system: return "system: \(message.content)"
            case .tool:
                if let name = message.metadata["tool"], !name.isEmpty {
                    return "tool[\(name)]: \(message.content)"
                }
                return "tool: \(message.content)"
            }
        }.joined(separator: "\n")
    }

    /// Derives the retrieval key line for a round's display text.
    ///
    /// This is the LongMemEval "K = V + facts" key expansion done
    /// deterministically and without a model. The line is composed from
    /// three families, deduplicated, sorted lexicographically ascending,
    /// joined with a space, and truncated at a token boundary:
    ///
    /// 1. **Dates.** Every `NSDataDetector` date match whose matched text
    ///    carries an explicit four-digit year, rendered as an ISO-8601 day
    ///    string in the match's own time zone. LongMemEval's own finding
    ///    is that "Llama 8B struggles to generate accurate time ranges" —
    ///    temporal keys are exactly the thing not to ask a small model
    ///    for, so Foundation parses them instead. The year requirement is
    ///    what keeps it *pure*: `NSDataDetector` resolves relative
    ///    expressions ("tomorrow", "Tuesday") against the current date,
    ///    which would make the key — and therefore the chunk id — a
    ///    function of when the archive ran.
    /// 2. **Entities.** Runs of one to three capitalized tokens that are
    ///    not sentence-initial and not stopwords. Sentence-initial tokens
    ///    are excluded because their capitalization carries no signal.
    /// 3. **Quantities.** Numeric literals with an adjacent unit token.
    ///
    /// The result is a pure function of `displayText` alone — never of
    /// the fact store, never of the clock. That is the property that lets
    /// ``ArchivedRound/id`` stay fixed while memory around it evolves: if
    /// the key drifted with the fact store, every consolidation pass
    /// would re-mint ids and the archive would grow a duplicate of itself.
    public static func keyLine(for displayText: String, maxCharacters: Int = 240) -> String {
        precondition(maxCharacters > 0, "maxCharacters must be positive")
        var keys: Set<String> = []
        keys.formUnion(dateKeys(in: displayText))
        keys.formUnion(entityKeys(in: displayText))
        keys.formUnion(quantityKeys(in: displayText))
        guard !keys.isEmpty else { return "" }
        var kept: [String] = []
        var length = 0
        for key in keys.sorted() {
            let added = kept.isEmpty ? key.count : key.count + 1
            if length + added > maxCharacters { break }
            kept.append(key)
            length += added
        }
        return kept.joined(separator: " ")
    }

    // MARK: - Key families

    private static func dateKeys(in text: String) -> [String] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var out: [String] = []
        for match in detector.matches(in: text, range: range) {
            guard let date = match.date else { continue }
            guard let matched = Range(match.range, in: text) else { continue }
            // Only absolutely-specified dates become keys: a match without
            // an explicit four-digit year was resolved against "now" and
            // would make this function impure.
            guard hasExplicitYear(String(text[matched])) else { continue }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = match.timeZone ?? TimeZone.current
            formatter.dateFormat = "yyyy-MM-dd"
            out.append(formatter.string(from: date))
        }
        return out
    }

    /// Whether `matched` contains a maximal run of exactly four digits —
    /// a written-out year. Scanned by hand rather than by regex because
    /// the natural pattern needs a lookbehind, which Swift's regex engine
    /// does not support.
    private static func hasExplicitYear(_ matched: String) -> Bool {
        var run = 0
        for character in matched {
            if character.isNumber {
                run += 1
            } else {
                if run == 4 { return true }
                run = 0
            }
        }
        return run == 4
    }

    /// A token plus the two facts the entity scan needs about it: whether
    /// it opened a sentence, and whether only spaces separate it from the
    /// previous token (so runs never span punctuation).
    private struct ScannedToken {
        let text: String
        let sentenceInitial: Bool
        let adjacentToPrevious: Bool
    }

    private static let entityStopwords: Set<String> = [
        "a", "an", "and", "but", "he", "her", "his", "i", "if", "it", "its",
        "me", "my", "or", "our", "she", "that", "the", "their", "they",
        "this", "we", "you", "your",
    ]

    private static func entityKeys(in text: String) -> [String] {
        let tokens = scan(text)
        var out: [String] = []
        var run: [String] = []
        func flush() {
            guard !run.isEmpty else { return }
            out.append(run.prefix(3).joined(separator: " "))
            run.removeAll(keepingCapacity: true)
        }
        for token in tokens {
            let qualifies = !token.sentenceInitial
                && token.text.count >= 2
                && (token.text.first?.isUppercase ?? false)
                && !entityStopwords.contains(token.text.lowercased())
            if qualifies {
                if !token.adjacentToPrevious { flush() }
                run.append(token.text)
            } else {
                flush()
            }
        }
        flush()
        return out
    }

    private static func scan(_ text: String) -> [ScannedToken] {
        var tokens: [ScannedToken] = []
        var current = ""
        var currentIsSentenceInitial = true
        var pendingSentenceStart = true
        var onlySpacesSincePrevious = true
        var sawPrevious = false
        func flush() {
            guard !current.isEmpty else { return }
            tokens.append(ScannedToken(
                text: current,
                sentenceInitial: currentIsSentenceInitial,
                adjacentToPrevious: sawPrevious && onlySpacesSincePrevious
            ))
            current = ""
            sawPrevious = true
            onlySpacesSincePrevious = true
            pendingSentenceStart = false
        }
        for character in text {
            if character.isLetter || character.isNumber {
                if current.isEmpty { currentIsSentenceInitial = pendingSentenceStart }
                current.append(character)
                continue
            }
            flush()
            // A colon counts as a boundary because every display line
            // opens with a role prefix ("user: ").
            if character == "." || character == "!" || character == "?" || character == ":" || character == "\n" {
                pendingSentenceStart = true
            }
            if character != " " && character != "\t" { onlySpacesSincePrevious = false }
        }
        flush()
        return tokens
    }

    // Bounded quantifiers throughout, matching the discipline
    // `PatternRedactor` and `SecretsVerifier` already hold: an unbounded
    // repetition in a pattern that runs over untrusted transcript text is
    // a backtracking hazard.
    private static func quantityKeys(in text: String) -> [String] {
        // Built locally rather than held in a `static let`: `Regex` is not
        // `Sendable`, and the codebase's alternative — an
        // `@unchecked Sendable` wrapper, as `PatternRedactor` and
        // `SecretsVerifier.SecretRule` use — buys nothing here, since key
        // derivation runs once per round on the archival path and never on
        // the read path.
        let quantityPattern = #/\b([0-9]{1,12}(?:[.,][0-9]{1,6})?)[ \t]?([A-Za-z]{1,10})\b/#
        var out: [String] = []
        for match in text.matches(of: quantityPattern) {
            let unit = String(match.output.2).lowercased()
            guard !entityStopwords.contains(unit) else { continue }
            out.append("\(match.output.1) \(unit)")
        }
        return out
    }
}
