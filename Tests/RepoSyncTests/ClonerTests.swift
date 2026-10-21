import XCTest
@testable import RepoSync

final class ClonerTests: XCTestCase {
    private var sandbox: TestRepos!

    override func setUpWithError() throws {
        sandbox = try TestRepos.makeSandbox()
    }

    override func tearDown() {
        sandbox.cleanup()
    }

    private func repo(_ name: String) -> GitHubRepo {
        GitHubRepo(
            name: name,
            cloneURL: URL(string: "https://github.com/test-org/\(name).git")!,
            sizeKB: 1,
            archived: false,
            owner: "test-org"
        )
    }

    private func partialCloneFolder(_ name: String) -> URL {
        sandbox.folder.appendingPathComponent(".\(name).reposync-cloning")
    }

    func testClonesIntoEmptyFolder() async throws {
        try sandbox.makeRemote("x", commits: 2)

        let outcome = await Cloner.clone(repo("x"), into: sandbox.folder)

        XCTAssertEqual(outcome, .cloned)
        let cloned = sandbox.folder.appendingPathComponent("x")
        XCTAssertEqual(try sandbox.git(["config", "--get", "remote.origin.url"], in: cloned), "https://github.com/test-org/x.git")
        XCTAssertEqual(try sandbox.git(["branch", "--show-current"], in: cloned), "main")
        XCTAssertFalse(FileManager.default.fileExists(atPath: partialCloneFolder("x").path))
    }

    func testExistingGitRepoIsLeftAlone() async throws {
        try sandbox.makeRemote("x", commits: 1)
        let existing = try sandbox.clone("x")
        let headBefore = try sandbox.git(["rev-parse", "HEAD"], in: existing)
        try sandbox.advance("x", by: 2)

        let outcome = await Cloner.clone(repo("x"), into: sandbox.folder)

        XCTAssertEqual(outcome, .alreadyExists)
        XCTAssertEqual(try sandbox.git(["rev-parse", "HEAD"], in: existing), headBefore)
    }

    func testExistingNonGitFolderIsLeftAlone() async throws {
        try sandbox.makeRemote("x", commits: 1)
        let existing = sandbox.folder.appendingPathComponent("x")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try "mine".write(to: existing.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let outcome = await Cloner.clone(repo("x"), into: sandbox.folder)

        XCTAssertEqual(outcome, .alreadyExists)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: existing.path), ["notes.txt"])
    }

    func testExistingFileWithTheNameIsLeftAlone() async throws {
        try sandbox.makeRemote("x", commits: 1)
        let existing = sandbox.folder.appendingPathComponent("x")
        try "mine".write(to: existing, atomically: true, encoding: .utf8)

        let outcome = await Cloner.clone(repo("x"), into: sandbox.folder)

        XCTAssertEqual(outcome, .alreadyExists)
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "mine")
    }

    func testLeftoverPartialCloneIsReplaced() async throws {
        try sandbox.makeRemote("x", commits: 1)
        let leftover = partialCloneFolder("x")
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try "junk".write(to: leftover.appendingPathComponent("junk"), atomically: true, encoding: .utf8)

        let outcome = await Cloner.clone(repo("x"), into: sandbox.folder)

        XCTAssertEqual(outcome, .cloned)
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sandbox.folder.appendingPathComponent("x/.git").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.folder.appendingPathComponent("x/junk").path))
    }

    func testFailedCloneLeavesNothing() async throws {
        let outcome = await Cloner.clone(repo("missing"), into: sandbox.folder)

        guard case .failed(let reason) = outcome else { return XCTFail("expected failure, got \(outcome)") }
        XCTAssertTrue(reason.contains("missing.git"), reason)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.folder.appendingPathComponent("missing").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partialCloneFolder("missing").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sandbox.folder.path), [])
    }

    func testMissingDestinationFolderIsNotCreated() async throws {
        try sandbox.makeRemote("x", commits: 1)
        let missing = sandbox.folder.appendingPathComponent("moved-away")

        let outcome = await Cloner.clone(repo("x"), into: missing)

        guard case .failed = outcome else { return XCTFail("expected failure, got \(outcome)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testDiscoverIgnoresInProgressClones() async throws {
        try sandbox.makeRemote("done", commits: 1)
        try sandbox.makeRemote("busy", commits: 1)
        try sandbox.clone("done")
        let inProgress = partialCloneFolder("busy")
        try sandbox.git(["clone", "-q", "\(TestRepos.remoteURLPrefix)busy.git", inProgress.path], in: sandbox.root)

        let found = await SyncEngine.discover(folder: sandbox.folder, filter: .allGitHub, organizations: [])

        XCTAssertEqual(found.map(\.name), ["done"])
    }

    func testParsesLastReceivingPercentFromCarriageReturnedProgress() {
        let stderr = "Cloning into 'x'...\rReceiving objects:   3% (1/30)\rReceiving objects:  57% (17/30)\rReceiving objects: 100% (30/30), done.\nResolving deltas: 100% (4/4), done.\n"

        XCTAssertEqual(Cloner.lastReceivingPercent(in: stderr), 100)
        XCTAssertNil(Cloner.lastReceivingPercent(in: "fatal: nope"))
    }
}
