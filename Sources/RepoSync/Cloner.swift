import Foundation

enum CloneOutcome: Equatable {
    case cloned
    case alreadyExists
    case failed(String)
}

enum Cloner {
    static let inProgressSuffix = ".reposync-cloning"
    private static let cloneTimeout: TimeInterval = 1800
    private static let receivingPrefix = "Receiving objects:"
    static let missingFolderMessage = "The repos folder is missing"

    static func isInProgressClone(_ folderName: String) -> Bool {
        folderName.hasPrefix(".") && folderName.hasSuffix(inProgressSuffix)
    }

    static func clone(_ repo: GitHubRepo, into folder: URL, progress: ((Int) -> Void)? = nil) async -> CloneOutcome {
        let fm = FileManager.default
        let destination = folder.appendingPathComponent(repo.name)
        // attributesOfItem does not follow symlinks, so a dangling link still counts as existing.
        if (try? fm.attributesOfItem(atPath: destination.path)) != nil { return .alreadyExists }

        // A missing folder was moved, renamed or unmounted, so recreating it would clone into the wrong place.
        guard CloneStep.directoryExists(folder) else { return .failed(missingFolderMessage) }

        let partial = folder.appendingPathComponent(".\(repo.name)\(inProgressSuffix)")
        do {
            if (try? fm.attributesOfItem(atPath: partial.path)) != nil { try fm.removeItem(at: partial) }
        } catch {
            return .failed(error.localizedDescription)
        }

        let result = await Git.run(["clone", "--progress", repo.cloneURL.absoluteString, partial.path], in: folder, timeout: cloneTimeout)
        guard result.ok else {
            try? fm.removeItem(at: partial)
            return .failed(result.timedOut ? "Clone timed out" : SyncEngine.firstLine(failureMessage(result.stderr)))
        }

        if let percent = lastReceivingPercent(in: result.stderr) { progress?(percent) }

        do {
            try fm.moveItem(at: partial, to: destination)
        } catch {
            try? fm.removeItem(at: partial)
            return .failed(error.localizedDescription)
        }
        return .cloned
    }

    // Progress lines are carriage-return separated, so they must not be mistaken for the error line.
    private static func failureMessage(_ stderr: String) -> String {
        stderr.split(whereSeparator: { $0 == "\r" || $0 == "\n" })
            .filter { !$0.hasPrefix("Cloning into") && !$0.contains("objects:") }
            .joined(separator: "\n")
    }

    static func lastReceivingPercent(in stderr: String) -> Int? {
        stderr.split(whereSeparator: { $0 == "\r" || $0 == "\n" })
            .compactMap { line -> Int? in
                guard line.hasPrefix(receivingPrefix) else { return nil }
                let digits = line.dropFirst(receivingPrefix.count).drop { $0 == " " }.prefix { $0.isNumber }
                return Int(digits)
            }
            .last
    }
}
