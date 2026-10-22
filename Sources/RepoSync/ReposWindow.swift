import AppKit
import SwiftUI

private struct RepoTableRow: Identifiable {
    let name: String
    let path: String
    let branch: String
    let status: String
    let statusRank: Int
    let mark: Color?
    let lastPulled: Date?
    let worktrees: String
    let isOffDefault: Bool

    var id: String { name }
    var lastPulledSort: Date { lastPulled ?? .distantPast }
}

private enum RepoScope: String, CaseIterable, Identifiable {
    case all, notPulled, offMain
    var id: String { rawValue }
}

struct ReposView: View {
    @EnvironmentObject private var model: AppModel
    @State private var scope: RepoScope = .all
    @State private var query = ""
    @State private var selection = Set<String>()
    @State private var sortOrder = [KeyPathComparator(\RepoTableRow.name, comparator: .localizedStandard)]

    var body: some View {
        let all = rows
        let shown = filtered(all).sorted(using: sortOrder)

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Show", selection: $scope) {
                    Text("All \(all.count)").tag(RepoScope.all)
                    Text("Not pulled \(all.filter { $0.statusRank > 0 }.count)").tag(RepoScope.notPulled)
                    Text("Off main \(all.filter(\.isOffDefault).count)").tag(RepoScope.offMain)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Spacer()

                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filter repos or branches", text: $query)
                        .textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                            .buttonStyle(.plain)
                            .help("Clear filter")
                    }
                }
                .font(.system(size: 12))
                .padding(.horizontal, 7)
                .frame(width: 220, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Table(shown, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Repo", value: \.name, comparator: .localizedStandard) { row in
                    HStack(spacing: 7) {
                        Circle().fill(row.mark ?? .clear).frame(width: 6, height: 6)
                        Text(row.name)
                    }
                }
                .width(min: 160, ideal: 210)

                TableColumn("Branch", value: \.branch, comparator: .localizedStandard) { row in
                    Text(row.branch).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                }
                .width(min: 90, ideal: 130)

                TableColumn("Status", value: \.statusRank) { row in
                    Text(row.status).foregroundStyle(row.statusRank > 0 ? .primary : .secondary).help(row.status)
                }
                .width(min: 120, ideal: 230)

                TableColumn("Last pulled", value: \.lastPulledSort) { row in
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(RelativeTime.ago(row.lastPulled, now: context.date)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .width(min: 80, ideal: 100)

                TableColumn("Worktrees", value: \.worktrees, comparator: .localizedStandard) { row in
                    Text(row.worktrees).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).help(row.worktrees)
                }
                .width(min: 80, ideal: 160)
            }
            .contextMenu(forSelectionType: String.self) { names in
                if let name = names.first, let row = all.first(where: { $0.name == name }) {
                    Button("Open in Terminal") { model.openInTerminal(row.path) }
                    Button("Show in Finder") { model.showInFinder(row.path) }
                    Button("Copy path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(row.path, forType: .string)
                    }
                    Divider()
                    if model.exclusions.containsRepo(row.name) {
                        Button("Include") { model.unexclude(row.name) }
                    } else {
                        Button("Exclude") { model.exclude(row.name) }
                    }
                }
            } primaryAction: { names in
                if let name = names.first, let row = all.first(where: { $0.name == name }) {
                    model.openInTerminal(row.path)
                }
            }

            HStack {
                Text(footerText(shown: shown.count, total: all.count))
                Spacer()
                Text("Double-click a repo to open it in Terminal")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
        }
        .frame(minWidth: 620, minHeight: 320)
        .onAppear { model.refreshLive() }
    }

    private var rows: [RepoTableRow] {
        model.live.map { repo in
            let status = model.status(for: repo.name)
            let (text, rank, mark) = model.exclusions.containsRepo(repo.name) ? ("Excluded", 0, nil) : describe(status?.outcome)
            return RepoTableRow(
                name: repo.name,
                path: repo.path,
                branch: repo.branch,
                status: text,
                statusRank: rank,
                mark: mark,
                lastPulled: status?.lastPulled,
                worktrees: repo.worktrees.map(\.branch).joined(separator: ", "),
                isOffDefault: repo.isOffDefault
            )
        }
    }

    private func filtered(_ rows: [RepoTableRow]) -> [RepoTableRow] {
        let scoped: [RepoTableRow]
        switch scope {
        case .all: scoped = rows
        case .notPulled: scoped = rows.filter { $0.statusRank > 0 }
        case .offMain: scoped = rows.filter(\.isOffDefault)
        }
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return scoped }
        return scoped.filter {
            $0.name.localizedCaseInsensitiveContains(needle)
                || $0.branch.localizedCaseInsensitiveContains(needle)
                || $0.worktrees.localizedCaseInsensitiveContains(needle)
        }
    }

    private func describe(_ outcome: RepoOutcome?) -> (String, Int, Color?) {
        switch outcome {
        case nil: return ("Not synced yet", 0, nil)
        case .current: return ("Current", 0, nil)
        case .pulled(let commits): return ("Pulled \(commits) \(commits == 1 ? "commit" : "commits")", 0, nil)
        case .skipped(let reason, let behind):
            return (behind > 0 ? "\(reason), \(behind) behind" : reason, 1, .orange)
        case .failed(let reason): return (reason, 2, .red)
        }
    }

    private func footerText(shown: Int, total: Int) -> String {
        shown == total ? "\(total) repos" : "Showing \(shown) of \(total) repos"
    }
}

@MainActor
enum ReposWindow {
    private static var window: NSWindow?

    static func show(model: AppModel) {
        if window == nil {
            let hosting = NSHostingController(rootView: ReposView().environmentObject(model))
            // Only the minimum size, so the resizable window never chases SwiftUI's preferred size (see OnboardingWindow).
            hosting.sizingOptions = [.minSize]
            let newWindow = NSWindow(contentViewController: hosting)
            newWindow.title = "Repos"
            newWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            newWindow.isReleasedWhenClosed = false
            newWindow.setContentSize(NSSize(width: 820, height: 560))
            newWindow.center()
            newWindow.setFrameAutosaveName("ReposWindow")
            window = newWindow
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
