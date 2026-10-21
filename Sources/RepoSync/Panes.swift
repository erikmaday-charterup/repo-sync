import SwiftUI

// MARK: Shared pane pieces

struct PaneHeader: View {
    @EnvironmentObject private var model: AppModel
    let title: String
    let backTitle: String
    let back: Pane

    var body: some View {
        ZStack {
            Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1).padding(.horizontal, 70)
            HStack {
                Button {
                    model.pane = back
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text(backTitle).font(.system(size: 13))
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }
}

// Scrolls only when the content is taller than the panel can show.
struct FittedScroll<Content: View>: View {
    var maxHeight: CGFloat = 440
    @ViewBuilder let content: Content
    @State private var height: CGFloat = 0

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                })
        }
        .frame(height: min(max(height, 1), maxHeight))
        .onPreferenceChange(ContentHeightKey.self) { height = $0 }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct PaneSectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 3)
    }
}

enum DayLabel {
    static func title(for date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: History

struct HistoryPane: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "Sync history", backTitle: "Back", back: .main)
            if model.history.isEmpty {
                Text("No syncs yet. The first one runs as soon as a folder is chosen.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            } else {
                FittedScroll {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(days, id: \.title) { day in
                            PaneSectionLabel(day.title)
                            ForEach(day.notable) { run in RunRow(run: run) }
                            if day.quiet > 0 {
                                Text(day.quiet == 1 ? "1 run with no changes" : "\(day.quiet) runs with no changes")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 16)
                                    .padding(.top, 2)
                            }
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
            Hairline()
            FooterItem(title: "Open raw log", shortcut: "") { model.openLog() }
        }
    }

    private struct Day {
        let title: String
        var notable: [SyncRun]
        var quiet: Int
    }

    private var days: [Day] {
        var result: [Day] = []
        let runs = model.history
        for (index, run) in runs.enumerated() {
            let title = DayLabel.title(for: run.started)
            let previous = runs.indices.contains(index + 1) ? runs[index + 1] : nil
            if result.last?.title != title { result.append(Day(title: title, notable: [], quiet: 0)) }
            if run.isNotable(after: previous) {
                result[result.count - 1].notable.append(run)
            } else {
                result[result.count - 1].quiet += 1
            }
        }
        return result
    }
}

private struct RunRow: View {
    @EnvironmentObject private var model: AppModel
    let run: SyncRun

