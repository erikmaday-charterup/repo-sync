import Foundation

enum SyncEngine {
    private static let authMarkers = [
        "authentication failed", "could not read username", "could not read password",
        "permission denied (publickey)", "invalid username or password", "terminal prompts disabled",
        "returned error: 403", "returned error: 401", "host key verification failed", "repository not found"
    ]
    private static let networkMarkers = [
        "could not resolve host", "failed to connect", "couldn't connect", "connection timed out",
        "operation timed out", "network is unreachable", "connection refused", "connection reset"
    ]

    enum FailureKind {
        case auth, network, other
    }

    static func classify(_ result: CommandResult) -> FailureKind {
        if result.timedOut { return .network }
        let text = result.stderr.lowercased()
        if networkMarkers.contains(where: text.contains) { return .network }
        if authMarkers.contains(where: text.contains) { return .auth }
        return .other
    }

    static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? "Unknown error"
        return line.replacingOccurrences(of: "fatal: ", with: "").replacingOccurrences(of: "error: ", with: "")
    }

    // MARK: Discovery

    static func discover(folder: URL, filter: RepoFilter, organizations: [String], excluded: Set<String> = []) async -> [RepoRef] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        let candidates = entries.filter { url in
            !Cloner.isInProgressClone(url.lastPathComponent)
                && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                && fm.fileExists(atPath: url.appendingPathComponent(".git").path)
        }
        let allowedOwners = Set(organizations.map { $0.lowercased() })

        let found = await concurrentMap(candidates, limit: 16) { url -> RepoRef? in
            let result = await Git.run(["config", "--get", "remote.origin.url"], in: url, timeout: 10)
            guard result.ok, let owner = githubOwner(of: result.trimmed) else { return nil }
            if filter == .organizations && !allowedOwners.contains(owner.lowercased()) { return nil }
            return RepoRef(
                name: url.lastPathComponent, url: url, owner: owner,
                excluded: excluded.containsRepo(url.lastPathComponent),
                usesHTTPS: result.trimmed.lowercased().hasPrefix("https://")
            )
        }
        return found.compactMap { $0 }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func githubOwner(of remote: String) -> String? {
        let prefixes = ["https://github.com/", "http://github.com/", "git@github.com:", "ssh://git@github.com/"]
        guard let prefix = prefixes.first(where: { remote.lowercased().hasPrefix($0) }) else { return nil }
        let rest = remote.dropFirst(prefix.count)
        let owner = rest.split(separator: "/").first.map(String.init)
        return owner?.isEmpty == false ? owner : nil
    }

    // MARK: Access

    static func checkAccess(using repo: RepoRef) async -> AccessState {
        let result = await Git.run(["ls-remote", "--quiet", "origin", "HEAD"], in: repo.url, timeout: 30)
        return accessState(from: result)
    }

    static func accessState(from result: CommandResult) -> AccessState {
        if result.ok { return .working }
        switch classify(result) {
        case .network: return .unreachable(detail: firstLine(result.stderr))
        case .auth, .other: return .refused(detail: firstLine(result.stderr))
        }
    }

    // MARK: Sync

    static func defaultBranch(of repo: URL) async -> String {
        let head = await Git.run(["symbolic-ref", "--short", "-q", "refs/remotes/origin/HEAD"], in: repo, timeout: 10)
        if head.ok, head.trimmed.hasPrefix("origin/") {
            return String(head.trimmed.dropFirst("origin/".count))
        }
        for candidate in ["main", "master"] {
            let exists = await Git.run(["rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(candidate)"], in: repo, timeout: 10)
            if exists.ok { return candidate }
        }
        return "main"
    }

    static func sync(_ repo: RepoRef) async -> SyncResult {
        let branch = await defaultBranch(of: repo.url)
        let before = await Git.run(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], in: repo.url, timeout: 10)
        let outcome = await syncOutcome(repo)
        guard case .pulled = outcome, before.ok else { return SyncResult(outcome: outcome, commits: []) }

        let log = await Git.run(
            ["log", "--format=%h%x09%s", "-n", "3", "\(before.trimmed)..refs/heads/\(branch)"],
            in: repo.url, timeout: 10
        )
        let commits = log.stdout.split(whereSeparator: \.isNewline).compactMap { line -> Commit? in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            return parts.count == 2 ? Commit(sha: parts[0], subject: parts[1]) : nil
        }
        return SyncResult(outcome: outcome, commits: commits)
    }

    private static func syncOutcome(_ repo: RepoRef) async -> RepoOutcome {
        let fetch = await Git.run(["fetch", "--prune", "--quiet", "origin"], in: repo.url, timeout: 180)
        if !fetch.ok {
            switch classify(fetch) {
            case .network: return .failed(reason: "Couldn't reach GitHub")
            case .auth:
                if fetch.stderr.lowercased().contains("repository not found") {
                    return .failed(reason: "GitHub says this repo doesn't exist or you can't see it")
                }
                return .failed(reason: "GitHub refused access")
            case .other: return .failed(reason: firstLine(fetch.stderr))
            }
        }

        let branch = await defaultBranch(of: repo.url)
        let local = "refs/heads/\(branch)"
        let remote = "refs/remotes/origin/\(branch)"

        let hasLocal = await Git.run(["rev-parse", "--verify", "--quiet", local], in: repo.url, timeout: 10)
        guard hasLocal.ok else { return .current }

        let counts = await Git.run(["rev-list", "--left-right", "--count", "\(local)...\(remote)"], in: repo.url, timeout: 30)
        let parts = counts.trimmed.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        guard counts.ok, parts.count == 2 else { return .failed(reason: "Couldn't compare \(branch) with GitHub") }
        let ahead = parts[0]
        let behind = parts[1]

        if behind == 0 { return .current }
        if ahead > 0 {
            let noun = ahead == 1 ? "a commit" : "\(ahead) commits"
            return .skipped(reason: "\(branch) has \(noun) not on GitHub", behind: behind)
        }

        if let checkout = await worktreePath(checkingOut: branch, in: repo.url) {
            let status = await Git.run(["status", "--porcelain", "--untracked-files=no"], in: checkout, timeout: 30)
            if !status.ok { return .skipped(reason: firstLine(status.stderr), behind: behind) }
            if !status.trimmed.isEmpty {
                return .skipped(reason: "Uncommitted changes on \(branch)", behind: behind)
            }
            let merge = await Git.run(["merge", "--ff-only", "--quiet", remote], in: checkout, timeout: 60)
            if !merge.ok {
                return .skipped(reason: "Couldn't fast-forward: \(firstLine(merge.stderr))", behind: behind)
            }
            return .pulled(commits: behind)
        }

        let old = await Git.run(["rev-parse", local], in: repo.url, timeout: 10)
        let new = await Git.run(["rev-parse", remote], in: repo.url, timeout: 10)
        guard old.ok, new.ok else { return .failed(reason: "Couldn't read \(branch)") }
        let update = await Git.run(
            ["update-ref", "-m", "repo-sync: fast-forward to origin/\(branch)", local, new.trimmed, old.trimmed],
            in: repo.url, timeout: 10
        )
        return update.ok ? .pulled(commits: behind) : .failed(reason: firstLine(update.stderr))
    }

    private static func worktreePath(checkingOut branch: String, in repo: URL) async -> URL? {
        let list = await worktrees(in: repo)
        return list.first { $0.branch == branch }.map { URL(fileURLWithPath: $0.path) }
    }

    // MARK: Live info

    static func worktrees(in repo: URL) async -> [Worktree] {
        let result = await Git.run(["worktree", "list", "--porcelain"], in: repo, timeout: 10)
        guard result.ok else { return [] }
        var trees: [Worktree] = []
        for block in result.stdout.components(separatedBy: "\n\n") {
            var path: String?
            var branch = "detached"
            for line in block.split(whereSeparator: \.isNewline) {
                if line.hasPrefix("worktree ") { path = String(line.dropFirst("worktree ".count)) }
                if line.hasPrefix("branch refs/heads/") { branch = String(line.dropFirst("branch refs/heads/".count)) }
                if line == "bare" { path = nil }
            }
            if let path { trees.append(Worktree(path: path, branch: branch)) }
        }
        return trees
    }

    static func live(_ repo: RepoRef) async -> RepoLive {
        let all = await worktrees(in: repo.url)
        let ownPath = repo.url.resolvingSymlinksInPath().path
        let main = all.first { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == ownPath }
        let extras = all.filter { $0.path != main?.path }
        let defaultBranch = await defaultBranch(of: repo.url)
        return RepoLive(
            name: repo.name,
            path: repo.url.path,
            branch: main?.branch ?? "detached",
            defaultBranch: defaultBranch,
            worktrees: extras
        )
    }
}

func concurrentMap<T, R>(_ items: [T], limit: Int, _ transform: @escaping (T) async -> R) async -> [R] {
    await withTaskGroup(of: (Int, R).self) { group in
        var results = [R?](repeating: nil, count: items.count)
        var next = 0
        for _ in 0..<min(limit, items.count) {
            let index = next
            group.addTask { (index, await transform(items[index])) }
            next += 1
        }
        while let (index, value) = await group.next() {
            results[index] = value
            if next < items.count {
                let index = next
                group.addTask { (index, await transform(items[index])) }
                next += 1
            }
        }
        return results.compactMap { $0 }
    }
}
