// RAGBot — grounded question-answering over an indexed corpus.
//
// The pattern: a hybrid retriever (lexical BM25 + dense NLEmbedding) finds
// candidate passages, the assembler injects them as [source-id] citations,
// the citation verifier requires the model to ground every factual claim,
// and the eval suite locks the behavior in place across model upgrades.
//
// Open in Xcode 26 to run.

import Foundation
import Compound
import FoundationModels

@main
struct RAGBot {
    static func main() async throws {
        // 1. Index a corpus. In production this happens at app launch (or
        //    via a BackgroundCompoundActivity overnight refresh) against
        //    your actual content.
        let documents: [(String, String)] = [
            ("compound", "Compound AI Systems pair a stochastic proposer with deterministic verifiers."),
            ("verifier", "A verifier is a deterministic function from a candidate output to a verdict."),
            ("budget", "Bounded loops are required: turns, tool calls, repair attempts, wall-clock."),
        ]
        var chunks: [DocumentChunk] = []
        for (id, body) in documents {
            chunks.append(contentsOf: DocumentChunker.paragraphs(text: body, documentID: id))
        }
        let bm25 = BM25Retriever(chunks: chunks)
        let dense = DenseRetriever(provider: try NLEmbeddingProvider())
        try await dense.index(chunks)
        let hybrid = HybridRetriever(retrievers: [bm25, dense])

        // 2. Assemble: instructions + sources + redactors. The instructions
        //    enforce the citation contract; the verifier enforces it again.
        let assembler = DefaultContextAssembler(
            baseInstructions: "Answer using the supplied sources. Annotate every claim with a [source-id].",
            retriever: hybrid,
            retrievalLimit: 4
        )

        // 3. Output verifier: citation gate + encoding + secrets backstop.
        //    The known IDs come from the retriever's index — we compute
        //    them per-run from the assembled context.
        let outputVerifier = VerifierChain(name: "rag-output", [
            AnyVerifier(EncodingVerifier()),
            AnyVerifier(SecretsVerifier(returnAs: .repair)),
            AnyVerifier(try CitationVerifier(knownSourceIDs: Set(documents.map(\.0)))),
        ])

        let session = CompoundSession(.init(
            assembler: assembler,
            outputVerifier: outputVerifier,
            tracer: OSLogTracer(),
            budget: .default
        ))

        // 4. Run with progress streaming for a SwiftUI UI.
        let progress = StreamingProgressReporter()
        let progressStream = await progress.subscribe()
        Task {
            for await event in progressStream {
                if case .modelStreamChunk(_, let delta) = event {
                    print(delta, terminator: "")
                }
            }
        }

        let outcome = try await session.respond(
            to: "What is a verifier and why does the loop need a budget?",
            progress: progress
        )
        print("\n— done —")
        print(outcome.output)

        // 5. Lock the behavior in place with an eval suite.
        let suite = EvalSuite(name: "smoke", cases: [
            EvalCase(
                id: "must-cite",
                prompt: "What is a verifier?",
                predicates: [
                    try MatchesRegexPredicate(#"\[(verifier|compound|budget)\]"#)
                ]
            ),
        ])
        let report = await EvalRunner().run(suite, against: session)
        print(report.detailedReport())
    }
}
