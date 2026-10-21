import Foundation

enum GitCredential {
    private static let githubRequest = "protocol=https\nhost=github.com\n\n"
    private static let passwordField = "password="

    // Prompts are disabled in Git.environment, so this only reports a login git already has, such as gh's helper or a saved one.
    static func hasStoredLogin() async -> Bool {
        let result = await Git.run(["credential", "fill"], in: FileManager.default.temporaryDirectory, timeout: 15, input: githubRequest)
        return result.ok && containsPassword(result.stdout)
    }

    // GIT_ASKPASS=/usr/bin/true answers prompts with an empty string, so an empty password means nothing is stored.
    static func containsPassword(_ output: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains { $0.hasPrefix(passwordField) && $0.count > passwordField.count }
    }
}

enum SetupItem: Int, CaseIterable, Identifiable {
    case git, gh, ghLogin, gitLogin

    var id: Int { rawValue }

    var command: String? {
        switch self {
        case .git: return nil
        case .gh: return "brew install gh"
        case .ghLogin: return "gh auth login"
        case .gitLogin: return "gh auth setup-git"
        }
    }

    var waitingTitle: String {
        switch self {
        case .git: return "git installed"
        case .gh: return "gh installed"
        case .ghLogin: return "gh signed in to GitHub"
        case .gitLogin: return "git using that login"
        }
    }

    var passedTitle: String {
        switch self {
        case .git: return "git is installed"
        case .gh: return "gh is installed"
        case .ghLogin: return "gh is signed in to GitHub"
        case .gitLogin: return "git has a GitHub login"
        }
    }

    var failedTitle: String {
        switch self {
        case .git: return "git isn't installed"
        case .gh: return "gh isn't installed"
        case .ghLogin: return "gh isn't signed in to GitHub"
        case .gitLogin: return "git doesn't have a GitHub login"
        }
    }

    var failedDetail: String {
        switch self {
        case .git: return "macOS can install it for you with Apple's command line tools."
        case .gh: return "Install GitHub's gh tool with Homebrew, or download it from its site."
        case .ghLogin: return "Run this in Terminal and follow the prompts."
        case .gitLogin: return "Run this in Terminal so git uses gh's login."
        }
    }

    func panelMessage(syncStopped: Bool) -> String {
        "\(failedTitle), so \(syncStopped ? "nothing was pulled" : "new repos aren't cloned")."
    }
}

enum SetupItemState: Equatable {
    case passed, failed, waiting
}

struct SetupReport: Equatable {
    var gitVersion: String?
    var gitInstalled = false
    var ghInstalled = false
    var ghSignedIn = false
    // nil when only git's access check was run, which background syncs rely on instead.
    var gitUsesLogin: Bool? = false

    static let ready = SetupReport(gitInstalled: true, ghInstalled: true, ghSignedIn: true, gitUsesLogin: true)

    var isReady: Bool { firstProblem == nil }

    var firstProblem: SetupItem? {
        SetupItem.allCases.first { !passed($0) }
    }

    func state(of item: SetupItem) -> SetupItemState {
        if let problem = firstProblem, problem.rawValue < item.rawValue { return .waiting }
        return passed(item) ? .passed : .failed
    }

    // GitHub answered 401 to gh's token, so gh's login is no longer good even if gh still has it saved.
    func rejectingGitHubLogin() -> SetupReport {
        var report = self
        report.ghSignedIn = false
        return report
    }

    private func passed(_ item: SetupItem) -> Bool {
        switch item {
        case .git: return gitInstalled
        case .gh: return ghInstalled
        case .ghLogin: return ghSignedIn
        case .gitLogin: return gitUsesLogin != false
        }
    }
}

// Answers whether git and gh are ready, and borrows gh's token, without ever prompting or changing their setup.
struct GhStatus {
    typealias Runner = (_ arguments: [String]) async -> CommandResult

    private static let host = "github.com"
    private static let timeout: TimeInterval = 20
    private static let env = URL(fileURLWithPath: "/usr/bin/env")
    private static let executableName = "gh"

    static let environment: [String: String] = Git.environment.merging(
        ["GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1"]
    ) { _, override in override }

    static let live = GhStatus(runGh: runInstalledGh, gitInstallation: GitInstall.installation, gitHasLogin: GitCredential.hasStoredLogin)

    let runGh: Runner
    let gitInstallation: () async -> GitInstallation?
    let gitHasLogin: () async -> Bool

    // Each check needs the one before it; asking git for a login without git installed pops the install dialog.
    // gh counts as signed in from its saved token alone, so offline never looks signed out; GitHub's 401 catches a revoked one.
    // git's login is probed only in the foreground, since a keychain helper may prompt.
    func check(probingGitLogin: Bool) async -> SetupReport {
        var report = SetupReport()
        guard let git = await gitInstallation() else { return report }
        report.gitInstalled = true
        report.gitVersion = git.version
        guard await runGh(["--version"]).ok else { return report }
        report.ghInstalled = true
        guard await token() != nil else { return report }
        report.ghSignedIn = true
        report.gitUsesLogin = probingGitLogin ? await gitHasLogin() : nil
        return report
    }

    func token() async -> String? {
        let result = await runGh(["auth", "token", "--hostname", Self.host])
        guard result.ok, !result.trimmed.isEmpty else { return nil }
        return result.trimmed
    }

    private static func runInstalledGh(_ arguments: [String]) async -> CommandResult {
        await Subprocess.run(env, [executableName] + arguments, environment: environment, timeout: timeout)
    }
}

// What the panel says above the repo list when something keeps Repo Sync from syncing or cloning.
struct AccessGuidance: Equatable {
    static let folderMissing = "Your repos folder is missing. Choose it again in Settings."
    static let unreachable = "Couldn't reach GitHub, so nothing was pulled. Check your connection, then sync again."
    static let refused = "GitHub access failed, so nothing was pulled."
    static let refusedOverHTTPS = "GitHub refused git's login, so nothing was pulled. This makes git use gh's login:"

    let message: String
    let command: String?
    let offersSetup: Bool
    let syncStopped: Bool

    static func make(folderMissing: Bool, access: AccessState, problem: SetupItem?, overHTTPS: Bool) -> AccessGuidance? {
        if folderMissing { return AccessGuidance(message: Self.folderMissing, command: nil, offersSetup: false, syncStopped: true) }
        if problem == .git {
            return AccessGuidance(message: SetupItem.git.panelMessage(syncStopped: true), command: nil, offersSetup: true, syncStopped: true)
        }
        switch access {
        case .unreachable:
            return AccessGuidance(message: unreachable, command: nil, offersSetup: false, syncStopped: true)
        case .refused:
            if let problem {
                return AccessGuidance(message: problem.panelMessage(syncStopped: true), command: problem.command, offersSetup: true, syncStopped: true)
            }
            // A login git saved earlier, for example in the keychain, can outlive the GitHub token behind it.
            return overHTTPS
                ? AccessGuidance(message: refusedOverHTTPS, command: SetupItem.gitLogin.command, offersSetup: false, syncStopped: true)
                : AccessGuidance(message: refused, command: nil, offersSetup: false, syncStopped: true)
        case .working, .unknown:
            guard let problem else { return nil }
            return AccessGuidance(message: problem.panelMessage(syncStopped: false), command: problem.command, offersSetup: true, syncStopped: false)
        }
    }
}
