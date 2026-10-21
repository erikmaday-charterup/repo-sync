import Foundation

struct CloneBookkeeping: Equatable {
    let knownRepos: Set<String>?
    let pendingDeletions: [String]

    // `known`, `exclusions` and `pending` are the current values, so choices made while the run was in flight win over the plan.
    static func apply(
        result: CloneStepResult,
        present: Set<String>,
        known: Set<String>?,
        exclusions: Set<String>,
        pending: [String]
    ) -> CloneBookkeeping {
        let stillPending = result.deleted.filter { known?.containsRepo($0) == true && !exclusions.containsRepo($0) }
        let updatedKnown = result.listed || known != nil
            ? (known ?? []).unionRepos(present).unionRepos(result.cloned)
            : known
        return CloneBookkeeping(
            knownRepos: updatedKnown,
            pendingDeletions: result.listed ? stillPending.sorted() : pending
        )
    }
}

struct FollowUpSync {
    private var requested = false

    // Returns true when the caller should start a sync now.
    mutating func request(whileSyncing isSyncing: Bool) -> Bool {
        if isSyncing {
            requested = true
            return false
        }
        return true
    }

    // Returns true when a sync was requested during the one that just finished.
    mutating func finishSync() -> Bool {
        defer { requested = false }
        return requested
    }
}

struct CloneActivity: Equatable {
    enum State: Equatable {
        case cloning, cloned, failed
    }

    struct Item: Equatable, Identifiable {
        let name: String
        var state: State
        var id: String { name }
    }

    private(set) var total = 0
    private(set) var items: [Item] = []

    var current: String? { items.last { $0.state == .cloning }?.name }
    var finishedCount: Int { items.filter { $0.state != .cloning }.count }
    var failedCount: Int { items.filter { $0.state == .failed }.count }

    mutating func begin(total: Int) {
        self.total = total
        items = []
    }

    mutating func started(_ name: String) {
        items.append(Item(name: name, state: .cloning))
    }

    mutating func finished(_ name: String, outcome: CloneOutcome) {
        guard let index = items.firstIndex(where: { $0.name == name }) else { return }
        if case .failed = outcome { items[index].state = .failed } else { items[index].state = .cloned }
    }
}
