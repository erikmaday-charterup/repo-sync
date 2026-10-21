import AppKit
import SwiftUI

private enum Layout {
    static let width: CGFloat = 540
    static let contentHeight: CGFloat = 300
    static let horizontalPadding: CGFloat = 40
    static let boxCornerRadius: CGFloat = 10
    static let visibleCloneRows = 5
}

struct OnboardingView: View {
    @EnvironmentObject private var onboarding: OnboardingModel

    var body: some View {
        VStack(spacing: 0) {
            StepDots(current: onboarding.step)
                .padding(.top, 4)
                .padding(.bottom, 22)
            stepContent
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, Layout.horizontalPadding)
                .padding(.bottom, 20)
                .frame(height: Layout.contentHeight, alignment: .top)
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 0.5)
            ActionBar()
        }
        .frame(width: Layout.width)
    }

    @ViewBuilder private var stepContent: some View {
        switch onboarding.step {
        case .welcome: WelcomeStep()
        case .checklist: ChecklistStep()
        case .folder: FolderStep()
        case .repos: ReposStep()
        case .cloning: CloningStep()
        case .done: DoneStep()
        }
    }
}

// MARK: Shared pieces

private struct StepDots: View {
    let current: OnboardingStep

    var body: some View {
        HStack(spacing: 7) {
            ForEach(OnboardingStep.allCases, id: \.self) { step in
                Circle()
                    .fill(step.rawValue <= current.rawValue ? Color.accentColor : Color.primary.opacity(0.15))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(current.rawValue + 1) of \(OnboardingStep.allCases.count)")
    }
}

private struct StepTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.system(size: 20, weight: .semibold)).padding(.bottom, 2)
    }
}

private struct StepBody: View {
    let text: Text
    var size: CGFloat = 13

    init(_ text: String, size: CGFloat = 13) {
        self.text = Text(text)
        self.size = size
    }

    init(text: Text) {
        self.text = text
    }

    var body: some View {
        text
            .font(.system(size: size))
            .foregroundStyle(.secondary)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct Box<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Layout.boxCornerRadius).fill(Color.primary.opacity(0.045)))
    }
}

private struct StatusLine<Accessory: View>: View {
    let headline: String
    let detail: String
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(headline).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            accessory
        }
    }
}

private struct StatusIcon: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(color).frame(width: 24)
    }
}

// MARK: Steps

private struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "square.stack.3d.down.right")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
            StepTitle("Every repo, always current")
            StepBody("Repo Sync clones your team's GitHub repos into one folder and keeps their main branch up to date every hour. It never touches your branches or uncommitted work.")
            StepBody("Setup takes about two minutes, plus however long the first clone takes.")
        }
    }
}

private struct ChecklistStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepTitle("Checking your Mac")
            StepBody("Repo Sync needs git and GitHub's gh tool, and borrows gh's login. It never changes their setup. It shows you what to run instead.")
            Box(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(SetupItem.allCases) { item in
                        if item != SetupItem.allCases.first {
                            Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 0.5).padding(.horizontal, 14)
                        }
                        ChecklistRow(item: item)
                    }
                }
                .padding(.vertical, 2)
            }
            .padding(.top, 4)
        }
    }
}

private struct ChecklistRow: View {
    private static let ghSite = URL(string: "https://cli.github.com")!

