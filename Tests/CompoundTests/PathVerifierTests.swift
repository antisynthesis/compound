import Foundation
import Testing
@testable import Compound

@Suite("PathVerifier")
struct PathVerifierTests {
    @Test("path-safety passes for paths inside workspace")
    func passesInsideWorkspace() async throws {
        let v = PathSafetyVerifier(workspaceRoot: "/tmp/workspace")
        #expect((try await v.verify("/tmp/workspace/src/foo.swift", context: RunContext())).isPass)
        #expect((try await v.verify("src/foo.swift", context: RunContext())).isPass)
    }

    @Test("path-safety rejects absolute escape")
    func rejectsAbsoluteEscape() async throws {
        let v = PathSafetyVerifier(workspaceRoot: "/tmp/workspace")
        #expect((try await v.verify("/etc/passwd", context: RunContext())).isReject)
    }

    @Test("path-safety rejects parent traversal")
    func rejectsParentTraversal() async throws {
        let v = PathSafetyVerifier(workspaceRoot: "/tmp/workspace")
        #expect((try await v.verify("../outside.txt", context: RunContext())).isReject)
    }

    @Test("path-safety rejects empty path")
    func rejectsEmptyPath() async throws {
        let v = PathSafetyVerifier(workspaceRoot: "/tmp/workspace")
        #expect((try await v.verify("   ", context: RunContext())).isReject)
    }

    @Test("path-safety rejects percent-encoded traversal")
    func rejectsPercentEncodedTraversal() async throws {
        let v = PathSafetyVerifier(workspaceRoot: "/tmp/workspace")
        #expect((try await v.verify("..%2foutside.txt", context: RunContext())).isReject)
    }

    @Test("path-denylist normalizes NFD to NFC")
    func denylistNormalizesNFD() async throws {
        let v = try PathDenyListVerifier()
        #expect((try await v.verify("/Users/x/.SSH/id_rsa", context: RunContext())).isReject)
    }

    @Test("path-denylist matches uppercase variant")
    func denylistUppercaseVariant() async throws {
        let v = try PathDenyListVerifier()
        #expect((try await v.verify("project/.ENV.production", context: RunContext())).isReject)
    }

    @Test("path-denylist blocks .env")
    func denylistEnv() async throws {
        let v = try PathDenyListVerifier()
        #expect((try await v.verify("config/.env", context: RunContext())).isReject)
    }

    @Test("path-denylist blocks .git interior")
    func denylistGitInterior() async throws {
        let v = try PathDenyListVerifier()
        #expect((try await v.verify("repo/.git/HEAD", context: RunContext())).isReject)
    }

    @Test("path-denylist blocks SSH keys")
    func denylistSSHKeys() async throws {
        let v = try PathDenyListVerifier()
        #expect((try await v.verify("/Users/x/.ssh/id_rsa", context: RunContext())).isReject)
    }

    @Test("path-denylist blocks .aws directory anywhere")
    func denylistAWS() async throws {
        let v = try PathDenyListVerifier()
        #expect((try await v.verify("/home/u/.aws/credentials", context: RunContext())).isReject)
        #expect((try await v.verify("project/.aws/config", context: RunContext())).isReject)
    }

    @Test("path-denylist blocks kubeconfig variants")
    func denylistKubeconfig() async throws {
        let v = try PathDenyListVerifier()
        #expect((try await v.verify("/home/u/.kube/config", context: RunContext())).isReject)
        #expect((try await v.verify("ops/kubeconfig", context: RunContext())).isReject)
    }

    @Test("path-denylist blocks docker config")
    func denylistDocker() async throws {
        let v = try PathDenyListVerifier()
        #expect((try await v.verify("/home/u/.docker/config.json", context: RunContext())).isReject)
    }

    @Test("path-denylist blocks gcloud config dir")
    func denylistGCloud() async throws {
        let v = try PathDenyListVerifier()
        #expect((try await v.verify("/home/u/.config/gcloud/credentials.db", context: RunContext())).isReject)
    }

    @Test("path-denylist blocks npmrc, pypirc, netrc, terraformrc")
    func denylistVariousRC() async throws {
        let v = try PathDenyListVerifier()
        for path in ["/home/u/.npmrc", "/home/u/.pypirc", "/home/u/.netrc", "/home/u/.terraformrc"] {
            let verdict = try await v.verify(path, context: RunContext())
            #expect(verdict.isReject, "expected .reject for \(path)")
        }
    }

    @Test("path-denylist blocks gh hosts.yml and service-account*.json")
    func denylistGHServiceAccount() async throws {
        let v = try PathDenyListVerifier()
        #expect((try await v.verify("/home/u/.config/gh/hosts.yml", context: RunContext())).isReject)
        #expect((try await v.verify("infra/service-account-prod.json", context: RunContext())).isReject)
    }

    @Test("path-denylist blocks tfstate files")
    func denylistTFState() async throws {
        let v = try PathDenyListVerifier()
        #expect((try await v.verify("infra/main.tfstate", context: RunContext())).isReject)
        #expect((try await v.verify("infra/main.tfstate.backup", context: RunContext())).isReject)
    }

    @Test("path-denylist passes ordinary file")
    func denylistPassesOrdinary() async throws {
        let v = try PathDenyListVerifier()
        #expect((try await v.verify("src/foo.swift", context: RunContext())).isPass)
    }

    @Test("path-denylist supports custom patterns")
    func denylistCustomPatterns() async throws {
        let v = try PathDenyListVerifier(patterns: [#"\.custom$"#])
        #expect((try await v.verify("infra/main.custom", context: RunContext())).isReject)
        #expect((try await v.verify("infra/main.tf", context: RunContext())).isPass)
    }
}
