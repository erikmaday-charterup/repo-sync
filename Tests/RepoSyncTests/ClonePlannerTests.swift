import XCTest
@testable import RepoSync

final class ClonePlannerTests: XCTestCase {
    private func repo(_ name: String, archived: Bool = false) -> GitHubRepo {
        GitHubRepo(
            name: name,
            cloneURL: URL(string: "https://github.com/test-org/\(name).git")!,
            sizeKB: 1,
            archived: archived,
            owner: "test-org"
        )
    }

    func testFirstRunClonesMissingAndDetectsNoDeletions() {
        let plan = ClonePlanner.plan(
            orgRepos: [repo("a"), repo("b"), repo("c")],
            present: ["a"],
            known: nil,
            excluded: []
        )

        XCTAssertEqual(plan.toClone.map(\.name), ["b", "c"])
        XCTAssertEqual(plan.deleted, [])
    }

    func testArchivedRepoIsNotCloned() {
        let plan = ClonePlanner.plan(
            orgRepos: [repo("old", archived: true), repo("live")],
            present: [],
            known: nil,
            excluded: []
        )

        XCTAssertEqual(plan.toClone.map(\.name), ["live"])
    }

    func testExcludedRepoIsNotClonedOrReportedDeleted() {
        let plan = ClonePlanner.plan(
            orgRepos: [repo("skip-me"), repo("keep")],
            present: ["keep"],
            known: ["skip-me", "keep"],
            excluded: ["skip-me"]
        )

        XCTAssertEqual(plan.toClone, [])
        XCTAssertEqual(plan.deleted, [])
    }

    func testDeletedRepoIsReportedNotRecloned() {
        let plan = ClonePlanner.plan(
            orgRepos: [repo("gone"), repo("here")],
            present: ["here"],
            known: ["gone", "here"],
            excluded: []
        )

        XCTAssertEqual(plan.deleted, ["gone"])
        XCTAssertEqual(plan.toClone, [])
    }

    func testRepoRemovedFromGitHubIsNotReportedDeleted() {
        let plan = ClonePlanner.plan(
            orgRepos: [repo("here")],
            present: ["here"],
            known: ["here", "removed-upstream"],
            excluded: []
        )

        XCTAssertEqual(plan.deleted, [])
        XCTAssertEqual(plan.toClone, [])
    }

    func testNewOrgRepoIsCloned() {
        let plan = ClonePlanner.plan(
            orgRepos: [repo("here"), repo("brand-new")],
            present: ["here"],
            known: ["here"],
            excluded: []
        )

        XCTAssertEqual(plan.toClone.map(\.name), ["brand-new"])
        XCTAssertEqual(plan.deleted, [])
    }

    func testSameNameInTwoOrgsIsClonedOnce() {
        let plan = ClonePlanner.plan(
            orgRepos: [repo("shared"), repo("shared")],
            present: [],
            known: nil,
            excluded: []
        )

        XCTAssertEqual(plan.toClone.count, 1)
    }

    func testFolderDifferingOnlyInCaseCountsAsPresent() {
        let plan = ClonePlanner.plan(orgRepos: [repo("Foo")], present: ["foo"], known: nil, excluded: [])

        XCTAssertEqual(plan.toClone, [])
        XCTAssertEqual(plan.deleted, [])
    }

    func testDeletingFolderDifferingOnlyInCaseIsDetected() {
        let plan = ClonePlanner.plan(orgRepos: [repo("Foo")], present: [], known: ["foo"], excluded: [])

        XCTAssertEqual(plan.deleted, ["foo"])
        XCTAssertEqual(plan.toClone, [])
    }

    func testExclusionDifferingOnlyInCaseIsHonoured() {
        let plan = ClonePlanner.plan(orgRepos: [repo("Foo")], present: [], known: ["foo"], excluded: ["FOO"])

        XCTAssertEqual(plan.toClone, [])
        XCTAssertEqual(plan.deleted, [])
    }

    func testNamesDifferingOnlyInCaseAreClonedOnce() {
        let plan = ClonePlanner.plan(orgRepos: [repo("Shared"), repo("shared")], present: [], known: nil, excluded: [])

        XCTAssertEqual(plan.toClone.map(\.name), ["Shared"])
    }
}