    @EnvironmentObject private var onboarding: OnboardingModel
    let item: SetupItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            icon.frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.system(size: 13, weight: state == .failed ? .medium : .regular))
                        .foregroundStyle(state == .passed || state == .failed ? .primary : .secondary)
                    Spacer(minLength: 8)
                    if state == .passed, item == .git, let version = onboarding.setup?.gitVersion {
                        Text("Version \(version)").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                if state == .failed {
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    action.padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var state: SetupItemState? {
        onboarding.setup?.state(of: item)
    }

    @ViewBuilder private var icon: some View {
        switch state {
        case nil: ProgressView().controlSize(.mini)
        case .passed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .waiting: Image(systemName: "circle").foregroundStyle(.tertiary)
        }
    }

    private var installingGit: Bool { item == .git && onboarding.isInstallingGit }

    private var title: String {
        switch state {
        case .passed: return item.passedTitle
        case .failed: return installingGit ? "Waiting for git to install" : item.failedTitle
        case .waiting, nil: return item.waitingTitle
        }
    }

    private var detail: String {
        installingGit ? "Follow the macOS prompt. This step continues when git works." : item.failedDetail
    }

    @ViewBuilder private var action: some View {
        switch item {
        case .git:
            Button("Install git") { onboarding.installGit() }.controlSize(.small)
        case .gh:
            HStack(spacing: 10) {
                if let command = item.command { CopyableCommand(command: command) }
                Link("cli.github.com", destination: Self.ghSite).font(.system(size: 12))
            }
        case .ghLogin, .gitLogin:
            if let command = item.command { CopyableCommand(command: command) }
        }
    }
}

private struct FolderStep: View {
    @EnvironmentObject private var onboarding: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepTitle("Where should your repos live?")
            StepBody("Repo Sync clones into this folder and watches every repo inside it.")
            Box {
                HStack(spacing: 12) {
                    Image(systemName: "folder").font(.system(size: 20)).foregroundStyle(.secondary).frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(onboarding.folder.path.abbreviatingHome)
                            .font(.system(size: 13, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.head)
                        Text(onboarding.folderStatus.description).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button("Change") { chooseFolder() }
                }
            }
            .padding(.top, 6)
            if let error = onboarding.folderError {
                Text(error).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            StepBody("Already have repos somewhere? Pick that folder. Repo Sync leaves existing repos alone and only clones what's missing.", size: 12)
                .padding(.top, 2)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder for your repos"
        let existing = onboarding.folderStatus == .new ? onboarding.folder.deletingLastPathComponent() : onboarding.folder
        panel.directoryURL = existing
        if panel.runModal() == .OK, let url = panel.url {
            onboarding.folder = url
        }
    }
}

private struct ReposStep: View {
    @EnvironmentObject private var onboarding: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepTitle("Choose repos")
            switch onboarding.reposState {
            case .loaded:
                intro
                HStack(spacing: 14) {
                    Text(summary).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Button("Select all") { onboarding.selectAll() }.buttonStyle(LinkButtonStyle())
                    Button("Select none") { onboarding.selectNone() }.buttonStyle(LinkButtonStyle())
                }
                .padding(.top, 2)
                RepoList()
            case .loading:
                placeholder {
                    ProgressView().controlSize(.small)
                    Text("Loading repos from GitHub").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            case .noOrganizations:
                placeholder {
                    Text("Your GitHub account isn't in any organizations, so there's nothing to clone.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            case .failed(let message):
                placeholder {
                    Text(message).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Try again") { onboarding.reloadRepos() }.controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder private var intro: some View {
        let rest = "Untick anything you don't want; you can change this later in Settings."
        if onboarding.orgs.count > 1 {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("From").font(.system(size: 13)).foregroundStyle(.secondary)
                    Picker("Organization", selection: Binding(get: { onboarding.selectedOrg ?? "" }, set: { onboarding.selectOrg($0) })) {
                        ForEach(onboarding.orgs, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                StepBody(rest)
            }
        } else {
            let org = Text(onboarding.selectedOrg ?? "").fontWeight(.medium).foregroundColor(.primary)
            StepBody(text: Text("From \(org). \(rest)"))
        }
    }

    private func placeholder<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 10) { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: Layout.boxCornerRadius).fill(Color.primary.opacity(0.045)))
            .padding(.top, 6)
    }

    private var summary: String {
        let counts = "\(onboarding.selectedCount) of \(onboarding.repoChoices.count) selected"
        guard onboarding.selectedSize > 0 else { return counts }
        return "\(counts), about \(RepoSize.text(kilobytes: onboarding.selectedSize))"
    }
}

private struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(Color.accentColor)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

private struct RepoList: View {
    @EnvironmentObject private var onboarding: OnboardingModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach($onboarding.repoChoices) { $choice in
                    HStack(spacing: 8) {
                        Toggle(choice.repo.name, isOn: $choice.selected)
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                        Text(choice.repo.name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(trailing(choice)).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onTapGesture { if choice.isSelectable { choice.selected.toggle() } }
                    .disabled(!choice.isSelectable)
                }
            }
            .padding(.vertical, 6)
        }
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: Layout.boxCornerRadius).fill(Color.primary.opacity(0.045)))
        .clipShape(RoundedRectangle(cornerRadius: Layout.boxCornerRadius))
    }

    private func trailing(_ choice: RepoChoice) -> String {
        if choice.alreadyHere { return "Already here" }
        if choice.repo.archived { return "Archived" }
        return RepoSize.text(kilobytes: choice.repo.sizeKB)
    }
}

enum RepoSize {
    private static let unit = 1000.0

    // Whole megabytes and one decimal for gigabytes, like "98 MB" and "2.1 GB".
    static func text(kilobytes: Int) -> String {
        let bytes = Double(kilobytes) * 1024
        let megabytes = bytes / unit / unit
        if megabytes < 1 { return "\(Int((bytes / unit).rounded())) KB" }
        if megabytes < unit { return "\(Int(megabytes.rounded())) MB" }
        return String(format: "%.1f GB", megabytes / unit)
    }
}

private struct CloningStep: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let activity = model.cloneActivity
        VStack(alignment: .leading, spacing: 12) {
            StepTitle("Cloning your repos")
            if let problem = stopProblem(activity) {
                StepBody("Repo Sync couldn't clone anything this time. It tries again on the next sync.")
                Box {
                    HStack(spacing: 12) {
                        StatusIcon(symbol: "exclamationmark.circle.fill", color: .orange)
                        StatusLine(headline: problem, detail: "Open Sync history from the menu bar to see what happened.") { EmptyView() }
                    }
                }
                .padding(.top, 6)
            } else {
                progressContent(activity)
            }
        }
    }

    // Shown instead of "Nothing new to clone" when the sync stopped or couldn't list repos.
    private func stopProblem(_ activity: CloneActivity) -> String? {
        guard !model.isSyncing, activity.total == 0 else { return nil }
        return model.cloneProblem
    }

    @ViewBuilder private func progressContent(_ activity: CloneActivity) -> some View {
        StepBody("You can close this window. Cloning keeps going, and the menu bar shows progress.")
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(status(activity)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text(count(activity)).monospacedDigit()
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            progressBar(activity)
        }
        .padding(.top, 4)
        if !activity.items.isEmpty {
            Box(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(activity.items.suffix(Layout.visibleCloneRows)) { item in
                        CloneRow(item: item)
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder private func progressBar(_ activity: CloneActivity) -> some View {
        if model.isSyncing && model.isCloning && model.progress.total > 0 {
            ProgressView(value: Double(model.progress.done), total: Double(model.progress.total))
        } else if model.isSyncing && activity.total == 0 {
            ProgressView().progressViewStyle(.linear)
        } else {
            ProgressView(value: 1, total: 1)
        }
    }

    private func status(_ activity: CloneActivity) -> String {
        if model.isSyncing && model.isCloning { return activity.current.map { "Cloning \($0)" } ?? "Cloning" }
        if model.isSyncing { return activity.total == 0 ? "Getting ready" : "Finishing up" }
        if activity.total == 0 { return "Nothing new to clone" }
        let cloned = activity.finishedCount - activity.failedCount
        let summary = cloned == 1 ? "Cloned 1 repo" : "Cloned \(cloned) repos"
        return activity.failedCount == 0 ? summary : "\(summary). \(activity.failedCount) failed, see Sync history."
    }

    private func count(_ activity: CloneActivity) -> String {
        if model.isSyncing && model.isCloning && model.progress.total > 0 { return "\(model.progress.done) of \(model.progress.total)" }
        guard activity.total > 0 else { return "" }
        return "\(activity.finishedCount) of \(activity.total)"
    }
}

private struct CloneRow: View {
    let item: CloneActivity.Item

    var body: some View {
        HStack(spacing: 10) {
            Group {
                switch item.state {
                case .cloning: ProgressView().controlSize(.mini)
                case .cloned: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                }
            }
            .font(.system(size: 13))
            .frame(width: 16)
            Text(item.name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var label: String {
        switch item.state {
        case .cloning: return "Cloning"
        case .cloned: return "Done"
        case .failed: return "Failed"
        }
    }
}

private struct DoneStep: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepTitle("You're set")
            StepBody("Repo Sync lives in your menu bar now. Click the stack icon any time to see what's current, what was skipped, and what changed.")
            Box(padding: 0) {
                VStack(spacing: 0) {
                    row("Open at login") {
                        Toggle("Open at login", isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 0.5).padding(.horizontal, 14)
                    row("Sync every") {
                        Picker("Sync every", selection: $model.intervalMinutes) {
                            ForEach(AppModel.intervalChoices, id: \.self) { Text(IntervalTitle.text($0)).tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                }
            }
            .padding(.top, 6)
        }
    }

    private func row<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack {
            Text(label).font(.system(size: 13))
            Spacer()
            control()
        }
        .frame(minHeight: 40)
        .padding(.horizontal, 14)
    }
}

// MARK: Action bar

private struct ActionBar: View {
    @EnvironmentObject private var onboarding: OnboardingModel
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            if onboarding.canGoBack {
                Button("Back") { onboarding.back() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 13))
                    .keyboardShortcut(.cancelAction)
            }
            Spacer()
            primary
        }
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder private var primary: some View {
        switch onboarding.step {
        case .welcome:
            if needsMove {
                PrimaryButton("Move to Applications and continue") { moveToApplications() }
            } else {
                PrimaryButton("Get started") { onboarding.next() }
            }
        case .checklist:
            PrimaryButton("Continue", enabled: onboarding.isSetupReady) { onboarding.next() }
        case .folder:
            PrimaryButton("Continue") { onboarding.confirmFolder() }
        case .repos:
            PrimaryButton(reposTitle, enabled: reposReady) { onboarding.finishRepos() }
        case .cloning:
            PrimaryButton("Continue", enabled: !model.isSyncing) { onboarding.next() }
        case .done:
            PrimaryButton("Finish") { OnboardingWindow.close() }
        }
    }

    private var needsMove: Bool {
        AppLocation.needsMove(bundleURL: Bundle.main.bundleURL, home: FileManager.default.homeDirectoryForCurrentUser)
    }

    private func moveToApplications() {
        do {
            try AppLocation.moveAndRelaunch()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't move Repo Sync to Applications"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            onboarding.next()
        }
    }

    private var reposReady: Bool {
        onboarding.reposState == .loaded || onboarding.reposState == .noOrganizations
    }

    private var reposTitle: String {
        switch onboarding.cloneCount {
        case 0: return "Continue"
        case 1: return "Clone 1 repo"
        case let count: return "Clone \(count) repos"
        }
    }
}

private struct PrimaryButton: View {
    let title: String
    var enabled = true
    let action: () -> Void

    init(_ title: String, enabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!enabled)
    }
}

// MARK: Window

@MainActor
enum OnboardingWindow {
    private static var window: NSWindow?
    private static var onboarding: OnboardingModel?
    private static let delegate = OnboardingWindowDelegate()

    static func show(model: AppModel, start: OnboardingStep) {
        if let window, window.isVisible, onboarding != nil {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let onboarding = OnboardingModel.live(
            settings: model,
            start: OnboardingModel.resolvedStart(start, setupReady: model.setup?.isReady == true, folderConfigured: model.folderPath != nil)
        )
        let hosting = NSHostingController(rootView: OnboardingView().environmentObject(onboarding).environmentObject(model))
        hosting.sizingOptions = .preferredContentSize
        let window = self.window ?? makeWindow()
        window.contentViewController = hosting
        window.center()
        self.window = window
        self.onboarding = onboarding
        onboarding.begin()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    static func close() {
        window?.close()
    }

    static func openSetup(model: AppModel) {
        PanelControl.close()
        show(model: model, start: .checklist)
    }

    fileprivate static func windowWillClose() {
        onboarding?.close()
        onboarding = nil
    }

    private static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Layout.width, height: 400),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Repo Sync"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = delegate
        return window
    }
}

@MainActor
private final class OnboardingWindowDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        OnboardingWindow.windowWillClose()
    }
}
