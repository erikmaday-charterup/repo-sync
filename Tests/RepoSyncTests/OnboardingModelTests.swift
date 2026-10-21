import XCTest
@testable import RepoSync

@MainActor
private final class FakeSettings: OnboardingSettings {
    var folderPath: String?
    var filter: RepoFilter = .allGitHub
    var organizations = ""
    var cloneOrgs: [String] = []
    var exclusions: Set<String> = []
    var knownRepos: Set<String>?
    var setup: SetupReport?
    var syncRequests = 0

    func exclude(_ name: String) { exclusions.insert(name) }

    func unexclude(_ name: String) {
        exclusions.remove(name)
        knownRepos?.remove(name)
    }

    func requestSync() { syncRequests += 1 }
}

private final class FixtureTransport {
    private var responses: [String: (status: Int, body: Data)] = [:]
    private(set) var requests: [String] = []

    func respond(_ url: String, fixture: String, status: Int = 200) throws {
        let fixtureURL = try XCTUnwrap(Bundle.module.url(forResource: fixture, withExtension: "json", subdirectory: "Fixtures"))
        responses[url] = (status, try Data(contentsOf: fixtureURL))
    }

    func respond(_ url: String, status: Int) {
        responses[url] = (status, Data("{}".utf8))
    }

    func respond(_ url: String, body: String) {
        responses[url] = (200, Data(body.utf8))
    }

    var transport: HTTPTransport {
        { [self] request in
            let key = request.url?.absoluteString ?? ""
            requests.append(key)
            guard let response = responses[key] else { throw URLError(.notConnectedToInternet) }
            return (response.body, HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: nil, headerFields: nil)!)
        }
    }
}

@MainActor
final class OnboardingModelTests: XCTestCase {
    private let membershipsURL = "https://api.github.com/user/memberships/orgs?state=active"
    private let anotherOrgReposURL = "https://api.github.com/orgs/another-org/repos?per_page=100&type=all"

    private var directory: URL!
    private var settings: FakeSettings!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("OnboardingModelTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        settings = FakeSettings()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeModel(
        start: OnboardingStep = .welcome,
        checkSetup: @escaping () async -> SetupReport = { .ready },
        requestGitInstall: @escaping () -> Void = {},
        sleep: @escaping (Int) async -> Void = { _ in try? await Task.sleep(nanoseconds: 60_000_000_000) }
    ) -> OnboardingModel {
        OnboardingModel(
            settings: settings,
            start: start,
            checkSetup: checkSetup,
            requestGitInstall: requestGitInstall,
            makeClient: { nil },
            sleep: sleep,
            homeDirectory: directory
        )
    }

    private func repo(_ name: String, sizeKB: Int = 1000, archived: Bool = false) -> GitHubRepo {
        GitHubRepo(
            name: name,
            cloneURL: URL(string: "https://github.com/test-org/\(name).git")!,
            sizeKB: sizeKB,
            archived: archived,
            owner: "test-org"
        )
    }

    // MARK: Launch rule

    func testInitialStepForNewUser() {
        XCTAssertEqual(OnboardingModel.initialStep(folderConfigured: false, setupReady: false), .welcome)
        XCTAssertEqual(OnboardingModel.initialStep(folderConfigured: false, setupReady: true), .welcome)
    }

    func testInitialStepForExistingUserWhoseChecklistFails() {
        XCTAssertEqual(OnboardingModel.initialStep(folderConfigured: true, setupReady: false), .checklist)
    }

    func testInitialStepWhenSetUp() {
        XCTAssertNil(OnboardingModel.initialStep(folderConfigured: true, setupReady: true))
    }

    func testChooseReposWhileTheChecklistFailsStartsAtTheChecklist() {
        XCTAssertEqual(OnboardingModel.resolvedStart(.repos, setupReady: false, folderConfigured: true), .checklist)
        XCTAssertEqual(OnboardingModel.resolvedStart(.repos, setupReady: true, folderConfigured: true), .repos)
        XCTAssertEqual(OnboardingModel.resolvedStart(.checklist, setupReady: true, folderConfigured: true), .checklist)
    }

