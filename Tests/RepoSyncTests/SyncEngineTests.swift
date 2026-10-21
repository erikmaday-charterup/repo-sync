import XCTest
@testable import RepoSync

final class SyncEngineTests: XCTestCase {
    private var sandbox: TestRepos!

    override func setUpWithError() throws {
        sandbox = try TestRepos.makeSandbox()
    }

    override func tearDown() {
        sandbox.cleanup()
    }

    private func repoRef(_ name: String) -> RepoRef {
        RepoRef(name: name, url: sandbox.folder.appendingPathComponent(name), owner: "test-org")
    }

    private func behindCount(_ name: String) throws -> Int {
        let repo = sandbox.folder.appendingPathComponent(name)
        return Int(try sandbox.git(["rev-list", "--count", "main..origin/main"], in: repo)) ?? -1
    }

    func testCleanMainFastForwards() async throws {
        try sandbox.makeRemote("clean-main", commits: 1)
        let repo = try sandbox.clone("clean-main")
        try sandbox.advance("clean-main", by: 3)

        let result = await SyncEngine.sync(repoRef("clean-main"))

        XCTAssertEqual(result.outcome, .pulled(commits: 3))
        XCTAssertEqual(try behindCount("clean-main"), 0)
        XCTAssertEqual(try sandbox.git(["rev-parse", "HEAD"], in: repo), try sandbox.git(["rev-parse", "origin/main"], in: repo))
    }

    func testFeatureBranchMovesMainRefOnly() async throws {
        try sandbox.makeRemote("on-feature", commits: 1)
        let repo = try sandbox.clone("on-feature")
        try sandbox.git(["switch", "-q", "-c", "feature-one"], in: repo)
        try sandbox.advance("on-feature", by: 2)

        let result = await SyncEngine.sync(repoRef("on-feature"))

        XCTAssertEqual(result.outcome, .pulled(commits: 2))
        XCTAssertEqual(try behindCount("on-feature"), 0)
        XCTAssertEqual(try sandbox.git(["branch", "--show-current"], in: repo), "feature-one")
    }

