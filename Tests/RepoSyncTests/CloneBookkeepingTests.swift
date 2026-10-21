import XCTest
@testable import RepoSync

final class CloneBookkeepingTests: XCTestCase {
    private func result(cloned: [String] = [], deleted: Set<String> = [], listed: Bool = true) -> CloneStepResult {
        CloneStepResult(cloned: cloned, failed: [], deleted: deleted, tokenRevoked: false, listed: listed)
    }

    func testDeletedRepoIsReportedAndStaysKnown() {
        let update = CloneBookkeeping.apply(
            result: result(deleted: ["gone"]), present: ["here"], known: ["gone", "here"], exclusions: [], pending: []
        )

        XCTAssertEqual(update.pendingDeletions, ["gone"])
        XCTAssertEqual(update.knownRepos, ["gone", "here"])
    }

    func testKnownIsAUnionSoDeletedRepoIsNotRecloned() {
        let first = CloneBookkeeping.apply(
            result: result(deleted: ["gone"]), present: ["here"], known: ["gone", "here"], exclusions: [], pending: []
        )
        let second = ClonePlanner.plan(
            orgRepos: [repo("gone"), repo("here")], present: ["here"], known: first.knownRepos, excluded: []
        )

        XCTAssertEqual(second.toClone, [])
        XCTAssertEqual(second.deleted, ["gone"])
    }

    func testRepoExcludedDuringRunStaysDismissed() {
        let update = CloneBookkeeping.apply(
            result: result(deleted: ["gone"]), present: [], known: ["gone"], exclusions: ["gone"], pending: []
        )

        XCTAssertEqual(update.pendingDeletions, [])
    }

    func testRepoRecloneRequestedDuringRunStaysDismissedAndUnknown() {
        let update = CloneBookkeeping.apply(
            result: result(deleted: ["gone"]), present: ["here"], known: ["here"], exclusions: [], pending: []
        )

        XCTAssertEqual(update.pendingDeletions, [])
        XCTAssertEqual(update.knownRepos, ["here"])
        let next = ClonePlanner.plan(orgRepos: [repo("gone"), repo("here")], present: ["here"], known: update.knownRepos, excluded: [])
        XCTAssertEqual(next.toClone.map(\.name), ["gone"])
    }

    func testFirstListedRunInitialisesKnown() {
        let update = CloneBookkeeping.apply(
            result: result(cloned: ["new"]), present: ["here"], known: nil, exclusions: [], pending: []
        )

        XCTAssertEqual(update.knownRepos, ["here", "new"])
    }

    func testUnlistedRunLeavesStateAlone() {
        let nothingKnown = CloneBookkeeping.apply(
            result: result(listed: false), present: ["here"], known: nil, exclusions: [], pending: ["x"]
        )
        XCTAssertNil(nothingKnown.knownRepos)
        XCTAssertEqual(nothingKnown.pendingDeletions, ["x"])

        let known = CloneBookkeeping.apply(
            result: result(listed: false), present: ["here"], known: ["old"], exclusions: [], pending: ["x"]
        )
        XCTAssertEqual(known.knownRepos, ["old", "here"])
        XCTAssertEqual(known.pendingDeletions, ["x"])
    }

    func testDeletionStaysPendingWhenKnownDiffersOnlyInCase() {
        let update = CloneBookkeeping.apply(
            result: result(deleted: ["foo"]), present: [], known: ["Foo"], exclusions: [], pending: []
        )

        XCTAssertEqual(update.pendingDeletions, ["foo"])
    }

    func testExclusionDifferingOnlyInCaseDismissesTheDeletion() {
        let update = CloneBookkeeping.apply(
            result: result(deleted: ["foo"]), present: [], known: ["foo"], exclusions: ["FOO"], pending: []
        )

        XCTAssertEqual(update.pendingDeletions, [])
    }

    func testKnownKeepsOneSpellingPerRepo() {
        let update = CloneBookkeeping.apply(
            result: result(cloned: ["Foo"]), present: ["foo", "bar"], known: ["foo"], exclusions: [], pending: []
        )

        XCTAssertEqual(update.knownRepos, ["foo", "bar"])
    }

    func testFollowUpSyncRunsAfterCurrentOneWhenRequestedMidSync() {
        var followUp = FollowUpSync()

        XCTAssertFalse(followUp.request(whileSyncing: true))
        XCTAssertTrue(followUp.finishSync())
        XCTAssertFalse(followUp.finishSync())
    }

    func testRequestWhileIdleStartsImmediately() {
        var followUp = FollowUpSync()

        XCTAssertTrue(followUp.request(whileSyncing: false))
        XCTAssertFalse(followUp.finishSync())
    }

    private func repo(_ name: String) -> GitHubRepo {
        GitHubRepo(name: name, cloneURL: URL(string: "https://github.com/test-org/\(name).git")!, sizeKB: 1, archived: false, owner: "test-org")
    }
}
