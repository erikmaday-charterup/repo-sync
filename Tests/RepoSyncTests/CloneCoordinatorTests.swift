import XCTest
@testable import RepoSync

@MainActor
final class CloneCoordinatorTests: XCTestCase {
    private func repo(_ name: String, owner: String = "test-org") -> GitHubRepo {
        GitHubRepo(
            name: name,
            cloneURL: URL(string: "https://github.com/\(owner)/\(name).git")!,
            sizeKB: 1,
            archived: false,
            owner: owner
        )
    }

    func testClonesPlannedReposAndReportsProgress() async {
        var progressCalls: [[Int]] = []
        let coordinator = CloneCoordinator(
            listRepos: { _ in [self.repo("a"), self.repo("b"), self.repo("present")] },
            clone: { _ in .cloned }
        )

        let result = await coordinator.run(orgs: ["test-org"], present: ["present"], known: nil, excluded: []) { done, total in
            progressCalls.append([done, total])
        }

        XCTAssertEqual(result.cloned.sorted(), ["a", "b"])
        XCTAssertEqual(result.failed, [])
        XCTAssertFalse(result.tokenRevoked)
        XCTAssertFalse(result.listingFailed)
        XCTAssertEqual(progressCalls.last, [2, 2])
        XCTAssertEqual(progressCalls.map { $0[1] }, [2, 2, 2])
    }

    func testUnauthorizedListingReportsRevokedAndClonesNothing() async {
        var cloneCalls = 0
        let coordinator = CloneCoordinator(
            listRepos: { org in
                if org == "second" { throw GitHubError.unauthorized }
                return [self.repo("a")]
            },
            clone: { _ in cloneCalls += 1; return .cloned }
        )

        let result = await coordinator.run(orgs: ["first", "second"], present: [], known: nil, excluded: []) { _, _ in }

        XCTAssertTrue(result.tokenRevoked)
        XCTAssertEqual(result.cloned, [])
        XCTAssertEqual(cloneCalls, 0)
    }

    func testCloneFailureIsReportedNotThrown() async {
        let coordinator = CloneCoordinator(
            listRepos: { _ in [self.repo("good"), self.repo("bad")] },
            clone: { $0.name == "bad" ? .failed("disk full") : .cloned }
        )

        let result = await coordinator.run(orgs: ["test-org"], present: [], known: nil, excluded: []) { _, _ in }

        XCTAssertEqual(result.cloned, ["good"])
        XCTAssertEqual(result.failed, [FailedRepo(name: "bad", reason: "disk full")])
    }

    func testListingFailureIsReportedAndOtherOrgsStillClone() async {
        let coordinator = CloneCoordinator(
            listRepos: { org in
                if org == "down" { throw GitHubError.http(503) }
                return [self.repo("a")]
            },
            clone: { _ in .cloned }
        )

        let result = await coordinator.run(orgs: ["down", "up"], present: [], known: nil, excluded: []) { _, _ in }

        XCTAssertEqual(result.cloned, ["a"])
        XCTAssertEqual(result.failed.map(\.name), ["down"])
        XCTAssertTrue(result.listed)
        XCTAssertTrue(result.listingFailed)
    }

    func testNothingListedWhenEveryOrgFails() async {
        let coordinator = CloneCoordinator(
            listRepos: { _ in throw GitHubError.http(503) },
            clone: { _ in .cloned }
        )

        let result = await coordinator.run(orgs: ["down"], present: [], known: nil, excluded: []) { _, _ in }

        XCTAssertFalse(result.listed)
        XCTAssertEqual(result.deleted, [])
    }

    func testAlreadyExistingFolderIsNeitherClonedNorFailed() async {
        let coordinator = CloneCoordinator(
            listRepos: { _ in [self.repo("racy")] },
            clone: { _ in .alreadyExists }
        )

        let result = await coordinator.run(orgs: ["test-org"], present: [], known: nil, excluded: []) { _, _ in }

        XCTAssertEqual(result.cloned, [])
        XCTAssertEqual(result.failed, [])
    }

    func testReportsDeletedRepos() async {
        let coordinator = CloneCoordinator(
            listRepos: { _ in [self.repo("gone"), self.repo("here")] },
            clone: { _ in .cloned }
        )

        let result = await coordinator.run(orgs: ["test-org"], present: ["here"], known: ["gone", "here"], excluded: []) { _, _ in }

        XCTAssertEqual(result.deleted, ["gone"])
        XCTAssertEqual(result.cloned, [])
    }

    func testClonesFromLocalRemotesThroughCloner() async throws {
        let sandbox = try TestRepos.makeSandbox()
        defer { sandbox.cleanup() }
        try sandbox.makeRemote("alpha", commits: 1)
        try sandbox.makeRemote("beta", commits: 1)
        let coordinator = CloneCoordinator(
            listRepos: { _ in [self.repo("alpha"), self.repo("beta")] },
            clone: { await Cloner.clone($0, into: sandbox.folder) }
        )

        let result = await coordinator.run(orgs: ["test-org"], present: [], known: nil, excluded: []) { _, _ in }

        XCTAssertEqual(result.cloned, ["alpha", "beta"])
        for name in ["alpha", "beta"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: sandbox.folder.appendingPathComponent(name).appendingPathComponent(".git").path))
        }
    }
}
