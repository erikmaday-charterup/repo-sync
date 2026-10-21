import Foundation

enum Preflight: Equatable {
    case folderMissing
    case nothingToCheck
    case checked(AccessState)
}

struct CloneStepSettings {
    let folder: URL?
    let cloneOrgs: [String]
    let known: Set<String>?
    let exclusions: Set<String>
    let pending: [String]
}

struct CloneRun {
    let result: CloneStepResult
    // nil when the folder changed or vanished mid-run, so known repos and deletions must stay as they are.
    let bookkeeping: CloneBookkeeping?
}

// The part of a sync that runs before pulling: folder and access checks, then cloning new org repos.
@MainActor
struct CloneStep {
    let settings: () -> CloneStepSettings
    let folderExists: (URL) -> Bool
    let folderEntries: (URL) -> Set<String>
    let checkAccess: () async -> AccessState?
    let readToken: () async -> String?
    let loginRejected: () -> Void
    let makeCoordinator: (_ token: String, _ folder: URL) -> CloneCoordinator
    let log: (String) -> Void

    nonisolated static func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func preflight() async -> Preflight {
        guard let folder = settings().folder, folderExists(folder) else { return .folderMissing }
        guard let state = await checkAccess() else { return .nothingToCheck }
        return .checked(state)
    }

    func cloneNewRepos(onStart: () -> Void = {}, progress: @escaping (Int, Int) -> Void = { _, _ in }) async -> CloneRun? {
        let initial = settings()
        guard let folder = initial.folder, !initial.cloneOrgs.isEmpty, folderExists(folder), let token = await readToken() else { return nil }
        let present = folderEntries(folder)

        onStart()
        let result = await makeCoordinator(token, folder).run(
            orgs: initial.cloneOrgs, present: present, known: initial.known, excluded: initial.exclusions, progress: progress
        )

        if result.tokenRevoked {
            log("GitHub rejected gh's login, so new repos weren't cloned")
            loginRejected()
            return CloneRun(result: result, bookkeeping: nil)
        }
        if !result.cloned.isEmpty { log("Cloned \(result.cloned.count) new repos: \(result.cloned.joined(separator: ", "))") }
        for failure in result.failed { log("Clone failed for \(failure.name): \(failure.reason)") }

        let current = settings()
        guard current.folder == folder, folderExists(folder) else {
            log("The repos folder changed or went missing while cloning, so deleted repos weren't checked")
            return CloneRun(result: result, bookkeeping: nil)
        }
        let bookkeeping = CloneBookkeeping.apply(
            result: result, present: present, known: current.known, exclusions: current.exclusions, pending: current.pending
        )
        return CloneRun(result: result, bookkeeping: bookkeeping)
    }
}
