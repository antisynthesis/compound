import Foundation
import Testing
@testable import Compound

@Suite("Policy")
struct PolicyTests {
    @Test("scope requirement allows when scopes present")
    func scopeAllows() async throws {
        let policy = ScopeRequirement()
        let auth = AuthContext(principal: "alice", scopes: ["fs.read", "fs.write"])
        let decision = await policy.evaluate(
            .toolInvocation(name: "edit", requiredScopes: ["fs.write"]),
            auth: auth
        )
        #expect(decision.isAllowed)
    }

    @Test("scope requirement denies when missing scopes")
    func scopeDenies() async throws {
        let policy = ScopeRequirement()
        let auth = AuthContext(principal: "alice", scopes: ["fs.read"])
        let decision = await policy.evaluate(
            .toolInvocation(name: "edit", requiredScopes: ["fs.write"]),
            auth: auth
        )
        if case .deny = decision {
            // ok
        } else {
            Issue.record("expected deny")
        }
    }

    @Test("composite denies if any member denies")
    func compositeDenies() async throws {
        struct Always: Policy {
            let name = "deny"
            let decision: PolicyDecision
            func evaluate(_: PolicySubject, auth _: AuthContext) async -> PolicyDecision { decision }
        }
        let comp = CompositePolicy([
            Always(decision: .allow),
            Always(decision: .deny(reason: "nope")),
        ])
        let d = await comp.evaluate(.toolInvocation(name: "x", requiredScopes: []), auth: .anonymous)
        if case .deny = d {
            // ok
        } else {
            Issue.record("expected deny")
        }
    }
}
