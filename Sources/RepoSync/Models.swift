import Foundation

struct RepoRef: Hashable {
    let name: String
    let url: URL
    let owner: String
    var excluded: Bool = false
    var usesHTTPS: Bool = true
}

enum RepoOutcome: Codable, Equatable {
    case current
    case pulled(commits: Int)
    case skipped(reason: String, behind: Int)
    case failed(reason: String)

    var needsAttention: Bool {
        switch self {
        case .current, .pulled: return false
        case .skipped, .failed: return true
        }
    }
}

struct RepoStatus: Codable, Identifiable {
    let name: String
    let path: String
    var outcome: RepoOutcome
    var lastPulled: Date?

    var id: String { name }
}

enum AccessState: Codable, Equatable {
    case unknown
    case working
    case refused(detail: String)
    case unreachable(detail: String)

    var isWorking: Bool { self == .working }
}

struct Worktree: Identifiable, Hashable {
    let path: String
    let branch: String

    var id: String { path }
    var folderName: String { URL(fileURLWithPath: path).lastPathComponent }

    var showsFolder: Bool {
        let shortBranch = branch.split(separator: "/").last.map(String.init) ?? branch
        return !folderName.localizedCaseInsensitiveContains(shortBranch)
    }
}

struct RepoLive: Identifiable {
    let name: String
    let path: String
    let branch: String
    let defaultBranch: String
    let worktrees: [Worktree]

    var id: String { name }
    var isOffDefault: Bool { branch != defaultBranch || !worktrees.isEmpty }
}

enum RepoFilter: String, CaseIterable, Identifiable {
    case allGitHub
    case organizations

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allGitHub: return "All GitHub repos"
        case .organizations: return "Only some organizations"
        }
    }
}

struct Commit: Codable, Hashable {
    let sha: String
    let subject: String
}

struct SyncResult {
    let outcome: RepoOutcome
    let commits: [Commit]
}

enum SyncTrigger: String, Codable {
    case schedule, manual
}

struct PulledRepo: Codable, Hashable {
    let name: String
    let count: Int
    let commits: [Commit]
}

struct SkippedRepo: Codable, Hashable {
    let name: String
    let reason: String
    let behind: Int
}

struct FailedRepo: Codable, Hashable {
    let name: String
    let reason: String
}

struct SyncRun: Codable, Identifiable {
    var id = UUID()
    let started: Date
    let duration: TimeInterval
    let trigger: SyncTrigger
    let repoCount: Int
    var stopped: String?
    var pulled: [PulledRepo] = []
    var skipped: [SkippedRepo] = []
    var failed: [FailedRepo] = []
    var cloned: [String] = []

    var summary: String {
        if let stopped { return stopped }
        var parts: [String] = []
        if !cloned.isEmpty { parts.append("\(cloned.count) cloned") }
        if !pulled.isEmpty { parts.append("\(pulled.count) pulled") }
        if !skipped.isEmpty { parts.append("\(skipped.count) skipped") }
        if !failed.isEmpty { parts.append("\(failed.count) failed") }
        return parts.isEmpty ? "No changes" : parts.joined(separator: ", ")
    }

    // A run is worth listing when something happened that the previous run didn't already show.
    func isNotable(after previous: SyncRun?) -> Bool {
        if stopped != nil || !cloned.isEmpty || !pulled.isEmpty || !failed.isEmpty { return true }
        return Set(skipped.map(\.name)) != Set(previous?.skipped.map(\.name) ?? [])
    }
}

extension SyncRun {
    private enum CodingKeys: String, CodingKey {
        case id, started, duration, trigger, repoCount, stopped, pulled, skipped, failed, cloned
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        started = try container.decode(Date.self, forKey: .started)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        trigger = try container.decode(SyncTrigger.self, forKey: .trigger)
        repoCount = try container.decode(Int.self, forKey: .repoCount)
        stopped = try container.decodeIfPresent(String.self, forKey: .stopped)
        pulled = try container.decode([PulledRepo].self, forKey: .pulled)
        skipped = try container.decode([SkippedRepo].self, forKey: .skipped)
        failed = try container.decode([FailedRepo].self, forKey: .failed)
        cloned = try container.decodeIfPresent([String].self, forKey: .cloned) ?? []
    }
}

enum Pane: Equatable {
    case main, history, run(UUID), settings
}

struct PersistedState: Codable {
    var lastSync: Date?
    var statuses: [RepoStatus]
    var access: AccessState
    var accessChecked: Date?
    var knownRepos: Set<String>?
    var pendingDeletions: [String] = []
}

extension PersistedState {
    private enum CodingKeys: String, CodingKey {
        case lastSync, statuses, access, accessChecked, knownRepos, pendingDeletions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastSync = try container.decodeIfPresent(Date.self, forKey: .lastSync)
        statuses = try container.decode([RepoStatus].self, forKey: .statuses)
        access = try container.decode(AccessState.self, forKey: .access)
        accessChecked = try container.decodeIfPresent(Date.self, forKey: .accessChecked)
        knownRepos = try container.decodeIfPresent(Set<String>.self, forKey: .knownRepos)
        pendingDeletions = try container.decodeIfPresent([String].self, forKey: .pendingDeletions) ?? []
    }
}
