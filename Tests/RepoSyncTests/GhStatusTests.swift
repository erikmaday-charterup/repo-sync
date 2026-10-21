import XCTest
@testable import RepoSync

private final class FakeGh {
    var installed = true
    var signedIn = true
    var offline = false
    var token = "gho_from_gh\n"
    var gitInstallation: GitInstallation? = GitInstallation(version: "2.54")
    var gitHasLogin = true
    private(set) var calls: [[String]] = []
    private(set) var gitLoginChecks = 0

    var status: GhStatus {
        GhStatus(
            runGh: { [self] arguments in
                calls.append(arguments)
                guard installed else { return CommandResult(status: 127, stdout: "", stderr: "", timedOut: false) }
                switch arguments {
                case ["--version"]:
                    return CommandResult(status: 0, stdout: "gh version 2.87.3 (2026-02-23)\n", stderr: "", timedOut: false)
                case ["auth", "status", "--hostname", "github.com"]:
                    return CommandResult(status: signedIn && !offline ? 0 : 1, stdout: "", stderr: "", timedOut: false)
                case ["auth", "token", "--hostname", "github.com"]:
                    return CommandResult(status: signedIn ? 0 : 1, stdout: signedIn ? token : "", stderr: "", timedOut: false)
                default:
                    return CommandResult(status: 1, stdout: "", stderr: "unexpected", timedOut: false)
                }
            },
            gitInstallation: { [self] in gitInstallation },
            gitHasLogin: { [self] in
                gitLoginChecks += 1
                return gitHasLogin
            }
        )
    }
}

final class GhStatusTests: XCTestCase {
    private var gh: FakeGh!

    override func setUp() {
        gh = FakeGh()
    }

    func testEverythingInPlaceIsReady() async {
        let report = await gh.status.check(probingGitLogin: true)

        XCTAssertTrue(report.isReady)
        XCTAssertNil(report.firstProblem)
        XCTAssertEqual(report.gitVersion, "2.54")
        XCTAssertEqual(gh.calls, [["--version"], ["auth", "token", "--hostname", "github.com"]])
        XCTAssertEqual(gh.gitLoginChecks, 1)
        XCTAssertEqual(SetupItem.allCases.map(report.state(of:)), [.passed, .passed, .passed, .passed])
    }

    func testMissingGitStopsBeforeRunningAnythingElse() async {
        gh.gitInstallation = nil

        let report = await gh.status.check(probingGitLogin: true)

        XCTAssertEqual(report.firstProblem, .git)
        XCTAssertEqual(gh.calls, [])
        XCTAssertEqual(gh.gitLoginChecks, 0)
        XCTAssertEqual(SetupItem.allCases.map(report.state(of:)), [.failed, .waiting, .waiting, .waiting])
    }

    func testMissingGhWaitsOnTheLaterItems() async {
        gh.installed = false

        let report = await gh.status.check(probingGitLogin: true)

        XCTAssertEqual(report.firstProblem, .gh)
        XCTAssertEqual(gh.calls, [["--version"]])
        XCTAssertEqual(gh.gitLoginChecks, 0)
        XCTAssertEqual(SetupItem.allCases.map(report.state(of:)), [.passed, .failed, .waiting, .waiting])
    }

    func testOfflineGhStillCountsAsSignedIn() async {
        gh.offline = true

        let report = await gh.status.check(probingGitLogin: true)

        XCTAssertTrue(report.isReady)
        XCTAssertNotEqual(report.firstProblem, .ghLogin)
        XCTAssertFalse(gh.calls.contains(["auth", "status", "--hostname", "github.com"]))
    }

    func testBackgroundCheckLeavesGitsLoginToTheAccessCheck() async {
        gh.gitHasLogin = false

        let report = await gh.status.check(probingGitLogin: false)

        XCTAssertEqual(gh.gitLoginChecks, 0)
        XCTAssertNil(report.gitUsesLogin)
        XCTAssertTrue(report.isReady)
    }

    func testSignedOutGhAsksForGhAuthLogin() async {
        gh.signedIn = false

        let report = await gh.status.check(probingGitLogin: true)

        XCTAssertEqual(report.firstProblem, .ghLogin)
        XCTAssertEqual(report.firstProblem?.command, "gh auth login")
        XCTAssertEqual(gh.gitLoginChecks, 0)
        XCTAssertEqual(SetupItem.allCases.map(report.state(of:)), [.passed, .passed, .failed, .waiting])
    }

    func testGitWithoutAGitHubLoginAsksForSetupGit() async {
        gh.gitHasLogin = false

        let report = await gh.status.check(probingGitLogin: true)

        XCTAssertEqual(report.firstProblem, .gitLogin)
        XCTAssertEqual(report.firstProblem?.command, "gh auth setup-git")
        XCTAssertEqual(SetupItem.allCases.map(report.state(of:)), [.passed, .passed, .passed, .failed])
    }

