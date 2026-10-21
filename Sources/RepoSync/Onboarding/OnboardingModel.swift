import Foundation

enum OnboardingStep: Int, CaseIterable {
    case welcome, checklist, folder, repos, cloning, done
}

struct RepoChoice: Identifiable {
    let repo: GitHubRepo
    var selected: Bool
    let alreadyHere: Bool

    var id: String { repo.name }
    // The clone planner never clones archived repos, so only ones already in the folder can be ticked.
    var isSelectable: Bool { alreadyHere || !repo.archived }
}

@MainActor
protocol OnboardingSettings: AnyObject {
    var folderPath: String? { get set }
    var filter: RepoFilter { get set }
    var organizations: String { get set }
    var cloneOrgs: [String] { get set }
    var exclusions: Set<String> { get }
    var knownRepos: Set<String>? { get }
    var setup: SetupReport? { get }
    func exclude(_ name: String)
    func unexclude(_ name: String)
    func requestSync()
}

extension AppModel: OnboardingSettings {}

extension OnboardingSettings {
    // Repos someone chose to clone should also sync, so a sync filter limited to some organizations grows to include the org.
    func addCloneOrg(_ org: String) {
        if !cloneOrgs.contains(org) { cloneOrgs.append(org) }
        if filter == .organizations { organizations = OrganizationList.adding(org, to: organizations) }
    }
}

enum OrganizationList {
    private static let separator: Character = ","
    private static let joiner = ", "

    static func parse(_ text: String) -> [String] {
        text.split(separator: separator).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // GitHub org names are case-insensitive, so "Org" already covers "org".
    static func adding(_ org: String, to text: String) -> String {
        let orgs = parse(text)
        guard !orgs.contains(where: { $0.caseInsensitiveCompare(org) == .orderedSame }) else { return text }
        return (orgs + [org]).joined(separator: joiner)
    }
}

enum FolderStatus: Equatable, CustomStringConvertible {
    case new
    case empty
    case repos(Int)

    static func of(_ folder: URL) -> FolderStatus {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { return .new }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let repos = names.filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).appendingPathComponent(".git").path) }
        return repos.isEmpty ? .empty : .repos(repos.count)
    }

    var description: String {
        switch self {
        case .new: return "New folder. Nothing cloned here yet."
        case .empty: return "Nothing cloned here yet."
        case .repos(1): return "Found 1 repo already here."
        case .repos(let count): return "Found \(count) repos already here."
        }
    }
}

enum ReposLoadState: Equatable {
    case loading
    case loaded
    case noOrganizations
    case failed(String)
}

@MainActor
final class OnboardingModel: ObservableObject {
    private enum Message {
        static let unreachable = "Couldn't load repos from GitHub. Check your connection and try again."
    }

    static let defaultFolderName = "Code"
    static let checklistPollSeconds = 3

    @Published private(set) var step: OnboardingStep
    @Published var folder: URL { didSet { folderStatus = FolderStatus.of(folder); folderError = nil } }
    @Published private(set) var folderStatus: FolderStatus
    @Published private(set) var folderError: String?
    @Published private(set) var orgs: [String] = []
    @Published private(set) var selectedOrg: String?
    @Published var repoChoices: [RepoChoice] = [] {
        didSet {
            for index in repoChoices.indices where repoChoices[index].selected && !repoChoices[index].isSelectable {
                repoChoices[index].selected = false
            }
        }
    }
    @Published private(set) var reposState: ReposLoadState = .loading
    // nil until the first check finishes.
    @Published private(set) var setup: SetupReport?
    @Published private(set) var isInstallingGit = false

    let firstStep: OnboardingStep
    private let settings: OnboardingSettings
    private let checkSetup: () async -> SetupReport
    private let requestGitInstall: () -> Void
    private let makeClient: () async -> GitHubClient?
    private let sleep: (Int) async -> Void
    private let isNewInstall: Bool
    private var history: [OnboardingStep] = []
    private var checklistTask: Task<Void, Never>?
    private var reposTask: Task<Void, Never>?

