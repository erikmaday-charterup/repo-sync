import SwiftUI

struct MenuPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            switch model.pane {
            case .main: MainPane()
            case .history: HistoryPane()
            case .run(let id): RunDetailPane(id: id)
            case .settings: SettingsPane()
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 8)
        .frame(width: 360)
    }
}

private struct MainPane: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.folderPath == nil {
                ChooseFolderPrompt()
            } else {
                AccessBanner()
                SyncHeader()
                VStack(alignment: .leading, spacing: 0) {
                    RepoLists()
                }
                .opacity(model.access.isWorking || model.access == .unknown ? 1 : 0.55)
            }
            Hairline()
            Footer()
        }
    }
}

// MARK: Header

private struct SyncHeader: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 24) {
                    Stat(label: "Last sync", value: model.isSyncing ? "In progress" : RelativeTime.ago(model.lastSync, now: context.date))
                    Stat(label: "Next sync", value: model.isSyncing ? "–" : RelativeTime.until(model.nextSync, now: context.date))
                    Stat(label: "GitHub", value: githubText, tint: githubTint)
                    Spacer(minLength: 0)
                    SyncButton()
                }
                if model.isSyncing {
                    SyncProgress(done: model.progress.done, total: model.progress.total, cloning: model.isCloning)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
        }
    }

    private var githubText: String {
        switch model.access {
        case .unknown: return "Not checked"
        case .working: return "Connected"
        case .refused: return "Failed"
        case .unreachable: return "Unreachable"
        }
    }

    private var githubTint: Color {
        switch model.access {
        case .refused, .unreachable: return .red
        default: return .primary
        }
    }
}

private struct SyncButton: View {
    @EnvironmentObject private var model: AppModel
    @State private var hovering = false

    var body: some View {
        Button {
            model.syncNow()
        } label: {
            ZStack {
                if model.isSyncing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                        .foregroundStyle(hovering ? .primary : .secondary)
                }
            }
            .frame(width: 26, height: 26)
            .modifier(RefreshBackground(highlighted: hovering && !model.isSyncing))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(model.isSyncing ? "Syncing" : "Sync now")
        .keyboardShortcut("r", modifiers: .command)
        .onHover { hovering = $0 }
    }
}

// Liquid Glass needs the macOS 26 SDK; older toolchains and systems get a plain hover circle.
private struct RefreshBackground: ViewModifier {
    let highlighted: Bool

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Circle())
        } else {
            plain(content)
        }
        #else
        plain(content)
        #endif
    }

    private func plain(_ content: Content) -> some View {
        content.background(Circle().fill(Color.primary.opacity(highlighted ? 0.06 : 0)))
    }
}

private struct SyncProgress: View {
    let done: Int
    let total: Int
    var cloning = false

    var body: some View {
        HStack(spacing: 10) {
            if total == 0 {
                ProgressView().progressViewStyle(.linear)
                Text("Checking GitHub")
            } else {
                ProgressView(value: Double(done), total: Double(total)).progressViewStyle(.linear)
                Text(cloning ? "Cloning \(done) of \(total)" : "\(done) of \(total)")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .controlSize(.small)
    }
}

private struct Stat: View {
    let label: String
    let value: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 11)).foregroundStyle(.tertiary)
            Text(value).font(.system(size: 13)).foregroundStyle(tint).monospacedDigit()
        }
    }
}

private struct AccessBanner: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let guidance {
            VStack(alignment: .leading, spacing: 7) {
                Text(guidance.message)
                    .font(.system(size: 12))
                    .foregroundStyle(guidance.syncStopped ? Color.red : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if guidance.command != nil || guidance.offersSetup {
                    HStack(spacing: 8) {
                        if let command = guidance.command { CopyableCommand(command: command) }
                        if guidance.offersSetup {
                            Button("Open setup") { OnboardingWindow.openSetup(model: model) }
                                .controlSize(.small)
                                .fixedSize()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(guidance.syncStopped ? Color.red.opacity(0.08) : Color.primary.opacity(0.045)))
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
    }

    private var guidance: AccessGuidance? {
        AccessGuidance.make(
            folderMissing: model.folderMissing, access: model.access, problem: model.setupProblem, overHTTPS: model.accessCheckedOverHTTPS
        )
    }
}

// MARK: Lists

private struct RepoLists: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let attention = model.needsAttention
        let offDefault = model.offDefault
        let deleted = model.pendingDeletions

        if !deleted.isEmpty {
            SectionLabel("Deleted")
            ForEach(deleted, id: \.self) { DeletedRow(name: $0) }
        }

        if !attention.isEmpty {
            SectionLabel("Not pulled")
            ForEach(attention) { AttentionRow(status: $0) }
        }

        if !offDefault.isEmpty {
            SectionLabel(offDefault.allSatisfy { $0.defaultBranch == "main" } ? "Off main" : "Off the default branch")
            ForEach(offDefault) { repo in
                RepoRow(name: repo.name, path: repo.path, branch: repo.branch)
                ForEach(Array(repo.worktrees.enumerated()), id: \.element.id) { index, tree in
                    WorktreeRow(tree: tree, isLast: index == repo.worktrees.count - 1)
                }
            }
        }

        if attention.isEmpty && offDefault.isEmpty && deleted.isEmpty && model.repoCount > 0 {
            Text("Every repo is on main and up to date")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 4)
        }

        if model.repoCount == 0 && !model.isSyncing && !model.folderMissing {
            Text("No GitHub repos found in this folder")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 4)
        }
    }
}

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 3)
    }
}

private struct AttentionRow: View {
    @EnvironmentObject private var model: AppModel
    let status: RepoStatus

