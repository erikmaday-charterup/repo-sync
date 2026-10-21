import AppKit
import Foundation
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    private enum Key {
        static let folderPath = "folderPath"
        static let filter = "repoFilter"
        static let organizations = "organizations"
        static let intervalMinutes = "intervalMinutes"
        // Keeps its original name so existing installs keep their open at login choice.
        static let openAtLoginDefaulted = "launchedBefore"
        static let cloneOrgs = "cloneOrgs"
        static let exclusions = "exclusions"
        static let lastUpdateCheck = "lastUpdateCheck"
    }

    enum StopReason {
        static let folderMissing = "Your repos folder is missing"
        static let accessFailed = "GitHub access failed"
        static let unreachable = "Couldn't reach GitHub"
        static let listingFailed = "Couldn't list repos on GitHub"
        static let loginRejected = "GitHub rejected gh's login"
        static let gitMissing = "git isn't installed"
    }

    struct AvailableUpdate {
        let version: Version
        let release: Release
    }

    static let intervalChoices = [15, 30, 60, 120]

    @Published var folderPath: String? {
        didSet {
            defaults.set(folderPath, forKey: Key.folderPath)
            if folderPath != oldValue { forgetKnownRepos() }
            settingsChanged()
        }
    }
    @Published var filter: RepoFilter {
        didSet { defaults.set(filter.rawValue, forKey: Key.filter); settingsChanged() }
    }
    @Published var organizations: String {
        didSet { defaults.set(organizations, forKey: Key.organizations); settingsChanged() }
    }
    @Published var intervalMinutes: Int {
        didSet { defaults.set(intervalMinutes, forKey: Key.intervalMinutes) }
    }
    @Published var cloneOrgs: [String] {
        didSet { defaults.set(cloneOrgs, forKey: Key.cloneOrgs) }
    }
    @Published var exclusions: Set<String> {
        didSet { defaults.set(exclusions.sorted(), forKey: Key.exclusions); settingsChanged() }
    }
    @Published var openAtLogin: Bool = false

    @Published private(set) var lastSync: Date?
    @Published private(set) var isSyncing = false
    @Published private(set) var progress = (done: 0, total: 0)
    @Published private(set) var statuses: [RepoStatus] = []
    @Published private(set) var live: [RepoLive] = []
    @Published private(set) var repoCount = 0
    @Published private(set) var access: AccessState = .unknown
    @Published private(set) var accessChecked: Date?
    @Published private(set) var isCheckingAccess = false
    @Published private(set) var history: [SyncRun] = []
    @Published private(set) var isCloning = false
    @Published private(set) var cloneActivity = CloneActivity()
    // nil until git and gh have been checked once.
    @Published private(set) var setup: SetupReport?
    @Published private(set) var githubLogin: String?
    @Published private(set) var isCheckingSetup = false
    @Published private(set) var accessCheckedOverHTTPS = true
    @Published private(set) var knownRepos: Set<String>?
    @Published private(set) var pendingDeletions: [String] = []
    @Published private(set) var folderMissing = false
    // Why the latest sync couldn't look for new repos, for the onboarding cloning step.
    @Published private(set) var cloneProblem: String?
    @Published private(set) var availableUpdate: AvailableUpdate?
    @Published private(set) var isInstallingUpdate = false
    @Published private(set) var updateFailed = false
    @Published var pane: Pane = .main

    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var discoveryTask: Task<Void, Never>?
    private var repos: [RepoRef] = []
    private var followUpSync = FollowUpSync()
    private var isCheckingForUpdate = false
    private let ghStatus: GhStatus

    private static let supportFolderName = "RepoSync"
    private static let previewFolderName = "RepoSyncPreview"
    private static let historyLimit = 500
    private static let previewGhStatus = GhStatus(
        runGh: { _ in CommandResult(status: -1, stdout: "", stderr: "", timedOut: false) },
        gitInstallation: { nil },
        gitHasLogin: { false }
    )

    private let stateURL: URL
    private let historyURL: URL
    let logURL: URL

    // A preview keeps its state, history and log in a scratch folder and never syncs, checks for updates or registers at login.
    init(preview: Bool = false) {
        let fileManager = FileManager.default
        let support: URL
        ghStatus = preview ? Self.previewGhStatus : .live
        if preview {
            support = fileManager.temporaryDirectory.appendingPathComponent(Self.previewFolderName, isDirectory: true)
            try? fileManager.removeItem(at: support)
            logURL = support.appendingPathComponent("RepoSync.log")
        } else {
            support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(Self.supportFolderName, isDirectory: true)
            logURL = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/RepoSync.log")
        }
        try? fileManager.createDirectory(at: support, withIntermediateDirectories: true)
        if !preview, let bundleIdentifier = Bundle.main.bundleIdentifier {
            SettingsMigration.run(defaults: defaults, domain: bundleIdentifier)
        }
        stateURL = support.appendingPathComponent("state.json")
        historyURL = support.appendingPathComponent("history.json")

        folderPath = defaults.string(forKey: Key.folderPath)
        filter = RepoFilter(rawValue: defaults.string(forKey: Key.filter) ?? "") ?? .allGitHub
        organizations = defaults.string(forKey: Key.organizations) ?? ""
        let storedInterval = defaults.integer(forKey: Key.intervalMinutes)
        intervalMinutes = Self.intervalChoices.contains(storedInterval) ? storedInterval : 60
        cloneOrgs = defaults.stringArray(forKey: Key.cloneOrgs) ?? []
        exclusions = Set(defaults.stringArray(forKey: Key.exclusions) ?? [])

        loadState()
        loadHistory()

        openAtLogin = SMAppService.mainApp.status == .enabled
        if preview {
            Task { await refreshRepos() }
            return
        }

        let alreadyDefaulted = defaults.bool(forKey: Key.openAtLoginDefaulted)
        if AppLocation.shouldDefaultOpenAtLogin(
            alreadyDefaulted: alreadyDefaulted, bundleURL: Bundle.main.bundleURL, home: fileManager.homeDirectoryForCurrentUser
        ) {
            defaults.set(true, forKey: Key.openAtLoginDefaulted)
            setOpenAtLogin(true)
        }
        start()
    }

    private func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncIfDue()
                self?.checkForUpdateIfDue()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.syncIfDue() }
        }

        Task {
            await refreshRepos()
            syncIfDue()
        }
        Task { await checkForUpdate() }
    }

    // MARK: Derived

    var folderURL: URL? { folderPath.map { URL(fileURLWithPath: $0) } }

    var organizationList: [String] {
        OrganizationList.parse(organizations)
    }

    var nextSync: Date? {
        guard folderPath != nil else { return nil }
        guard let lastSync else { return Date() }
        return lastSync.addingTimeInterval(TimeInterval(intervalMinutes * 60))
    }

    var needsAttention: [RepoStatus] {
        statuses.filter { $0.outcome.needsAttention }
    }

    var hasPendingDeletions: Bool { !pendingDeletions.isEmpty }

    var setupProblem: SetupItem? { setup?.firstProblem }

    var offDefault: [RepoLive] {
        live.filter(\.isOffDefault)
    }

    var hasFailure: Bool {
        if folderMissing || setupProblem == .git { return true }
        if case .refused = access { return true }
        if case .unreachable = access { return true }
        return statuses.contains { if case .failed = $0.outcome { return true } else { return false } }
    }

    func status(for name: String) -> RepoStatus? {
        statuses.first { $0.name == name }
    }

    // MARK: Actions

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder that holds your repos"
        if let folderURL { panel.directoryURL = folderURL }
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            folderPath = url.path
        }
    }

    func setOpenAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log("Couldn't change open at login: \(error.localizedDescription)")
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    func openLog() {
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        NSWorkspace.shared.open(logURL)
    }

    func openInTerminal(_ path: String) {
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: path)], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration()
        )
    }

    func showInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func refreshLive() {
        Task { await loadLive() }
    }

    func checkAccessNow() {
        guard !isCheckingAccess else { return }
        isCheckingAccess = true
        Task {
            switch await makeCloneStep().preflight() {
            case .checked(let state):
                access = state
                accessChecked = Date()
            case .folderMissing:
                folderMissing = true
            case .nothingToCheck:
                break
            }
            isCheckingAccess = false
            saveState()
        }
    }

    func excludeDeleted(_ name: String) {
        exclude(name)
    }

    func recloneDeleted(_ name: String) {
        pendingDeletions.removeRepo(name)
        knownRepos?.removeRepo(name)
        saveState()
        requestSync()
    }

    func exclude(_ name: String) {
        pendingDeletions.removeRepo(name)
        if !exclusions.containsRepo(name) { exclusions.insert(name) }
        saveState()
    }

    func unexclude(_ name: String) {
        pendingDeletions.removeRepo(name)
        exclusions.removeRepo(name)
        knownRepos?.removeRepo(name)
        saveState()
    }

    // MARK: git and gh

    @discardableResult
    func checkSetup(probingGitLogin: Bool = false) async -> SetupReport {
        isCheckingSetup = true
        defer { isCheckingSetup = false }
        let report = await ghStatus.check(probingGitLogin: probingGitLogin)
        setup = report
        if report.isReady {
            if githubLogin == nil { await loadGitHubLogin() }
        } else {
            githubLogin = nil
        }
        // Reading the account can find GitHub rejecting gh's token, which the report alone doesn't show.
        return setup ?? report
    }

    func checkSetupAgain() {
        guard !isCheckingSetup else { return }
        githubLogin = nil
        Task { await checkSetup(probingGitLogin: true) }
    }

    func githubClient() async -> GitHubClient? {
        await ghStatus.token().map { GitHubClient(token: $0) }
    }

    func githubRejectedLogin() {
        setup = (setup ?? .ready).rejectingGitHubLogin()
        githubLogin = nil
    }

    private func loadGitHubLogin() async {
        guard let client = await githubClient() else { return }
        do {
            githubLogin = try await client.user().login
        } catch GitHubError.unauthorized {
            log("GitHub rejected gh's login when reading the account")
            githubRejectedLogin()
        } catch {
            log("Couldn't read the GitHub account gh is signed in to: \(error)")
        }
    }

    func checkForUpdateIfDue() {
        guard Updater.isCheckDue(lastCheck: defaults.object(forKey: Key.lastUpdateCheck) as? Date, now: Date()) else { return }
        Task { await checkForUpdate() }
    }

    private func checkForUpdate() async {
        guard !isCheckingForUpdate, !isInstallingUpdate, setup?.isReady == true else { return }
        isCheckingForUpdate = true
        defer { isCheckingForUpdate = false }
        guard let updater = await makeUpdater() else { return }
        defaults.set(Date(), forKey: Key.lastUpdateCheck)
        do {
            let result = try await updater.check()
            switch result {
            case .upToDate:
                availableUpdate = nil
            case .available(let version, let release):
                if availableUpdate?.version != version { updateFailed = false }
                availableUpdate = AvailableUpdate(version: version, release: release)
            }
        } catch GitHubError.unauthorized {
            log("Update check failed: GitHub rejected gh's login")
            githubRejectedLogin()
        } catch {
            log("Update check failed: \(error)")
        }
    }

    func installUpdate() {
        guard let update = availableUpdate, !isInstallingUpdate else { return }
        isInstallingUpdate = true
        updateFailed = false
        Task {
            guard let updater = await makeUpdater() else {
                isInstallingUpdate = false
                return
            }
            do {
                try await updater.install(update.release, appURL: Bundle.main.bundleURL)
            } catch UpdateError.notWritable(let releasePage) {
                NSWorkspace.shared.open(releasePage)
                isInstallingUpdate = false
            } catch GitHubError.unauthorized {
                log("Update to \(update.version) failed: GitHub rejected gh's login")
                githubRejectedLogin()
                isInstallingUpdate = false
            } catch {
                log("Update to \(update.version) failed: \(error)")
                updateFailed = true
                isInstallingUpdate = false
                NSWorkspace.shared.open(update.release.htmlURL)
            }
        }
    }

    private func makeUpdater() async -> Updater? {
        guard let current = Updater.currentVersion(), let client = await githubClient() else { return nil }
        return Updater(current: current, client: client)
    }

    private func forgetKnownRepos() {
        knownRepos = nil
        pendingDeletions = []
        saveState()
    }

    // MARK: Sync

    func syncIfDue() {
        guard !isSyncing, let nextSync, nextSync <= Date() else { return }
        syncNow(trigger: .schedule)
    }

    // Starts a sync now, or right after the one in flight so it sees settings changed meanwhile.
    func requestSync() {
        if followUpSync.request(whileSyncing: isSyncing) { syncNow() }
    }

    func syncNow(trigger: SyncTrigger = .manual) {
        guard !isSyncing, folderURL != nil else { return }
        isSyncing = true
        progress = (0, 0)
        Task {
            await runSync(trigger: trigger)
            isSyncing = false
            if followUpSync.finishSync() { syncNow() }
        }
    }

    private func runSync(trigger: SyncTrigger) async {
        await refreshRepos()
        let started = Date()
        cloneProblem = nil
        cloneActivity = CloneActivity()
        let report = await checkSetup()
        guard report.gitInstalled else {
            log("Sync stopped: git isn't installed")
            stopRun(started: started, trigger: trigger, reason: StopReason.gitMissing)
            return
        }
        let step = makeCloneStep()

        switch await step.preflight() {
        case .folderMissing:
            folderMissing = true
            log("Sync stopped: the repos folder \(folderPath ?? "") is missing")
            stopRun(started: started, trigger: trigger, reason: StopReason.folderMissing)
            return
        case .checked(let state):
            access = state
            accessChecked = Date()
            guard state.isWorking else {
                log("Sync stopped before pulling: \(accessDescription)")
                let reason: String
                if case .unreachable = state { reason = StopReason.unreachable } else { reason = StopReason.accessFailed }
                stopRun(started: started, trigger: trigger, reason: reason)
                return
            }
        case .nothingToCheck:
            break
        }

        let hadNothingToSync = repos.allSatisfy(\.excluded)
        let cloneRun = await step.cloneNewRepos(onStart: {
            isCloning = true
            progress = (0, 0)
        }, progress: { [weak self] done, total in
            self?.progress = (done, total)
            if done == 0 { self?.cloneActivity.begin(total: total) }
        })
        isCloning = false
        if let cloneRun {
            apply(cloneRun)
        } else if !cloneOrgs.isEmpty, let problem = setupProblem {
            cloneProblem = problem.failedTitle
        }
        let cloned = cloneRun?.result.cloned ?? []
        let cloneFailures = cloneRun?.result.failed ?? []
        if !cloned.isEmpty {
            await refreshRepos()
            if hadNothingToSync {
                access = .working
                accessChecked = Date()
            }
        }

        let targets = repos.filter { !$0.excluded }
        guard !targets.isEmpty else {
            lastSync = started
            statuses = []
            if !cloned.isEmpty || !cloneFailures.isEmpty {
                record(SyncRun(
                    started: started, duration: Date().timeIntervalSince(started), trigger: trigger,
                    repoCount: 0, failed: cloneFailures, cloned: cloned
                ))
            }
            saveState()
            return
        }

        progress = (0, targets.count)
        let previous = Dictionary(uniqueKeysWithValues: statuses.map { ($0.name, $0) })
        var results: [RepoStatus] = []
        var run = SyncRun(started: started, duration: 0, trigger: trigger, repoCount: targets.count)

        await withTaskGroup(of: (RepoRef, SyncResult).self) { group in
            var pending = targets.makeIterator()
            for _ in 0..<min(8, targets.count) {
                if let repo = pending.next() {
                    group.addTask { (repo, await SyncEngine.sync(repo)) }
                }
            }
            while let (repo, result) = await group.next() {
                let outcome = result.outcome
                let pulledNow: Bool
                switch outcome {
                case .current:
                    pulledNow = true
                case .pulled(let count):
                    pulledNow = true
                    run.pulled.append(PulledRepo(name: repo.name, count: count, commits: result.commits))
                case .skipped(let reason, let behind):
                    pulledNow = false
                    run.skipped.append(SkippedRepo(name: repo.name, reason: reason, behind: behind))
                case .failed(let reason):
                    pulledNow = false
                    run.failed.append(FailedRepo(name: repo.name, reason: reason))
                }
                results.append(RepoStatus(
                    name: repo.name,
                    path: repo.url.path,
                    outcome: outcome,
                    lastPulled: pulledNow ? Date() : previous[repo.name]?.lastPulled
                ))
                progress.done += 1
                if let next = pending.next() {
                    group.addTask { (next, await SyncEngine.sync(next)) }
                }
            }
        }

        statuses = results.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        lastSync = started
        record(SyncRun(
            started: started,
            duration: Date().timeIntervalSince(started),
            trigger: trigger,
            repoCount: targets.count,
            pulled: run.pulled.sorted { $0.name < $1.name },
            skipped: run.skipped.sorted { $0.name < $1.name },
            failed: (run.failed + cloneFailures).sorted { $0.name < $1.name },
            cloned: cloned
        ))
        saveState()
        logSummary(duration: Date().timeIntervalSince(started))
        await loadLive()
    }

    private func stopRun(started: Date, trigger: SyncTrigger, reason: String) {
        lastSync = started
        cloneProblem = reason
        var run = SyncRun(
            started: started, duration: Date().timeIntervalSince(started), trigger: trigger,
            repoCount: repos.filter { !$0.excluded }.count
        )
        run.stopped = reason
        record(run)
        saveState()
    }

    private func apply(_ cloneRun: CloneRun) {
        if cloneRun.result.tokenRevoked {
            cloneProblem = StopReason.loginRejected
        } else if cloneRun.result.listingFailed {
            cloneProblem = StopReason.listingFailed
        }
        guard let bookkeeping = cloneRun.bookkeeping else { return }
        knownRepos = bookkeeping.knownRepos
        pendingDeletions = bookkeeping.pendingDeletions
    }

    private func makeCloneStep() -> CloneStep {
        CloneStep(
            settings: { [unowned self] in
                CloneStepSettings(
                    folder: folderURL, cloneOrgs: cloneOrgs, known: knownRepos, exclusions: exclusions, pending: pendingDeletions
                )
            },
            folderExists: CloneStep.directoryExists,
            folderEntries: Self.folderEntries,
            checkAccess: { [unowned self] in
                guard let repo = repos.first(where: { !$0.excluded }) else { return nil }
                accessCheckedOverHTTPS = repo.usesHTTPS
                return await SyncEngine.checkAccess(using: repo)
            },
            readToken: { [unowned self] in await ghStatus.token() },
            loginRejected: { [unowned self] in githubRejectedLogin() },
            makeCoordinator: { [unowned self] token, folder in
                let client = GitHubClient(token: token)
                return CloneCoordinator(
                    listRepos: { try await client.repos(org: $0) },
                    clone: { [weak self] repo in
                        self?.cloneStarted(repo.name)
                        let outcome = await Cloner.clone(repo, into: folder)
                        self?.cloneFinished(repo.name, outcome: outcome)
                        return outcome
                    }
                )
            },
            log: { [unowned self] in log($0) }
        )
    }

    private func cloneStarted(_ name: String) {
        cloneActivity.started(name)
    }

    private func cloneFinished(_ name: String, outcome: CloneOutcome) {
        cloneActivity.finished(name, outcome: outcome)
    }

    nonisolated static func folderEntries(in folder: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return Set(names.filter { !Cloner.isInProgressClone($0) })
    }

    // MARK: Discovery

    private func settingsChanged() {
        discoveryTask?.cancel()
        discoveryTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await refreshRepos()
        }
    }

    private func refreshRepos() async {
        guard let folderURL else {
            repos = []
            repoCount = 0
            live = []
            folderMissing = false
            return
        }
        folderMissing = !CloneStep.directoryExists(folderURL)
        repos = await SyncEngine.discover(folder: folderURL, filter: filter, organizations: organizationList, excluded: exclusions)
        repoCount = repos.count
        let names = Set(repos.filter { !$0.excluded }.map(\.name))
        statuses.removeAll { !names.contains($0.name) }
        await loadLive()
    }

    private func loadLive() async {
        let snapshot = repos
        let results = await concurrentMap(snapshot, limit: 12) { await SyncEngine.live($0) }
        live = results
    }

    // MARK: Persistence and logging

    var accessDescription: String {
        switch access {
        case .unknown: return "Not checked yet"
        case .working: return "Working"
        case .refused(let detail): return "GitHub refused access (\(detail))"
        case .unreachable(let detail): return "Couldn't reach GitHub (\(detail))"
        }
    }

    func run(id: UUID) -> SyncRun? {
        history.first { $0.id == id }
    }

    private func record(_ run: SyncRun) {
        history.insert(run, at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
        if let data = try? JSONEncoder().encode(history) {
            try? data.write(to: historyURL, options: .atomic)
        }
    }

    private func loadHistory() {
        guard let data = try? Data(contentsOf: historyURL),
              let runs = try? JSONDecoder().decode([SyncRun].self, from: data) else { return }
        history = runs
    }

    func showPreviewProgress(done: Int, total: Int, cloning: Bool = false) {
        isSyncing = true
        isCloning = cloning
        progress = (done, total)
    }

    func showPreviewIdle() {
        isSyncing = false
        isCloning = false
    }

    func showPreviewAccess(_ state: AccessState, folderMissing: Bool = false) {
        access = state
        self.folderMissing = folderMissing
    }

    func showPreviewUpdate(_ update: AvailableUpdate?, failed: Bool) {
        availableUpdate = update
        updateFailed = failed
    }

    func showPreviewSetup(_ report: SetupReport?, login: String?) {
        setup = report
        githubLogin = login
    }

    func showPreviewCloneProblem(_ problem: String?) {
        showPreviewIdle()
        cloneActivity = CloneActivity()
        cloneProblem = problem
    }

    func showPreviewCloneActivity(_ activity: CloneActivity) {
        cloneActivity = activity
    }

    func loadPreviewHistory(_ runs: [SyncRun]) {
        history = runs
    }

    func loadPreviewState(from url: URL) {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else { return }
        statuses = state.statuses
        access = state.access
        pendingDeletions = state.pendingDeletions
    }

    private func loadState() {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else { return }
        lastSync = state.lastSync
        statuses = state.statuses
        access = state.access
        accessChecked = state.accessChecked
        knownRepos = state.knownRepos
        pendingDeletions = state.pendingDeletions
    }

    private func saveState() {
        let state = PersistedState(
            lastSync: lastSync, statuses: statuses, access: access, accessChecked: accessChecked,
            knownRepos: knownRepos, pendingDeletions: pendingDeletions
        )
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }

    private func logSummary(duration: TimeInterval) {
        let pulled = statuses.filter { if case .pulled = $0.outcome { return true } else { return false } }
        var lines = ["Synced \(statuses.count) repos in \(Int(duration))s: \(pulled.count) pulled, \(needsAttention.count) need attention"]
        for status in pulled {
            if case .pulled(let commits) = status.outcome { lines.append("  pulled \(status.name) (\(commits) commits)") }
        }
        for status in needsAttention {
            switch status.outcome {
            case .skipped(let reason, let behind): lines.append("  skipped \(status.name): \(reason), \(behind) behind")
            case .failed(let reason): lines.append("  failed \(status.name): \(reason)")
            default: break
            }
        }
        lines.forEach(log)
    }

    func log(_ message: String) {
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])
        let line = "\(stamp) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: logURL)
        }
    }
}