    init(
        settings: OnboardingSettings,
        start: OnboardingStep,
        checkSetup: @escaping () async -> SetupReport,
        requestGitInstall: @escaping () -> Void,
        makeClient: @escaping () async -> GitHubClient?,
        sleep: @escaping (Int) async -> Void,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.settings = settings
        self.checkSetup = checkSetup
        self.requestGitInstall = requestGitInstall
        self.makeClient = makeClient
        self.sleep = sleep
        step = start
        firstStep = start
        isNewInstall = settings.folderPath == nil
        let initialFolder = settings.folderPath.map { URL(fileURLWithPath: $0) }
            ?? homeDirectory.appendingPathComponent(Self.defaultFolderName, isDirectory: true)
        folder = initialFolder
        folderStatus = FolderStatus.of(initialFolder)
        setup = settings.setup
    }

    static func live(settings: AppModel, start: OnboardingStep) -> OnboardingModel {
        OnboardingModel(
            settings: settings,
            start: start,
            checkSetup: { await settings.checkSetup(probingGitLogin: true) },
            requestGitInstall: GitInstall.requestInstall,
            makeClient: { await settings.githubClient() },
            sleep: { try? await Task.sleep(nanoseconds: UInt64($0) * 1_000_000_000) }
        )
    }

    // nil means onboarding shouldn't open on launch.
    nonisolated static func initialStep(folderConfigured: Bool, setupReady: Bool) -> OnboardingStep? {
        if !folderConfigured { return .welcome }
        return setupReady ? nil : .checklist
    }

    nonisolated static func resolvedStart(_ requested: OnboardingStep, setupReady: Bool, folderConfigured: Bool) -> OnboardingStep {
        guard requested == .repos else { return requested }
        if !setupReady { return .checklist }
        return folderConfigured ? .repos : .folder
    }

    nonisolated static func choices(for repos: [GitHubRepo], present: Set<String>, excluded: Set<String>, known: Set<String>?) -> [RepoChoice] {
        repos
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { repo in
                let alreadyHere = present.containsRepo(repo.name)
                let removedBefore = !alreadyHere && known?.containsRepo(repo.name) == true
                let selected = !excluded.containsRepo(repo.name) && (alreadyHere || (!repo.archived && !removedBefore))
                return RepoChoice(repo: repo, selected: selected, alreadyHere: alreadyHere)
            }
    }

    // MARK: Derived

    var isSetupReady: Bool { setup?.isReady == true }

    var canGoBack: Bool { !history.isEmpty && step != .cloning }

    var selectedSize: Int { repoChoices.filter(\.selected).reduce(0) { $0 + $1.repo.sizeKB } }
    var selectedCount: Int { repoChoices.filter(\.selected).count }
    var cloneCount: Int { repoChoices.filter { $0.selected && $0.isSelectable && !$0.alreadyHere }.count }

    // MARK: Navigation

    func begin() {
        enter(step)
    }

    func next() {
        guard step != .checklist || isSetupReady, let following = OnboardingStep(rawValue: step.rawValue + 1) else { return }
        history.append(step)
        move(to: following)
    }

    func back() {
        guard canGoBack, let previous = history.popLast() else { return }
        move(to: previous)
    }

    func close() {
        checklistTask?.cancel()
        reposTask?.cancel()
    }

    private func move(to newStep: OnboardingStep) {
        leave(step)
        step = newStep
        enter(newStep)
    }

    private func enter(_ step: OnboardingStep) {
        switch step {
        case .checklist: startChecking()
        case .folder: folderStatus = FolderStatus.of(folder)
        case .repos: loadRepos()
        case .welcome, .cloning, .done: break
        }
    }

    private func leave(_ step: OnboardingStep) {
        switch step {
        case .checklist: checklistTask?.cancel()
        case .repos: reposTask?.cancel()
        case .welcome, .folder, .cloning, .done: break
        }
    }

    // MARK: Checklist

    func installGit() {
        requestGitInstall()
        isInstallingGit = true
    }

    func waitForChecklist() async {
        await checklistTask?.value
    }