    func testChooseReposWithoutAFolderStartsAtFolder() {
        XCTAssertEqual(OnboardingModel.resolvedStart(.repos, setupReady: true, folderConfigured: false), .folder)
        XCTAssertEqual(OnboardingModel.resolvedStart(.repos, setupReady: false, folderConfigured: false), .checklist)
    }

    // MARK: Navigation

    func testNextFromWelcomeGoesToTheChecklist() {
        let model = makeModel()
        model.next()
        XCTAssertEqual(model.step, .checklist)
        model.close()
    }

    func testBackReturnsToThePreviousStepAndNotBeforeTheFirst() {
        settings.setup = .ready
        let model = makeModel(start: .folder)
        XCTAssertFalse(model.canGoBack)
        model.back()
        XCTAssertEqual(model.step, .folder)

        model.next()
        XCTAssertEqual(model.step, .repos)
        XCTAssertTrue(model.canGoBack)
        model.back()
        XCTAssertEqual(model.step, .folder)
    }

    func testConfirmingTheFolderCreatesItAndMovesOnToRepos() throws {
        let model = makeModel(start: .folder)
        model.folder = directory.appendingPathComponent("Code")
        model.confirmFolder()
        XCTAssertEqual(model.step, .repos)
        XCTAssertEqual(settings.folderPath, directory.appendingPathComponent("Code").path)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Code").path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testFolderDefaultsToCodeInHomeOrTheConfiguredFolder() {
        XCTAssertEqual(makeModel().folder.path, directory.appendingPathComponent("Code").path)
        settings.folderPath = "/tmp/elsewhere"
        XCTAssertEqual(makeModel(start: .checklist).folder.path, "/tmp/elsewhere")
    }

