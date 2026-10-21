import AppKit
import SwiftUI

// `RepoSync --sync-once <folder>` syncs once without the menu bar and prints each repo's result.
// `RepoSync --render-preview <dir> [state.json]` draws the panel, settings and onboarding steps to PNGs in light and dark.
enum Headless {
    @MainActor
    static func renderPreviewIfRequested() {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--render-preview"), args.indices.contains(flag + 1) else { return }
        let outDir = URL(fileURLWithPath: args[flag + 1])
        let model = AppModel(preview: true)
        model.showPreviewSetup(readySetup, login: "erikmaday")
        if args.indices.contains(flag + 2) {
            model.loadPreviewState(from: URL(fileURLWithPath: args[flag + 2]))
            model.loadPreviewHistory(sampleHistory())
        }
        RunLoop.main.run(until: Date().addingTimeInterval(4))

        var panes: [(String, Pane)] = [("main", .main), ("history", .history), ("settings", .settings)]
        if let notable = model.history.first(where: { !$0.pulled.isEmpty }) { panes.append(("run", .run(notable.id))) }

        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for (name, pane) in panes {
                model.pane = pane
                snapshot(MenuPanel().environmentObject(model), appearance: appearance,
                         to: outDir.appendingPathComponent("\(name)-\(suffix).png"))
            }
            model.pane = .main
            model.showPreviewProgress(done: 39, total: 78)
            snapshot(MenuPanel().environmentObject(model), appearance: appearance,
                     to: outDir.appendingPathComponent("syncing-\(suffix).png"))
            model.showPreviewProgress(done: 21, total: 74, cloning: true)
            snapshot(MenuPanel().environmentObject(model), appearance: appearance,
                     to: outDir.appendingPathComponent("cloning-\(suffix).png"))
            model.showPreviewProgress(done: 39, total: 78)
            snapshot(ReposView().environmentObject(model).frame(width: 820, height: 560), appearance: appearance,
                     to: outDir.appendingPathComponent("repos-\(suffix).png"))
            renderProblems(model: model, appearance: appearance, suffix: suffix, outDir: outDir)
            renderOnboarding(model: model, appearance: appearance, suffix: suffix, outDir: outDir)
        }
        exit(0)
    }

    @MainActor
    private static func renderProblems(model: AppModel, appearance: NSAppearance.Name, suffix: String, outDir: URL) {
        func render(_ name: String, _ pane: Pane = .main) {
            model.pane = pane
            snapshot(MenuPanel().environmentObject(model), appearance: appearance,
                     to: outDir.appendingPathComponent("\(name)-\(suffix).png"))
        }
        let access = model.access
        model.showPreviewIdle()
        model.showPreviewAccess(.refused(detail: "Authentication failed"))
        render("main-refused")
        render("settings-refused", .settings)
        model.showPreviewSetup(SetupReport(gitVersion: "2.54", gitInstalled: true, ghInstalled: true, ghSignedIn: true), login: nil)
        render("main-git-login-refused")
        model.showPreviewAccess(access)
        model.showPreviewSetup(SetupReport(gitVersion: "2.54", gitInstalled: true, ghInstalled: true), login: nil)
        render("main-gh-signed-out")
        render("settings-gh-signed-out", .settings)
        model.showPreviewAccess(.unreachable(detail: "Could not resolve host: github.com"))
        render("main-offline-gh-signed-out")
        model.showPreviewAccess(access)
        model.showPreviewSetup(SetupReport(gitVersion: "2.54", gitInstalled: true), login: nil)
        render("main-gh-missing")
        model.showPreviewSetup(readySetup, login: "erikmaday")
        model.showPreviewAccess(access, folderMissing: true)
        render("main-folder-missing")
        model.showPreviewAccess(access)
        let release = Release(tag: "v1.1.0", htmlURL: URL(string: "https://github.com/\(Updater.owner)/\(Updater.repo)/releases/tag/v1.1.0")!, zipAssetID: 1)
        model.showPreviewUpdate(AppModel.AvailableUpdate(version: Version("1.1.0")!, release: release), failed: true)
        render("main-update-failed")
        model.showPreviewUpdate(nil, failed: false)
        model.pane = .main
    }

    @MainActor
    private static func renderOnboarding(model: AppModel, appearance: NSAppearance.Name, suffix: String, outDir: URL) {
        let onboarding = OnboardingModel(
            settings: model, start: .welcome, checkSetup: { readySetup }, requestGitInstall: {}, makeClient: { nil }, sleep: { _ in }
        )
        onboarding.folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Code")
        onboarding.showRepos(org: "example-org", choices: sampleRepoChoices())
        let steps = OnboardingStep.allCases

        func render(_ name: String, _ step: OnboardingStep, setup: SetupReport? = readySetup, installingGit: Bool = false,
                    folder: FolderStatus = .new) {
            onboarding.loadPreview(step: step, setup: setup, installingGit: installingGit, folderStatus: folder,
                                   history: Array(steps.prefix(step.rawValue)))
            snapshot(OnboardingView().environmentObject(onboarding).environmentObject(model), appearance: appearance,
                     to: outDir.appendingPathComponent("onboarding-\(name)-\(suffix).png"))
        }

        render("1-welcome", .welcome)
        render("2-checklist", .checklist)
        render("2-checklist-checking", .checklist, setup: nil)
        render("2-checklist-git-missing", .checklist, setup: SetupReport())
        render("2-checklist-git-installing", .checklist, setup: SetupReport(), installingGit: true)
        render("2-checklist-gh-missing", .checklist, setup: SetupReport(gitVersion: "2.54", gitInstalled: true))
        render("2-checklist-gh-signed-out", .checklist, setup: SetupReport(gitVersion: "2.54", gitInstalled: true, ghInstalled: true))
        render("2-checklist-git-login", .checklist,
               setup: SetupReport(gitVersion: "2.54", gitInstalled: true, ghInstalled: true, ghSignedIn: true))
        render("3-folder", .folder)
        render("3-folder-existing", .folder, folder: .repos(37))
        render("4-repos", .repos)
        onboarding.showRepos(org: "example-labs", choices: sampleRepoChoices())
        onboarding.showRepos(org: "example-org", choices: sampleRepoChoices())
        render("4-repos-orgs", .repos)

        var activity = CloneActivity()
        activity.begin(total: 74)
        for name in sampleRepoNames.prefix(25) { activity.started(name) }
        for name in sampleRepoNames.prefix(21) { activity.finished(name, outcome: .cloned) }
        model.showPreviewCloneActivity(activity)
        model.showPreviewProgress(done: 21, total: 74, cloning: true)
        render("5-cloning", .cloning)
        model.showPreviewCloneProblem(AppModel.StopReason.accessFailed)
        render("5-cloning-stopped", .cloning)
        model.showPreviewCloneProblem(nil)
        render("6-done", .done)
    }

    private static let readySetup = SetupReport(gitVersion: "2.54", gitInstalled: true, ghInstalled: true, ghSignedIn: true, gitUsesLogin: true)

    private static let sampleRepoNames = [
        "admin-portal", "api-gateway", "billing-service", "booking-widget", "customer-web", "orders-ci",
        "orders-quotes", "orders-reservations", "orders-user", "data-warehouse", "driver-app",
        "driver-app-config", "email-templates", "fleet-tracker", "gpstracking", "infra-terraform", "invoice-exports",
        "marketplace", "notifications", "operator-portal", "payments", "pricing", "quote-engine", "reporting",
        "route-planner", "shuttle-mcp", "shuttle-mcp-tools", "shuttle-realtime", "support-tools", "trip-scheduler"
    ]

    private static func sampleRepoChoices() -> [RepoChoice] {
        let archived: Set<String> = ["api-legacy", "old-website", "php-admin", "quote-engine-v1"]
        let alreadyHere: Set<String> = ["orders-ci", "orders-quotes"]
        let generated = (1...44).map { String(format: "service-%02d", $0) }
        let names = sampleRepoNames + Array(archived) + generated
        let repos = names.enumerated().map { index, name in
            GitHubRepo(
                name: name, cloneURL: URL(string: "https://github.com/example-org/\(name).git")!,
                sizeKB: [98_000, 12_400, 41_000, 3_200, 26_000, 7_800][index % 6], archived: archived.contains(name),
                owner: "example-org"
            )
        }
        return OnboardingModel.choices(for: repos, present: alreadyHere, excluded: [], known: nil)
    }

    private static func sampleHistory() -> [SyncRun] {
        let now = Date()
        func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }
        let skipped = [SkippedRepo(name: "pricing", reason: "Uncommitted changes on main", behind: 3)]
        return [
            SyncRun(started: ago(0.2), duration: 8, trigger: .manual, repoCount: 78,
                    pulled: [
                        PulledRepo(name: "shuttle-mcp", count: 14, commits: [
                            Commit(sha: "4e1a9c2", subject: "Add trip lookup tool"),
                            Commit(sha: "b77d013", subject: "Handle missing driver phone numbers"),
                            Commit(sha: "09fc5e1", subject: "Bump MCP SDK")
                        ]),
                        PulledRepo(name: "orders-reservations", count: 1, commits: [
                            Commit(sha: "e90b1d7", subject: "Save changes before calling the billing service")
                        ])
                    ],
                    skipped: skipped,
                    cloned: ["shuttle-mcp-tools", "invoice-exports", "driver-app-config"]),
            SyncRun(started: ago(1), duration: 7, trigger: .schedule, repoCount: 78, skipped: skipped),
            SyncRun(started: ago(2), duration: 7, trigger: .schedule, repoCount: 78, skipped: skipped),
            SyncRun(started: ago(3), duration: 30, trigger: .schedule, repoCount: 78, stopped: "Couldn't reach GitHub"),
            SyncRun(started: ago(4), duration: 9, trigger: .schedule, repoCount: 78,
                    pulled: [PulledRepo(name: "gpstracking", count: 5, commits: [])]),
            SyncRun(started: ago(26), duration: 8, trigger: .schedule, repoCount: 78,
                    pulled: [PulledRepo(name: "pricing", count: 2, commits: [])]),
            SyncRun(started: ago(27), duration: 8, trigger: .schedule, repoCount: 78)
        ]
    }

    @MainActor
    private static func snapshot<V: View>(_ view: V, appearance: NSAppearance.Name, to url: URL) {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--sync-once") else { return }
        let folder = args.indices.contains(flag + 1)
            ? URL(fileURLWithPath: args[flag + 1])
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await syncOnce(folder: folder)
            done.signal()
        }
        done.wait()
        exit(0)
    }

    private static func syncOnce(folder: URL) async {
        let repos = await SyncEngine.discover(folder: folder, filter: .allGitHub, organizations: [])
        print("Found \(repos.count) GitHub repos in \(folder.path)")
        guard let first = repos.first else { return }

        let access = await SyncEngine.checkAccess(using: first)
        print("GitHub access: \(access)")
        guard access.isWorking else { return }

        let outcomes = await concurrentMap(repos, limit: 8) { repo in (repo, await SyncEngine.sync(repo)) }
        for (repo, result) in outcomes {
            let outcome = result.outcome
            let live = await SyncEngine.live(repo)
            let trees = live.worktrees.map { "\($0.branch)@\($0.folderName)" }.joined(separator: ", ")
            let pulledCommits = result.commits.map { "\($0.sha) \($0.subject)" }.joined(separator: "; ")
            print("\(repo.name): \(outcome)\(pulledCommits.isEmpty ? "" : " [\(pulledCommits)]") | on \(live.branch) (default \(live.defaultBranch))\(trees.isEmpty ? "" : " | worktrees: \(trees)")")
        }
    }
}