    // Keeps checking until everything passes, since the fixes happen outside the app; coming back to the step checks again.
    private func startChecking() {
        checklistTask?.cancel()
        checklistTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                let report = await self.checkSetup()
                guard !Task.isCancelled else { return }
                self.setup = report
                if report.gitInstalled { self.isInstallingGit = false }
                if report.isReady { return }
                await self.sleep(Self.checklistPollSeconds)
            }
        }
    }

    // MARK: Folder

    func confirmFolder() {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            folderError = "Couldn't create this folder: \(error.localizedDescription)"
            return
        }
        if settings.folderPath != folder.path { settings.folderPath = folder.path }
        next()
    }

    // MARK: Repos

    func selectOrg(_ org: String) {
        guard org != selectedOrg else { return }
        selectedOrg = org
        loadRepos()
    }

    func selectAll() {
        for index in repoChoices.indices where repoChoices[index].isSelectable { repoChoices[index].selected = true }
    }

    func selectNone() {
        for index in repoChoices.indices { repoChoices[index].selected = false }
    }

    func reloadRepos() {
        loadRepos()
    }

    func showRepos(org: String, choices: [RepoChoice]) {
        if !orgs.contains(org) { orgs.append(org) }
        selectedOrg = org
        repoChoices = choices
        reposState = .loaded
    }

    func finishRepos() {
        if reposState == .noOrganizations {
            history.append(step)
            move(to: .done)
            return
        }
        guard reposState == .loaded, let org = selectedOrg else { return }
        for choice in repoChoices where choice.isSelectable {
            let name = choice.repo.name
            if !choice.selected {
                if !settings.exclusions.containsRepo(name) { settings.exclude(name) }
            } else if settings.exclusions.containsRepo(name) || (!choice.alreadyHere && settings.knownRepos?.containsRepo(name) == true) {
                settings.unexclude(name)
            }
        }
        settings.addCloneOrg(org)
        if isNewInstall {
            settings.filter = .organizations
            settings.organizations = org
        }
        let cloning = cloneCount > 0
        settings.requestSync()
        history.append(step)
        move(to: cloning ? .cloning : .done)
    }

    private func loadRepos() {
        reposTask?.cancel()
        reposState = .loading
        let folder = folder
        reposTask = Task { [weak self] in
            guard let client = await self?.makeClient() else {
                guard let self, !Task.isCancelled else { return }
                self.loginRejected()
                return
            }
            do {
                guard let self else { return }
                if self.orgs.isEmpty {
                    let orgs = try await client.organizations()
                    guard !Task.isCancelled else { return }
                    self.orgs = orgs.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                }
                guard let org = self.preferredOrg() else {
                    self.reposState = .noOrganizations
                    return
                }
                self.selectedOrg = org
                let repos = try await client.repos(org: org)
                guard !Task.isCancelled else { return }
                self.repoChoices = Self.choices(
                    for: repos,
                    present: AppModel.folderEntries(in: folder),
                    excluded: self.settings.exclusions,
                    known: self.settings.knownRepos
                )
                self.reposState = .loaded
            } catch GitHubError.unauthorized {
                guard let self, !Task.isCancelled else { return }
                self.loginRejected()
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.reposState = .failed(Message.unreachable)
            }
        }
    }

    private func preferredOrg() -> String? {
        if let selectedOrg, orgs.contains(selectedOrg) { return selectedOrg }
        return settings.cloneOrgs.first(where: orgs.contains) ?? orgs.first
    }

    // No token from gh, or GitHub refused it, so go back to the checklist that says what to run.
    private func loginRejected() {
        setup = (setup ?? .ready).rejectingGitHubLogin()
        orgs = []
        selectedOrg = nil
        history.removeAll { $0.rawValue >= OnboardingStep.checklist.rawValue }
        move(to: .checklist)
    }

    // MARK: Preview

    func loadPreview(
        step: OnboardingStep,
        setup: SetupReport? = .ready,
        installingGit: Bool = false,
        folderStatus: FolderStatus? = nil,
        history: [OnboardingStep] = []
    ) {
        self.step = step
        self.setup = setup
        isInstallingGit = installingGit
        if let folderStatus { self.folderStatus = folderStatus }
        self.history = history
    }
}