    var body: some View {
        HoverRow(verticalPadding: 5) { hovering in
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    Circle().fill(dotColor).frame(width: 6, height: 6)
                    Text(status.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 8)
                    if hovering {
                        RowActions(path: status.path)
                    } else if let behind {
                        Text(behind).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Text(reason)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 14)
                    .lineLimit(2)
            }
        }
    }

    private var dotColor: Color {
        if case .failed = status.outcome { return .red }
        return .orange
    }

    private var behind: String? {
        if case .skipped(_, let count) = status.outcome, count > 0 { return "\(count) behind" }
        return nil
    }

    private var reason: String {
        switch status.outcome {
        case .skipped(let reason, _), .failed(let reason): return reason
        default: return ""
        }
    }
}

private struct DeletedRow: View {
    @EnvironmentObject private var model: AppModel
    let name: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(Color.orange).frame(width: 6, height: 6)
                Text("\(Text(name).fontWeight(.medium).foregroundColor(.primary)) was removed from your folder.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Button("Exclude it") { model.excludeDeleted(name) }
                Button("Clone it again") { model.recloneDeleted(name) }
            }
            .controlSize(.small)
            .padding(.leading, 14)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
    }
}

private struct RepoRow: View {
    let name: String
    let path: String
    let branch: String

    var body: some View {
        HoverRow(verticalPadding: 3) { hovering in
            HStack(spacing: 8) {
                Text(name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                if hovering {
                    RowActions(path: path)
                } else {
                    Text(branch)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }
}

private struct WorktreeRow: View {
    let tree: Worktree
    let isLast: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(tree.branch).font(.system(size: 12, design: .monospaced))
            if tree.showsFolder {
                Text(tree.folderName).font(.system(size: 12)).foregroundStyle(.tertiary)
            }
        }
        .lineLimit(1)
        .foregroundStyle(.secondary)
        .padding(.leading, 36)
        .padding(.trailing, 16)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .leading) {
            Rail(isLast: isLast)
                .stroke(Color.primary.opacity(0.22), lineWidth: 1)
                .frame(width: 34)
        }
    }
}

private struct Rail: Shape {
    let isLast: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let x: CGFloat = 26.5
        path.move(to: CGPoint(x: x, y: rect.minY))
        path.addLine(to: CGPoint(x: x, y: isLast ? rect.midY : rect.maxY))
        path.move(to: CGPoint(x: x, y: rect.midY))
        path.addLine(to: CGPoint(x: x + 6, y: rect.midY))
        return path
    }
}

private struct RowActions: View {
    @EnvironmentObject private var model: AppModel
    let path: String

    var body: some View {
        HStack(spacing: 4) {
            IconButton(symbol: "terminal", help: "Open in Terminal") { model.openInTerminal(path) }
            IconButton(symbol: "folder", help: "Show in Finder") { model.showInFinder(path) }
        }
    }
}

private struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: 22, height: 18)
                .background(RoundedRectangle(cornerRadius: 4).fill(hovering ? Color.primary.opacity(0.08) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

// MARK: Footer and prompts

private struct Footer: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let update = model.availableUpdate {
                UpdateRow(version: update.version, installing: model.isInstallingUpdate, failed: model.updateFailed) {
                    model.installUpdate()
                }
            }
            if model.folderPath != nil && model.repoCount > 0 {
                FooterItem(title: "All repos", shortcut: "\(model.repoCount)") {
                    PanelControl.close()
                    ReposWindow.show(model: model)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            FooterItem(title: "Sync history", shortcut: "⌘L") { model.pane = .history }
                .keyboardShortcut("l", modifiers: .command)
            FooterItem(title: "Settings", shortcut: "⌘,") { model.pane = .settings }
                .keyboardShortcut(",", modifiers: .command)
            FooterItem(title: "Quit", shortcut: "⌘Q") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
    }
}

private struct UpdateRow: View {
    let version: Version
    let installing: Bool
    let failed: Bool
    let install: () -> Void

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(failed && !installing ? Color.red : Color.secondary)
            Spacer()
            Button("Update", action: install)
                .controlSize(.small)
                .disabled(installing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
    }

    private var title: String {
        if installing { return "Updating…" }
        return failed ? "Update failed" : "Update available: \(version.description)"
    }
}

struct FooterItem: View {
    let title: String
    let shortcut: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HoverRow(verticalPadding: 2) { _ in
                HStack {
                    Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Text(shortcut).font(.system(size: 12)).foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct ChooseFolderPrompt: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Choose a folder to sync").font(.system(size: 13, weight: .medium))
            Text("Repo Sync keeps the main branch current in every GitHub repo inside it.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Choose folder") { model.chooseFolder() }
                .controlSize(.small)
                .padding(.top, 6)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }
}

// MARK: Shared pieces

struct CopyableCommand: View {
    private static let copiedSeconds: UInt64 = 2

    let command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 6) {
            Text(command)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .fixedSize()
                .textSelection(.enabled)
            Button(copied ? "Copied" : "Copy") { copy() }
                .controlSize(.small)
        }
        .padding(.leading, 8)
        .padding(.trailing, 2)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
        .fixedSize()
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.copiedSeconds * 1_000_000_000)
            copied = false
        }
    }
}

struct HoverRow<Content: View>: View {
    var verticalPadding: CGFloat = 3
    @ViewBuilder let content: (Bool) -> Content
    @State private var hovering = false

    var body: some View {
        content(hovering)
            .padding(.horizontal, 10)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.05) : .clear))
            .contentShape(Rectangle())
            .padding(.horizontal, 6)
            .onHover { hovering = $0 }
    }
}

struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(height: 0.5)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
    }
}
