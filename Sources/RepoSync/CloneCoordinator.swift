import Foundation

struct CloneStepResult {
    let cloned: [String]
    let failed: [FailedRepo]
    let deleted: Set<String>
    let tokenRevoked: Bool
    let listed: Bool
    var listingFailed = false
}

struct CloneCoordinator {
    static let maxConcurrentClones = 4

    let listRepos: (String) async throws -> [GitHubRepo]
    let clone: (GitHubRepo) async -> CloneOutcome

    @MainActor
    func run(
        orgs: [String],
        present: Set<String>,
        known: Set<String>?,
        excluded: Set<String>,
        progress: @escaping (Int, Int) -> Void
    ) async -> CloneStepResult {
        var orgRepos: [GitHubRepo] = []
        var failed: [FailedRepo] = []
        var listedAny = false
        for org in orgs {
            do {
                orgRepos += try await listRepos(org)
                listedAny = true
            } catch GitHubError.unauthorized {
                return CloneStepResult(cloned: [], failed: [], deleted: [], tokenRevoked: true, listed: false)
            } catch {
                failed.append(FailedRepo(name: org, reason: "Couldn't list repos: \(describe(error))"))
            }
        }

        let listingFailures = failed.count
        let plan = ClonePlanner.plan(orgRepos: orgRepos, present: present, known: known, excluded: excluded)
        let total = plan.toClone.count
        var cloned: [String] = []
        var done = 0
        if total > 0 { progress(done, total) }

        await withTaskGroup(of: (GitHubRepo, CloneOutcome).self) { group in
            var pending = plan.toClone.makeIterator()
            for _ in 0..<min(Self.maxConcurrentClones, total) {
                if let repo = pending.next() { group.addTask { (repo, await clone(repo)) } }
            }
            while let (repo, outcome) = await group.next() {
                switch outcome {
                case .cloned: cloned.append(repo.name)
                case .alreadyExists: break
                case .failed(let reason): failed.append(FailedRepo(name: repo.name, reason: reason))
                }
                done += 1
                progress(done, total)
                if let next = pending.next() { group.addTask { (next, await clone(next)) } }
            }
        }

        return CloneStepResult(
            cloned: cloned.sorted(),
            failed: failed.sorted { $0.name < $1.name },
            deleted: plan.deleted,
            tokenRevoked: false,
            listed: listedAny,
            listingFailed: listingFailures > 0
        )
    }

    private func describe(_ error: Error) -> String {
        guard let github = error as? GitHubError else { return error.localizedDescription }
        switch github {
        case .unauthorized: return "GitHub refused the sign-in"
        case .notFound: return "GitHub doesn't know this organization"
        case .http(let status): return "GitHub answered \(status)"
        case .malformed: return "GitHub sent something unexpected"
        }
    }
}
