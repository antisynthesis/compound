// SQLAgent — natural-language to read-only SQL with structural gating.
//
// Letting a language model write SQL against a live database is exactly the
// kind of easy idea that goes wrong in production. So the model never touches
// the database directly. It proposes SQL; SQLSafetyVerifier disposes of
// anything dangerous — no DROP, no UPDATE without a WHERE, no stacked
// statements — and only the surviving query is executed. The guarantee comes
// from the structure, not from trusting the model to behave.
//
// Open in Xcode 26 to run — the example demonstrates the wiring; for an
// actual deployment plug your warehouse's executor into runQuery(_:).

import Foundation
import Compound
import FoundationModels

@main
struct SQLAgent {
    static func main() async throws {
        // 1. Output verifier: SQL safety is the gating contract. The agent
        //    is read-only — only SELECT/WITH/EXPLAIN statements pass.
        let outputVerifier = VerifierChain(name: "sql-output", [
            AnyVerifier(EncodingVerifier()),
            AnyVerifier(SQLSafetyVerifier(
                allowedStatements: [.select, .with, .explain],
                allowMultipleStatements: false,
                requireWhereOnUpdate: true,
                requireWhereOnDelete: true
            )),
        ])

        // 2. Assembler with schema context. In a real deployment retrieve
        //    the table schemas from your catalog and inject them; here we
        //    inline a fixture.
        let schemaSource = RetrievedSource(
            id: "schema",
            title: "Tables",
            content: """
            users(id INT PRIMARY KEY, email TEXT, signup_date DATE, country TEXT)
            orders(id INT PRIMARY KEY, user_id INT, total_cents INT, created_at TIMESTAMP)
            """
        )
        let assembler = DefaultContextAssembler(
            baseInstructions: """
                You translate natural language into a single PostgreSQL SELECT
                or WITH statement. Always include a LIMIT. Never modify data.
                """,
            retriever: StaticRetriever([schemaSource])
        )

        // 3. Session.
        let tracer = CompositeTracer([OSLogTracer(), SignpostTracer()])
        let session = CompoundSession(.init(
            assembler: assembler,
            outputVerifier: outputVerifier,
            tracer: tracer,
            budget: .default
        ))

        guard session.isAvailable() else {
            print("Apple Intelligence is not available on this device.")
            return
        }

        // 4. Run.
        let outcome = try await session.respond(
            to: "Top 5 countries by total spend in the last 90 days."
        )

        // 5. Execute the (now verified) SQL against your warehouse.
        let rows = try await runQuery(outcome.output)
        print(rows)
    }

    /// Stub. In a real app this hands the query to a connection pool
    /// (Postgres, SQLite, BigQuery, …) and returns the rows.
    static func runQuery(_ sql: String) async throws -> String {
        "<<would execute>>: \(sql)"
    }
}
