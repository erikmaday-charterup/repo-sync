import XCTest
@testable import RepoSync

@MainActor
private final class StepHarness {
    static let codeFolder = URL(fileURLWithPath: "/Users/someone/Code")
    static let otherFolder = URL(fileURLWithPath: "/Users/someone/Other")

    var folder: URL? = codeFolder
    var cloneOrgs = ["test-org"]
    var known: Set<String>?
    var exclusions: Set<String> = []
    var pending: [String] = []
    var existingFolders: Set<URL> = [codeFolder]
    var entries: Set<String> = []

    var hasRepoToCheck = true
    var accessResults: [AccessState] = [.working]
    var accessChecks = 0

    var token: String? = "gho_from_gh"
    var tokenReads = 0
    var loginRejections = 0
    var coordinatorTokens: [String] = []

    var orgRepos: [GitHubRepo] = []
    var listError: GitHubError?
    var whileListing: () -> Void = {}
    var listedOrgs: [String] = []
    var cloned: [String] = []
    var logs: [String] = []

    var step: CloneStep {
        CloneStep(
            settings: { [unowned self] in
                CloneStepSettings(folder: folder, cloneOrgs: cloneOrgs, known: known, exclusions: exclusions, pending: pending)
            },
            folderExists: { [unowned self] in existingFolders.contains($0) },
            folderEntries: { [unowned self] _ in entries },
            checkAccess: { [unowned self] in
                guard hasRepoToCheck else { return nil }
                accessChecks += 1
                return accessResults.count > 1 ? accessResults.removeFirst() : accessResults[0]
            },
            readToken: { [unowned self] in
                tokenReads += 1
                return token
            },
            loginRejected: { [unowned self] in loginRejections += 1 },
            makeCoordinator: { [unowned self] token, _ in
                coordinatorTokens.append(token)
                return CloneCoordinator(
                    listRepos: { org in
                        self.listedOrgs.append(org)
                        self.whileListing()
                        if let error = self.listError { throw error }
                        return self.orgRepos
                    },
                    clone: { repo in
                        self.cloned.append(repo.name)
                        return .cloned
                    }
                )
            },
            log: { [unowned self] in logs.append($0) }
        )
    }

    func repo(_ name: String) -> GitHubRepo {
        GitHubRepo(name: name, cloneURL: URL(string: "https://github.com/test-org/\(name).git")!, sizeKB: 1, archived: false, owner: "test-org")
    }
}

@MainActor
final class CloneStepTests: XCTestCase {
    private var harness: StepHarness!

    override func setUp() {
        harness = StepHarness()
    }

    // MARK: Missing folder

    func testMissingFolderStopsTheRunBeforeCheckingAccess() async {
        harness.existingFolders = []

        let preflight = await harness.step.preflight()

        XCTAssertEqual(preflight, .folderMissing)
        XCTAssertEqual(harness.accessChecks, 0)
    }

    func testMissingFolderClonesNothingAndReportsNoDeletions() async {
        harness.existingFolders = []
        harness.known = ["a", "b"]
        harness.orgRepos = [harness.repo("a"), harness.repo("b"), harness.repo("c")]

        let run = await harness.step.cloneNewRepos()

        XCTAssertNil(run)
        XCTAssertEqual(harness.listedOrgs, [])
        XCTAssertEqual(harness.cloned, [])
    }

    func testFolderWithNoReposHasNothingToCheck() async {
        harness.hasRepoToCheck = false

        let preflight = await harness.step.preflight()

        XCTAssertEqual(preflight, .nothingToCheck)
    }

    // MARK: Access

    func testWorkingAccessIsReported() async {
        let preflight = await harness.step.preflight()

        XCTAssertEqual(preflight, .checked(.working))
        XCTAssertEqual(harness.tokenReads, 0)
    }

    func testRefusedAccessIsReportedAsIsWithoutTouchingGitsLogin() async {
        harness.accessResults = [.refused(detail: "Authentication failed"), .working]

        let preflight = await harness.step.preflight()

        XCTAssertEqual(preflight, .checked(.refused(detail: "Authentication failed")))
        XCTAssertEqual(harness.accessChecks, 1)
        XCTAssertEqual(harness.tokenReads, 0)
        XCTAssertEqual(harness.loginRejections, 0)
    }