    func testTokenIsGhsTrimmedOutput() async {
        let token = await gh.status.token()

        XCTAssertEqual(token, "gho_from_gh")
        XCTAssertEqual(gh.calls, [["auth", "token", "--hostname", "github.com"]])
    }

    func testNoTokenWhenGhIsSignedOutOrMissing() async {
        gh.signedIn = false
        let signedOut = await gh.status.token()
        XCTAssertNil(signedOut)

        gh.signedIn = true
        gh.token = "  \n"
        let blank = await gh.status.token()
        XCTAssertNil(blank)

        gh.installed = false
        let missing = await gh.status.token()
        XCTAssertNil(missing)
    }

    func testGhRunsWithoutPromptsOrUpdateNotices() {
        XCTAssertEqual(GhStatus.environment["GH_PROMPT_DISABLED"], "1")
        XCTAssertEqual(GhStatus.environment["GH_NO_UPDATE_NOTIFIER"], "1")
        XCTAssertEqual(GhStatus.environment["GIT_TERMINAL_PROMPT"], "0")
        XCTAssertTrue(GhStatus.environment["PATH"]?.split(separator: ":").contains("/opt/homebrew/bin") == true)
    }

    func testRejectedLoginTurnsIntoGhAuthLoginGuidance() {
        let rejected = SetupReport.ready.rejectingGitHubLogin()

        XCTAssertEqual(rejected.firstProblem, .ghLogin)
        XCTAssertEqual(SetupItem.allCases.map(rejected.state(of:)), [.passed, .passed, .failed, .waiting])
    }

    func testEachProblemSaysWhatToRun() {
        XCTAssertNil(SetupItem.git.command)
        XCTAssertEqual(SetupItem.gh.command, "brew install gh")
        XCTAssertEqual(SetupItem.ghLogin.command, "gh auth login")
        XCTAssertEqual(SetupItem.gitLogin.command, "gh auth setup-git")
    }

    func testPanelMessageSaysWhetherSyncingStopped() {
        XCTAssertEqual(SetupItem.ghLogin.panelMessage(syncStopped: false), "gh isn't signed in to GitHub, so new repos aren't cloned.")
        XCTAssertEqual(SetupItem.gitLogin.panelMessage(syncStopped: true), "git doesn't have a GitHub login, so nothing was pulled.")
    }

    // MARK: Panel guidance

    func testUnreachableGitHubIsShownInsteadOfASignInHint() throws {
        let guidance = try XCTUnwrap(AccessGuidance.make(
            folderMissing: false, access: .unreachable(detail: "Could not resolve host"),
            problem: .ghLogin, overHTTPS: true
        ))

        XCTAssertEqual(guidance.message, "Couldn't reach GitHub, so nothing was pulled. Check your connection, then sync again.")
        XCTAssertNil(guidance.command)
        XCTAssertFalse(guidance.offersSetup)
        XCTAssertTrue(guidance.syncStopped)
    }

    func testChecklistProblemSaysWhatToRun() throws {
        let guidance = try XCTUnwrap(AccessGuidance.make(folderMissing: false, access: .working, problem: .ghLogin, overHTTPS: true))

        XCTAssertEqual(guidance.message, "gh isn't signed in to GitHub, so new repos aren't cloned.")
        XCTAssertEqual(guidance.command, "gh auth login")
        XCTAssertTrue(guidance.offersSetup)
        XCTAssertFalse(guidance.syncStopped)
    }

    func testRefusedOverHTTPSWithAPassingChecklistOffersSetupGit() throws {
        let guidance = try XCTUnwrap(AccessGuidance.make(
            folderMissing: false, access: .refused(detail: "Authentication failed"), problem: nil, overHTTPS: true
        ))

        XCTAssertEqual(guidance.command, "gh auth setup-git")
        XCTAssertFalse(guidance.offersSetup)
        XCTAssertTrue(guidance.syncStopped)
    }

    func testRefusedOverSSHHasNoCommand() throws {
        let guidance = try XCTUnwrap(AccessGuidance.make(
            folderMissing: false, access: .refused(detail: "Permission denied (publickey)"), problem: nil, overHTTPS: false
        ))

        XCTAssertEqual(guidance.message, "GitHub access failed, so nothing was pulled.")
        XCTAssertNil(guidance.command)
    }

    func testNothingToSayWhenEverythingWorks() {
        XCTAssertNil(AccessGuidance.make(folderMissing: false, access: .working, problem: nil, overHTTPS: true))
        XCTAssertEqual(
            AccessGuidance.make(folderMissing: true, access: .working, problem: .ghLogin, overHTTPS: true)?.message,
            "Your repos folder is missing. Choose it again in Settings."
        )
    }

    func testCredentialOutputNeedsANonEmptyPassword() {
        XCTAssertTrue(GitCredential.containsPassword("protocol=https\nhost=github.com\nusername=erik\npassword=gho_abc\n"))
        XCTAssertFalse(GitCredential.containsPassword("protocol=https\nhost=github.com\nusername=\npassword=\n"))
        XCTAssertFalse(GitCredential.containsPassword(""))
    }
}
