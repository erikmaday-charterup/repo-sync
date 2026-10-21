import Foundation

struct ClonePlan: Equatable {
    let toClone: [GitHubRepo]
    let deleted: Set<String>
}

enum ClonePlanner {
    static func plan(orgRepos: [GitHubRepo], present: Set<String>, known: Set<String>?, excluded: Set<String>) -> ClonePlan {
        let orgKeys = RepoName.keys(orgRepos.map(\.name))
        let presentKeys = RepoName.keys(present)
        let excludedKeys = RepoName.keys(excluded)
        let deleted = (known ?? []).filter { name in
            let key = RepoName.key(name)
            return orgKeys.contains(key) && !presentKeys.contains(key) && !excludedKeys.contains(key)
        }
        let deletedKeys = RepoName.keys(deleted)

        var seen = Set<String>()
        let toClone = orgRepos.filter { repo in
            let key = RepoName.key(repo.name)
            return !presentKeys.contains(key)
                && !excludedKeys.contains(key)
                && !repo.archived
                && !deletedKeys.contains(key)
                && seen.insert(key).inserted
        }
        return ClonePlan(toClone: toClone, deleted: deleted)
    }
}