    func testDirtyMainIsSkipped() async throws {
        try sandbox.makeRemote("dirty-main", commits: 1)
        let repo = try sandbox.clone("dirty-main")
        try "hi".write(to: repo.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try sandbox.git(["add", "file.txt"], in: repo)
        try sandbox.advance("dirty-main", by: 1)

        let result = await SyncEngine.sync(repoRef("dirty-main"))

        XCTAssertEqual(result.outcome, .skipped(reason: "Uncommitted changes on main", behind: 1))
        XCTAssertEqual(try behindCount("dirty-main"), 1)
        XCTAssertEqual(try sandbox.git(["status", "--porcelain"], in: repo), "A  file.txt")
    }

    func testLocalCommitIsSkipped() async throws {
        try sandbox.makeRemote("ahead-main", commits: 1)
        let repo = try sandbox.clone("ahead-main")
        try sandbox.git(["commit", "-q", "--allow-empty", "-m", "local"], in: repo)
        try sandbox.advance("ahead-main", by: 4)

        let result = await SyncEngine.sync(repoRef("ahead-main"))

        XCTAssertEqual(result.outcome, .skipped(reason: "main has a commit not on GitHub", behind: 4))
        XCTAssertEqual(try behindCount("ahead-main"), 4)
    }

    func testUntrackedFileDoesNotBlockFastForward() async throws {
        try sandbox.makeRemote("untracked-main", commits: 1)
        let repo = try sandbox.clone("untracked-main")
        try "hi".write(to: repo.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try sandbox.advance("untracked-main", by: 1)

        let result = await SyncEngine.sync(repoRef("untracked-main"))

        XCTAssertEqual(result.outcome, .pulled(commits: 1))
        XCTAssertEqual(try behindCount("untracked-main"), 0)
    }

    func testWorktreeOnMainFastForwards() async throws {
        try sandbox.makeRemote("worktree-main", commits: 1)
        let repo = try sandbox.clone("worktree-main")
        try sandbox.git(["switch", "-q", "-c", "feature-two"], in: repo)
        let worktree = sandbox.root.appendingPathComponent("wt-main")
        try sandbox.git(["worktree", "add", "-q", worktree.path, "main"], in: repo)
        try sandbox.advance("worktree-main", by: 2)

        let result = await SyncEngine.sync(repoRef("worktree-main"))

        XCTAssertEqual(result.outcome, .pulled(commits: 2))
        XCTAssertEqual(try sandbox.git(["rev-list", "--count", "HEAD..origin/main"], in: worktree), "0")
        XCTAssertEqual(try sandbox.git(["branch", "--show-current"], in: repo), "feature-two")
    }

    func testAlreadyCurrentReportsCurrent() async throws {
        try sandbox.makeRemote("up-to-date", commits: 1)
        try sandbox.clone("up-to-date")

        let result = await SyncEngine.sync(repoRef("up-to-date"))

        XCTAssertEqual(result.outcome, .current)
        XCTAssertTrue(result.commits.isEmpty)
    }

    func testVanishedRemoteFails() async throws {
        try sandbox.makeRemote("vanished", commits: 1)
        try sandbox.clone("vanished")
        try FileManager.default.removeItem(at: sandbox.remotes.appendingPathComponent("vanished.git"))

        let result = await SyncEngine.sync(repoRef("vanished"))

        guard case .failed = result.outcome else {
            return XCTFail("expected failed, got \(result.outcome)")
        }
    }

    func testPulledCommitsAreCaptured() async throws {
        try sandbox.makeRemote("captured", commits: 1)
        try sandbox.clone("captured")
        try sandbox.advance("captured", by: 3)

        let result = await SyncEngine.sync(repoRef("captured"))

        XCTAssertEqual(result.commits.map(\.subject), ["remote 3", "remote 2", "remote 1"])
    }

    func testDiscoverFindsOnlyGitHubRepos() async throws {
        try sandbox.makeRemote("github-repo", commits: 1)
        try sandbox.clone("github-repo")
        let other = sandbox.folder.appendingPathComponent("bitbucket-repo")
        try sandbox.git(["init", "-q", other.path], in: sandbox.root)
        try sandbox.git(["remote", "add", "origin", "git@bitbucket.org:x/y.git"], in: other)

        let found = await SyncEngine.discover(folder: sandbox.folder, filter: .allGitHub, organizations: [])

        XCTAssertEqual(found.map(\.name), ["github-repo"])
        XCTAssertEqual(found.first?.owner, "test-org")
    }

    func testDiscoverMarksExcluded() async throws {
        for name in ["included", "left-alone"] {
            try sandbox.makeRemote(name, commits: 1)
            try sandbox.clone(name)
        }

        let found = await SyncEngine.discover(
            folder: sandbox.folder, filter: .allGitHub, organizations: [], excluded: ["left-alone"]
        )

        XCTAssertEqual(found.map(\.name), ["included", "left-alone"])
        XCTAssertEqual(found.map(\.excluded), [false, true])
    }

    func testAccessStateKeepsTheFirstLineOfWhatGitSaid() {
        func state(_ stderr: String) -> AccessState {
            SyncEngine.accessState(from: CommandResult(status: 128, stdout: "", stderr: stderr, timedOut: false))
        }

        XCTAssertEqual(
            state("fatal: Authentication failed for 'https://github.com/test-org/a.git/'"),
            .refused(detail: "Authentication failed for 'https://github.com/test-org/a.git/'")
        )
        XCTAssertEqual(
            state("fatal: unable to access: Could not resolve host: github.com"),
            .unreachable(detail: "unable to access: Could not resolve host: github.com")
        )
        XCTAssertEqual(SyncEngine.accessState(from: CommandResult(status: 0, stdout: "", stderr: "", timedOut: false)), .working)
    }

    func testGitHubOwnerParsing() {
        XCTAssertEqual(SyncEngine.githubOwner(of: "https://github.com/o/r.git"), "o")
        XCTAssertEqual(SyncEngine.githubOwner(of: "git@github.com:o/r.git"), "o")
        XCTAssertEqual(SyncEngine.githubOwner(of: "ssh://git@github.com/o/r"), "o")
        XCTAssertNil(SyncEngine.githubOwner(of: "git@bitbucket.org:x/y.git"))
    }
}