    func testFolderStatusCountsReposAlreadyThere() throws {
        let folder = directory.appendingPathComponent("Code")
        XCTAssertEqual(FolderStatus.of(folder), .new)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertEqual(FolderStatus.of(folder), .empty)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("pricing/.git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("notes"), withIntermediateDirectories: true)
        XCTAssertEqual(FolderStatus.of(folder), .repos(1))
        XCTAssertEqual(FolderStatus.repos(1).description, "Found 1 repo already here.")
        XCTAssertEqual(FolderStatus.new.description, "New folder. Nothing cloned here yet.")
    }

    // MARK: Repo choices

    func testArchivedStartUnselected() {
        let choices = OnboardingModel.choices(
            for: [repo("old-thing", archived: true), repo("pricing")], present: [], excluded: [], known: nil
        )
        XCTAssertEqual(choices.map(\.repo.name), ["old-thing", "pricing"])
        XCTAssertEqual(choices.map(\.selected), [false, true])
    }

    func testAlreadyHereStartsSelected() {
        let choices = OnboardingModel.choices(
            for: [repo("pricing"), repo("legacy", archived: true)], present: ["pricing", "legacy"], excluded: [], known: nil
        )
        XCTAssertEqual(choices.map(\.repo.name), ["legacy", "pricing"])
        XCTAssertEqual(choices.map(\.alreadyHere), [true, true])
        XCTAssertEqual(choices.map(\.selected), [true, true])
    }

    func testExcludedAndPreviouslyDeletedStartUnselected() {
        let choices = OnboardingModel.choices(
            for: [repo("excluded-here"), repo("deleted"), repo("new-one")],
            present: ["excluded-here"],
            excluded: ["excluded-here"],
            known: ["excluded-here", "deleted"]
        )
        XCTAssertEqual(choices.map(\.repo.name), ["deleted", "excluded-here", "new-one"])
        XCTAssertEqual(choices.map(\.selected), [false, false, true])
    }

    func testFolderDifferingOnlyInCaseIsAlreadyHere() {
        let choices = OnboardingModel.choices(
            for: [repo("Here"), repo("Gone"), repo("Skipped")], present: ["here"], excluded: ["skipped"], known: ["gone", "here"]
        )

        XCTAssertEqual(choices.map(\.alreadyHere), [false, true, false])
        XCTAssertEqual(choices.map(\.selected), [false, true, false])
    }

    func testSelectedSizeSumsSelectedOnly() {
        let model = makeModel(start: .repos)
        model.repoChoices = [
            RepoChoice(repo: repo("a", sizeKB: 100), selected: true, alreadyHere: false),
            RepoChoice(repo: repo("b", sizeKB: 20), selected: true, alreadyHere: true),
            RepoChoice(repo: repo("c", sizeKB: 5000, archived: true), selected: false, alreadyHere: false)
        ]
        XCTAssertEqual(model.selectedSize, 120)
        XCTAssertEqual(model.selectedCount, 2)
        XCTAssertEqual(model.cloneCount, 1)
    }

    func testArchivedRepoNotHereCanNeverBeSelectedOrCloned() {
        let model = makeModel(start: .repos)
        model.repoChoices = OnboardingModel.choices(
            for: [repo("old-thing", archived: true), repo("kept-archive", archived: true), repo("pricing")],
            present: ["kept-archive"], excluded: [], known: nil
        )
        XCTAssertEqual(model.repoChoices.map(\.isSelectable), [true, false, true])

        model.selectAll()
        model.repoChoices[1].selected = true

        XCTAssertEqual(model.repoChoices.map(\.selected), [true, false, true])
        XCTAssertEqual(model.selectedCount, 2)
        XCTAssertEqual(model.cloneCount, 1)
    }

    func testFinishingLeavesArchivedReposThatAreNotHereOutOfExclusions() {
        let model = makeModel(start: .repos)
        model.showRepos(org: "test-org", choices: OnboardingModel.choices(
            for: [repo("old-thing", archived: true), repo("kept-archive", archived: true), repo("pricing")],
            present: ["kept-archive"], excluded: [], known: nil
        ))
        model.repoChoices[0].selected = false

        model.finishRepos()

        XCTAssertEqual(settings.exclusions, ["kept-archive"])
    }

    func testSelectAllAndNone() {
        let model = makeModel(start: .repos)
        model.repoChoices = [
            RepoChoice(repo: repo("a"), selected: true, alreadyHere: false),
            RepoChoice(repo: repo("b"), selected: false, alreadyHere: false)
        ]
        model.selectAll()
        XCTAssertEqual(model.selectedCount, 2)
        model.selectNone()
        XCTAssertEqual(model.selectedCount, 0)
    }

    func testFinishingReposExcludesUnselected() {
        let model = makeModel(start: .repos)
        model.showRepos(org: "test-org", choices: [
            RepoChoice(repo: repo("wanted"), selected: true, alreadyHere: false),
            RepoChoice(repo: repo("unwanted"), selected: false, alreadyHere: false),
            RepoChoice(repo: repo("here-but-unwanted"), selected: false, alreadyHere: true),
            RepoChoice(repo: repo("here-and-kept"), selected: true, alreadyHere: true)
        ])

        model.finishRepos()

        XCTAssertEqual(settings.exclusions, ["unwanted", "here-but-unwanted"])
        XCTAssertEqual(settings.cloneOrgs, ["test-org"])
        XCTAssertEqual(settings.syncRequests, 1)
        XCTAssertEqual(model.step, .cloning)
    }

    func testFinishingReposIncludesReselectedRepos() {
        settings.folderPath = "/tmp/code"
        settings.exclusions = ["was-excluded", "other-org-repo"]
        settings.knownRepos = ["was-deleted", "here"]
        let model = makeModel(start: .repos)
        model.showRepos(org: "test-org", choices: [
            RepoChoice(repo: repo("was-excluded"), selected: true, alreadyHere: false),
            RepoChoice(repo: repo("was-deleted"), selected: true, alreadyHere: false),
            RepoChoice(repo: repo("here"), selected: true, alreadyHere: true)
        ])

        model.finishRepos()

        XCTAssertEqual(settings.exclusions, ["other-org-repo"])
        XCTAssertEqual(settings.knownRepos, ["here"])
    }

    func testFinishingReposForNewInstallLimitsSyncToTheOrg() {
        let model = makeModel(start: .welcome)
        model.showRepos(org: "test-org", choices: [RepoChoice(repo: repo("a"), selected: true, alreadyHere: false)])

        model.finishRepos()

        XCTAssertEqual(settings.filter, .organizations)
        XCTAssertEqual(settings.organizations, "test-org")
    }

    func testFinishingReposForExistingInstallKeepsTheSyncFilterAndOtherCloneOrgs() {
        settings.folderPath = "/tmp/code"
        settings.cloneOrgs = ["first-org"]
        let model = makeModel(start: .repos)
        model.showRepos(org: "test-org", choices: [RepoChoice(repo: repo("a"), selected: true, alreadyHere: false)])

        model.finishRepos()

        XCTAssertEqual(settings.filter, .allGitHub)
        XCTAssertEqual(settings.organizations, "")
        XCTAssertEqual(settings.cloneOrgs, ["first-org", "test-org"])
    }

    func testFinishingReposAddsTheOrgToAnOrganizationsSyncFilter() {
        settings.folderPath = "/tmp/code"
        settings.filter = .organizations
        settings.organizations = "first-org"
        settings.cloneOrgs = ["first-org"]
        let model = makeModel(start: .repos)
        model.showRepos(org: "test-org", choices: [RepoChoice(repo: repo("a"), selected: true, alreadyHere: false)])

        model.finishRepos()

        XCTAssertEqual(settings.filter, .organizations)
        XCTAssertEqual(settings.organizations, "first-org, test-org")
        XCTAssertEqual(settings.cloneOrgs, ["first-org", "test-org"])
    }

    func testAddingACloneOrgWidensOnlyAnOrganizationsSyncFilter() {
        settings.filter = .organizations
        settings.organizations = "Test-Org"
        settings.addCloneOrg("test-org")
        settings.addCloneOrg("another-org")
        XCTAssertEqual(settings.organizations, "Test-Org, another-org")
        XCTAssertEqual(settings.cloneOrgs, ["test-org", "another-org"])

        settings.filter = .allGitHub
        settings.organizations = ""
        settings.addCloneOrg("third-org")
        XCTAssertEqual(settings.organizations, "")
        XCTAssertEqual(settings.cloneOrgs, ["test-org", "another-org", "third-org"])
    }

    func testOrganizationListParsesAndAddsWithoutDuplicates() {
        XCTAssertEqual(OrganizationList.parse(" a, ,b ,"), ["a", "b"])
        XCTAssertEqual(OrganizationList.adding("c", to: "a,b"), "a, b, c")
        XCTAssertEqual(OrganizationList.adding("B", to: "a, b"), "a, b")
        XCTAssertEqual(OrganizationList.adding("a", to: ""), "a")
    }

    func testFinishingWithNothingToCloneSkipsTheCloningStep() {
        let model = makeModel(start: .repos)
        model.showRepos(org: "test-org", choices: [RepoChoice(repo: repo("here"), selected: true, alreadyHere: true)])

        model.finishRepos()

        XCTAssertEqual(model.step, .done)
        XCTAssertEqual(settings.syncRequests, 1)
    }

    func testRepoSizesReadLikeTheMockup() {
        XCTAssertEqual(RepoSize.text(kilobytes: 95_703), "98 MB")
        XCTAssertEqual(RepoSize.text(kilobytes: 2_050_782), "2.1 GB")
        XCTAssertEqual(RepoSize.text(kilobytes: 12), "12 KB")
        XCTAssertEqual(RepoSize.text(kilobytes: 0), "0 KB")
    }

    // MARK: Checklist

    func testGitVersionShowsMajorAndMinor() {
        XCTAssertEqual(GitInstall.displayVersion(from: "git version 2.54.0 (Apple Git-157)\n"), "2.54")
        XCTAssertEqual(GitInstall.displayVersion(from: "git version 2.39.5\n"), "2.39")
        XCTAssertNil(GitInstall.displayVersion(from: "something else"))
    }

    func testChecklistChecksEveryThreeSecondsUntilEverythingPasses() async {
        let signedOut = SetupReport(gitInstalled: true, ghInstalled: true)
        var reports = [signedOut, signedOut, SetupReport.ready]
        var checks = 0
        var sleeps: [Int] = []
        let model = makeModel(
            start: .checklist,
            checkSetup: {
                checks += 1
                return reports.count > 1 ? reports.removeFirst() : reports[0]
            },
            sleep: { sleeps.append($0) }
        )

        model.begin()
        await model.waitForChecklist()

        XCTAssertEqual(checks, 3)
        XCTAssertEqual(sleeps, [3, 3])
        XCTAssertEqual(model.setup, .ready)
    }

    func testChecklistStopsCheckingWhenClosed() async {
        var checks = 0
        var model: OnboardingModel?
        model = makeModel(
            start: .checklist,
            checkSetup: {
                checks += 1
                return SetupReport(gitInstalled: true)
            },
            sleep: { _ in await MainActor.run { model?.close() } }
        )

        model?.begin()
        await model?.waitForChecklist()

        XCTAssertEqual(checks, 1)
    }

    func testComingBackToTheChecklistChecksAgain() async {
        var checks = 0
        let model = makeModel(start: .checklist, checkSetup: {
            checks += 1
            return .ready
        })

        model.begin()
        await model.waitForChecklist()
        model.next()
        model.back()
        await model.waitForChecklist()

        XCTAssertEqual(model.step, .checklist)
        XCTAssertEqual(checks, 2)
    }

    func testContinueWaitsUntilEveryItemPasses() async {
        var report = SetupReport(gitInstalled: true, ghInstalled: true, ghSignedIn: true)
        var model: OnboardingModel?
        model = makeModel(start: .checklist, checkSetup: { report }, sleep: { _ in model?.close() })

        model?.begin()
        await model?.waitForChecklist()
        XCTAssertEqual(model?.isSetupReady, false)
        XCTAssertEqual(model.map { SetupItem.allCases.map($0.setup!.state(of:)) }, [.passed, .passed, .passed, .failed])
        model?.next()
        XCTAssertEqual(model?.step, .checklist)

        report = .ready
        model?.begin()
        await model?.waitForChecklist()
        XCTAssertEqual(model?.isSetupReady, true)
        model?.next()
        XCTAssertEqual(model?.step, .folder)
    }

    func testChecklistShowsCheckingUntilTheFirstResult() {
        let model = makeModel(start: .checklist)
        XCTAssertNil(model.setup)
        XCTAssertFalse(model.isSetupReady)

        settings.setup = .ready
        XCTAssertEqual(makeModel(start: .checklist).setup, .ready)
    }

    func testInstallingGitWaitsUntilGitWorks() async {
        var installRequests = 0
        var report = SetupReport()
        var model: OnboardingModel?
        model = makeModel(
            start: .checklist,
            checkSetup: { report },
            requestGitInstall: { installRequests += 1 },
            sleep: { _ in model?.close() }
        )

        model?.begin()
        await model?.waitForChecklist()
        model?.installGit()
        XCTAssertEqual(installRequests, 1)
        XCTAssertEqual(model?.isInstallingGit, true)

        report = SetupReport(gitInstalled: true)
        model?.begin()
        await model?.waitForChecklist()
        XCTAssertEqual(model?.isInstallingGit, false)
        XCTAssertEqual(model?.setup?.firstProblem, .gh)
    }

    // MARK: Repo loading

    private func makeNetworkedModel(start: OnboardingStep, http: FixtureTransport, token: String? = "gho_from_gh") -> OnboardingModel {
        let transport = http.transport
        return OnboardingModel(
            settings: settings,
            start: start,
            checkSetup: { SetupReport(gitInstalled: true, ghInstalled: true) },
            requestGitInstall: {},
            makeClient: { token.map { GitHubClient(token: $0, transport: transport) } },
            sleep: { _ in try? await Task.sleep(nanoseconds: 60_000_000_000) },
            homeDirectory: directory
        )
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testReposLoadPrefersACloneOrgAndMarksReposAlreadyHere() async throws {
        let http = FixtureTransport()
        try http.respond(membershipsURL, fixture: "memberships")
        try http.respond(anotherOrgReposURL, fixture: "repos_page2")
        settings.cloneOrgs = ["another-org"]
        settings.folderPath = directory.appendingPathComponent("Code").path
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Code/alpha"), withIntermediateDirectories: true)
        let model = makeNetworkedModel(start: .repos, http: http)

        model.begin()
        await waitUntil { model.reposState != .loading }

        XCTAssertEqual(model.reposState, .loaded)
        XCTAssertEqual(model.orgs, ["another-org", "example-org"])
        XCTAssertEqual(model.selectedOrg, "another-org")
        XCTAssertEqual(model.repoChoices.map(\.repo.name), ["alpha", "beta", "legacy"])
        XCTAssertEqual(model.repoChoices.map(\.alreadyHere), [true, false, false])
        XCTAssertEqual(model.repoChoices.map(\.selected), [true, true, false])
    }

    func testNoOrganizationsLetsYouFinishWithoutCloning() async throws {
        let http = FixtureTransport()
        http.respond(membershipsURL, body: "[]")
        let model = makeNetworkedModel(start: .repos, http: http)

        model.begin()
        await waitUntil { model.reposState != .loading }
        model.finishRepos()

        XCTAssertEqual(model.step, .done)
        XCTAssertEqual(settings.cloneOrgs, [])
        XCTAssertEqual(settings.syncRequests, 0)
    }

    func testGitHubRejectingGhsLoginWhileLoadingReposGoesBackToTheChecklist() async throws {
        let http = FixtureTransport()
        http.respond(membershipsURL, status: 401)
        settings.setup = .ready
        let model = makeNetworkedModel(start: .repos, http: http)

        model.begin()
        await waitUntil { model.step == .checklist }

        XCTAssertEqual(model.step, .checklist)
        XCTAssertEqual(model.setup?.firstProblem, .ghLogin)
        XCTAssertEqual(model.setup?.firstProblem?.command, "gh auth login")
        XCTAssertFalse(model.isSetupReady)
        model.close()
    }

    func testNoTokenFromGhGoesBackToTheChecklist() async {
        settings.setup = .ready
        let model = makeNetworkedModel(start: .repos, http: FixtureTransport(), token: nil)

        model.begin()
        await waitUntil { model.step == .checklist }

        XCTAssertEqual(model.step, .checklist)
        XCTAssertFalse(model.canGoBack)
        model.close()
    }
}

final class CloneActivityTests: XCTestCase {
    func testTracksCurrentAndFinishedClones() {
        var activity = CloneActivity()
        activity.begin(total: 3)
        activity.started("a")
        activity.started("b")
        XCTAssertEqual(activity.current, "b")
        activity.finished("b", outcome: .cloned)
        XCTAssertEqual(activity.current, "a")
        activity.finished("a", outcome: .failed("nope"))
        XCTAssertNil(activity.current)
        XCTAssertEqual(activity.items.map(\.state), [.failed, .cloned])
        XCTAssertEqual(activity.finishedCount, 2)
        XCTAssertEqual(activity.failedCount, 1)
    }

    func testBeginningAgainForgetsTheLastBatch() {
        var activity = CloneActivity()
        activity.begin(total: 1)
        activity.started("a")
        activity.finished("a", outcome: .cloned)
        activity.begin(total: 2)
        XCTAssertEqual(activity.items, [])
        XCTAssertEqual(activity.total, 2)
    }
}