    var body: some View {
        Button {
            model.pane = .run(run.id)
        } label: {
            HoverRow(verticalPadding: 4) { _ in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(DayLabel.time(run.started))
                        .font(.system(size: 13))
                        .monospacedDigit()
                        .frame(width: 66, alignment: .leading)
                    Text(run.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(run.stopped == nil ? Color.secondary : Color.red)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

struct RunDetailPane: View {
    @EnvironmentObject private var model: AppModel
    let id: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let run = model.run(id: id) {
                PaneHeader(
                    title: "\(DayLabel.title(for: run.started)) at \(DayLabel.time(run.started))",
                    backTitle: "History",
                    back: .history
                )
                Text(subtitle(run))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                FittedScroll(maxHeight: 420) {
                    RunDetails(run: run).padding(.bottom, 6)
                }
            } else {
                PaneHeader(title: "Sync history", backTitle: "History", back: .history)
                Text("This run is no longer in the history.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        }
    }

    private func subtitle(_ run: SyncRun) -> String {
        let started = run.trigger == .manual ? "Started with Sync now." : "Ran on schedule."
        if let stopped = run.stopped { return "Stopped before pulling anything: \(stopped). \(started)" }
        let seconds = Int(run.duration.rounded())
        let duration = seconds == 1 ? "1 second" : "\(seconds) seconds"
        return "Checked \(run.repoCount) repos in \(duration). \(started)"
    }
}

private struct RunDetails: View {
    let run: SyncRun

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if run.stopped == nil && run.cloned.isEmpty && run.pulled.isEmpty && run.skipped.isEmpty && run.failed.isEmpty {
                Text("Nothing changed. Every repo was already current.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }
            if !run.cloned.isEmpty {
                PaneSectionLabel("Cloned")
                ForEach(run.cloned, id: \.self) { name in
                    Text(name)
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !run.pulled.isEmpty {
                PaneSectionLabel("Pulled")
                ForEach(run.pulled, id: \.name) { repo in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(repo.name).font(.system(size: 13, weight: .medium))
                            Spacer()
                            Text(repo.count == 1 ? "1 commit" : "\(repo.count) commits")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(repo.commits, id: \.sha) { commit in
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Text(commit.sha).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                                Text(commit.subject).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .padding(.leading, 10)
                        }
                        if repo.count > repo.commits.count {
                            Text("and \(repo.count - repo.commits.count) more")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 10)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                }
            }
            if !run.skipped.isEmpty {
                PaneSectionLabel("Skipped")
                ForEach(run.skipped, id: \.name) { repo in
                    IssueRow(name: repo.name, detail: repo.reason, trailing: repo.behind > 0 ? "\(repo.behind) behind" : nil, color: .orange)
                }
            }
            if !run.failed.isEmpty {
                PaneSectionLabel("Failed")
                ForEach(run.failed, id: \.name) { repo in
                    IssueRow(name: repo.name, detail: repo.reason, trailing: nil, color: .red)
                }
            }
        }
    }
}

private struct IssueRow: View {
    let name: String
    let detail: String
    let trailing: String?
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(name).font(.system(size: 13, weight: .medium))
                Spacer()
                if let trailing { Text(trailing).font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).padding(.leading, 14)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
}

// MARK: Settings

struct SettingsPane: View {
    @EnvironmentObject private var model: AppModel
    @State private var availableOrgs: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "Settings", backTitle: "Back", back: .main)
            FittedScroll(maxHeight: 500) { groups }
        }
        .padding(.bottom, 4)
        .task(id: model.setup?.isReady) { await loadOrganizations() }
    }

    private var groups: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup(title: "GitHub account", footer: "Repo Sync borrows gh's GitHub login and never changes your gh or git setup.") {
                accountRows
            }

            SettingsGroup(title: "Repos", footer: reposFooter) {
                SettingsRow("Folder") {
                    HStack(spacing: 6) {
                        Text(model.folderPath?.abbreviatingHome ?? "None chosen")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(model.folderPath == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Button(model.folderPath == nil ? "Choose" : "Change") { model.chooseFolder() }
                            .controlSize(.small)
                    }
                }
                RowDivider()
                SettingsRow("Sync") {
                    Picker("Sync", selection: $model.filter) {
                        ForEach(RepoFilter.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .fixedSize()
                }
                RowDivider()
                SettingsRow("Clone from") { cloneOrgsMenu }
                RowDivider()
                SettingsRow("Repos to clone") {
                    Button("Choose repos") { openOnboarding(at: .repos) }.controlSize(.small)
                }
                if model.filter == .organizations {
                    RowDivider()
                    SettingsRow("Organizations") {
                        TextField("Organizations", text: $model.organizations, prompt: Text("your-org, another-org"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .font(.system(size: 11))
                            .frame(width: 210)
                    }
                }
            }

            SettingsGroup(title: "Schedule", footer: nil) {
                SettingsRow("Sync every") {
                    Picker("Sync every", selection: $model.intervalMinutes) {
                        ForEach(AppModel.intervalChoices, id: \.self) { Text(IntervalTitle.text($0)).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .fixedSize()
                }
                RowDivider()
                SettingsRow("Open at login") {
                    Toggle("Open at login", isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
            }

            SettingsGroup(title: "GitHub access", footer: "Uses the GitHub login git already uses on this Mac.") {
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    HStack(spacing: 6) {
                        Image(systemName: accessSymbol).foregroundStyle(accessColor)
                        Text(accessTitle).font(.system(size: 12))
                        Spacer()
                        Text(checkedText(now: context.date)).font(.system(size: 11)).foregroundStyle(.secondary)
                        Button("Check now") { model.checkAccessNow() }.controlSize(.small)
                    }
                    .frame(minHeight: 32)
                    .padding(.horizontal, 10)
                }
            }

            SettingsGroup(title: "Excluded repos", footer: "Excluded repos are never cloned or synced.") {
                if model.exclusions.isEmpty {
                    SettingsRow("None") { EmptyView() }
                } else {
                    ForEach(Array(model.exclusions.sorted().enumerated()), id: \.element) { index, name in
                        if index > 0 { RowDivider() }
                        SettingsRow(name, truncatesLabel: true) {
                            Button { model.unexclude(name) } label: {
                                Image(systemName: "minus.circle").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Include \(name) again")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var accountRows: some View {
        if let problem = model.setupProblem {
            SettingsRow(problem.failedTitle, truncatesLabel: true) { checkAgainButton }
            RowDivider()
            HStack(spacing: 8) {
                if let command = problem.command { CopyableCommand(command: command) }
                Spacer(minLength: 8)
                Button("Open setup") { openOnboarding(at: .checklist) }.controlSize(.small)
            }
            .frame(minHeight: 32)
            .padding(.horizontal, 10)
        } else {
            SettingsRow(accountTitle, truncatesLabel: true) { checkAgainButton }
        }
    }

    private var accountTitle: String {
        guard model.setup != nil else { return "Checking gh" }
        return model.githubLogin.map { "Connected through gh as \($0)" } ?? "Connected through gh"
    }

    private var checkAgainButton: some View {
        Button("Check again") { model.checkSetupAgain() }
            .controlSize(.small)
            .disabled(model.isCheckingSetup)
    }

    private var cloneOrgsMenu: some View {
        Menu {
            ForEach(menuOrgs, id: \.self) { org in
                Toggle(org, isOn: Binding(get: { model.cloneOrgs.contains(org) }, set: { setCloneOrg(org, $0) }))
            }
            if menuOrgs.isEmpty { Text("No organizations") }
        } label: {
            Text(model.cloneOrgs.isEmpty ? "None" : model.cloneOrgs.joined(separator: ", "))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .menuStyle(.button)
        .controlSize(.small)
        .frame(maxWidth: 210, alignment: .trailing)
    }

    private var menuOrgs: [String] {
        var orgs = model.cloneOrgs
        for org in availableOrgs where !orgs.contains(org) { orgs.append(org) }
        return orgs.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func setCloneOrg(_ org: String, _ isOn: Bool) {
        if isOn {
            model.addCloneOrg(org)
        } else {
            model.cloneOrgs.removeAll { $0 == org }
        }
    }

    private func loadOrganizations() async {
        guard model.setup?.isReady == true, let client = await model.githubClient() else { return }
        do {
            availableOrgs = try await client.organizations()
        } catch GitHubError.unauthorized {
            model.githubRejectedLogin()
        } catch {
            model.log("Couldn't list your GitHub organizations: \(error)")
        }
    }

    private var reposFooter: String {
        guard model.folderPath != nil else { return "Choose the folder that holds your repos." }
        let count = model.repoCount == 1 ? "1 repo matches." : "\(model.repoCount) repos match."
        return model.filter == .organizations ? "\(count) Separate organizations with commas." : count
    }

    private func openOnboarding(at step: OnboardingStep) {
        PanelControl.close()
        OnboardingWindow.show(model: model, start: step)
    }

    private var accessTitle: String {
        if model.isCheckingAccess { return "Checking" }
        switch model.access {
        case .unknown: return "Not checked yet"
        case .working: return "Working"
        case .refused: return "Failed"
        case .unreachable: return "Couldn't reach GitHub"
        }
    }

    private var accessSymbol: String {
        switch model.access {
        case .working: return "checkmark.circle"
        case .unknown: return "circle.dashed"
        case .refused, .unreachable: return "xmark.circle"
        }
    }

    private var accessColor: Color {
        switch model.access {
        case .working: return .green
        case .unknown: return .secondary
        case .refused, .unreachable: return .red
        }
    }

    private func checkedText(now: Date) -> String {
        guard let checked = model.accessChecked, !model.isCheckingAccess else { return "" }
        return RelativeTime.ago(checked, now: now)
    }
}

enum IntervalTitle {
    static func text(_ minutes: Int) -> String {
        switch minutes {
        case 60: return "Hour"
        case let m where m % 60 == 0: return "\(m / 60) hours"
        default: return "\(minutes) minutes"
        }
    }
}

private struct SettingsGroup<Content: View>: View {
    let title: String
    let footer: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 5)
            VStack(spacing: 0) {
                content
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
            .padding(.horizontal, 12)
            if let footer {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.top, 5)
            }
        }
    }
}

private struct RowDivider: View {
    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 0.5).padding(.horizontal, 10)
    }
}

private struct SettingsRow<Control: View>: View {
    let label: String
    let truncatesLabel: Bool
    @ViewBuilder let control: Control

    init(_ label: String, truncatesLabel: Bool = false, @ViewBuilder control: () -> Control) {
        self.label = label
        self.truncatesLabel = truncatesLabel
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 10) {
            if truncatesLabel {
                Text(label).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            } else {
                Text(label).font(.system(size: 12)).fixedSize()
            }
            Spacer(minLength: 8)
            control
        }
        .frame(minHeight: 32)
        .padding(.horizontal, 10)
    }
}