    func testUnreachableGitHubIsReportedAsIs() async {
        harness.accessResults = [.unreachable(detail: "Could not resolve host")]

        let preflight = await harness.step.preflight()

        XCTAssertEqual(preflight, .checked(.unreachable(detail: "Could not resolve host")))
    }

    // MARK: Cloning and bookkeeping

    func testClonesNewReposWithGhsTokenAndRecordsThemAsKnown() async throws {
        harness.entries = ["here"]
        harness.orgRepos = [harness.repo("here"), harness.repo("new")]

        let cloneRun = await harness.step.cloneNewRepos()
        let run = try XCTUnwrap(cloneRun)

        XCTAssertEqual(run.result.cloned, ["new"])
        XCTAssertEqual(run.bookkeeping?.knownRepos, ["here", "new"])
        XCTAssertEqual(harness.coordinatorTokens, ["gho_from_gh"])
    }

    func testWithoutGhsTokenNothingIsListedOrCloned() async {
        harness.token = nil
        harness.orgRepos = [harness.repo("new")]

        let run = await harness.step.cloneNewRepos()

        XCTAssertNil(run)
        XCTAssertEqual(harness.listedOrgs, [])
        XCTAssertEqual(harness.loginRejections, 0)
    }

    func testFolderChangedDuringTheRunDiscardsBookkeeping() async throws {
        harness.known = ["here"]
        harness.entries = ["here"]
        harness.orgRepos = [harness.repo("here"), harness.repo("new")]
        let harness = harness!
        harness.whileListing = { [unowned harness] in
            harness.folder = StepHarness.otherFolder
            harness.existingFolders.insert(StepHarness.otherFolder)
            harness.known = nil
        }

        let cloneRun = await harness.step.cloneNewRepos()
        let run = try XCTUnwrap(cloneRun)

        XCTAssertEqual(run.result.cloned, ["new"])
        XCTAssertNil(run.bookkeeping)
    }

    func testFolderVanishingDuringTheRunDiscardsBookkeeping() async throws {
        harness.known = ["here", "gone"]
        harness.entries = ["here"]
        harness.orgRepos = [harness.repo("here"), harness.repo("gone")]
        let harness = harness!
        harness.whileListing = { [unowned harness] in harness.existingFolders = [] }

        let cloneRun = await harness.step.cloneNewRepos()
        let run = try XCTUnwrap(cloneRun)

        XCTAssertNil(run.bookkeeping)
    }

    func testGitHubRejectingGhsLoginWhileListingReportsItAndDiscardsBookkeeping() async throws {
        harness.listError = .unauthorized

        let cloneRun = await harness.step.cloneNewRepos()
        let run = try XCTUnwrap(cloneRun)

        XCTAssertTrue(run.result.tokenRevoked)
        XCTAssertNil(run.bookkeeping)
        XCTAssertEqual(harness.loginRejections, 1)
        XCTAssertTrue(harness.logs.contains("GitHub rejected gh's login, so new repos weren't cloned"), "\(harness.logs)")
    }

    func testFolderDifferingOnlyInCaseIsPresentAndItsDeletionIsDetected() async throws {
        harness.orgRepos = [harness.repo("Foo")]
        harness.entries = ["foo"]

        let firstRun = await harness.step.cloneNewRepos()
        let first = try XCTUnwrap(firstRun)
        XCTAssertEqual(harness.cloned, [])
        XCTAssertEqual(first.bookkeeping?.knownRepos, ["foo"])

        harness.known = first.bookkeeping?.knownRepos
        harness.entries = []
        let secondRun = await harness.step.cloneNewRepos()
        let second = try XCTUnwrap(secondRun)

        XCTAssertEqual(harness.cloned, [])
        XCTAssertEqual(second.bookkeeping?.pendingDeletions, ["foo"])
    }

    func testStartsCloningOnlyWhenThereIsSomethingToDo() async {
        var started = 0
        harness.cloneOrgs = []

        let run = await harness.step.cloneNewRepos(onStart: { started += 1 })

        XCTAssertNil(run)
        XCTAssertEqual(started, 0)
    }
}
