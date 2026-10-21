import AppKit

struct Version: Comparable, CustomStringConvertible {
    private static let maxComponents = 3
    private static let prefix = "v"

    let major: Int
    let minor: Int
    let patch: Int

    init?(_ string: String) {
        let numeric = string.hasPrefix(Self.prefix) ? String(string.dropFirst(Self.prefix.count)) : string
        let parts = numeric.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...Self.maxComponents).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count else { return nil }
        major = numbers[0]
        minor = numbers.count > 1 ? numbers[1] : 0
        patch = numbers.count > 2 ? numbers[2] : 0
    }

    static func < (lhs: Version, rhs: Version) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    var description: String { "\(major).\(minor).\(patch)" }
}

enum UpdateCheck {
    case upToDate
    case available(version: Version, release: Release)
}

enum UpdateError: Error, Equatable {
    case wrongBundle
    case notNewer
    case notWritable(releasePage: URL)
}

struct Updater {
    static let owner = "erikmaday-charterup"
    static let repo = "repo-sync"
    static let checkInterval: TimeInterval = 24 * 60 * 60

    private static let bundleIdentifier = "com.erikmaday.RepoSync"
    private static let identifierKey = "CFBundleIdentifier"
    private static let shortVersionKey = "CFBundleShortVersionString"
    private static let infoPlistPath = "Contents/Info.plist"
    private static let stagingBundleName = "Repo Sync (updating).app"
    private static let backupBundleName = "Repo Sync (previous).app"
    private static let exitPollSeconds = "0.2"

    let current: Version
    let client: GitHubClient
    var relaunch: (URL) throws -> Void = Updater.relaunchApp
    var terminate: () -> Void = Updater.terminateApp

    static func currentVersion(of bundle: Bundle = .main) -> Version? {
        (bundle.object(forInfoDictionaryKey: shortVersionKey) as? String).flatMap(Version.init)
    }

    static func isCheckDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        let elapsed = now.timeIntervalSince(lastCheck)
        return elapsed < 0 || elapsed >= checkInterval
    }

    func check() async throws -> UpdateCheck {
        let release = try await client.latestRelease(owner: Self.owner, repo: Self.repo)
        guard let version = Version(release.tag) else { throw GitHubError.malformed }
        // A release still uploading its zip, or published without one, has nothing to install yet.
        guard release.zipAssetID != nil else { return .upToDate }
        return version > current ? .available(version: version, release: release) : .upToDate
    }

    func install(_ release: Release, appURL: URL) async throws {
        let fileManager = FileManager.default
        let parent = appURL.deletingLastPathComponent()
        // Moving the bundle needs write access to the bundle directory itself as well as its parent.
        guard fileManager.isWritableFile(atPath: parent.path), fileManager.isWritableFile(atPath: appURL.path) else {
            throw UpdateError.notWritable(releasePage: release.htmlURL)
        }
        guard let assetID = release.zipAssetID else { throw GitHubError.notFound }

        let workFolder = fileManager.temporaryDirectory.appendingPathComponent("RepoSyncUpdate-\(UUID().uuidString)", isDirectory: true)
        let extracted = workFolder.appendingPathComponent("extracted", isDirectory: true)
        try fileManager.createDirectory(at: extracted, withIntermediateDirectories: true)
        var keepWorkFolder = false
        defer { if !keepWorkFolder { try? fileManager.removeItem(at: workFolder) } }

        let zip = workFolder.appendingPathComponent("update.zip")
        try await client.downloadAsset(owner: Self.owner, repo: Self.repo, id: assetID, to: zip)
        try AppLocation.run(AppLocation.dittoPath, ["-x", "-k", zip.path, extracted.path])

        let newBundle = extracted.appendingPathComponent(AppLocation.appBundleName, isDirectory: true)
        let info = try Self.infoDictionary(of: newBundle)
        guard info[Self.identifierKey] as? String == Self.bundleIdentifier else { throw UpdateError.wrongBundle }
        guard let newVersion = (info[Self.shortVersionKey] as? String).flatMap(Version.init), newVersion > current else {
            throw UpdateError.notNewer
        }

        // Staged beside the running app so the final swap is a same-volume rename.
        let staged = parent.appendingPathComponent(Self.stagingBundleName, isDirectory: true)
        let backup = workFolder.appendingPathComponent(Self.backupBundleName, isDirectory: true)
        try? fileManager.removeItem(at: staged)
        try fileManager.moveItem(at: newBundle, to: staged)
        do {
            try fileManager.moveItem(at: appURL, to: backup)
        } catch {
            try? fileManager.removeItem(at: staged)
            throw error
        }
        do {
            try fileManager.moveItem(at: staged, to: appURL)
            try relaunch(appURL)
        } catch {
            try? fileManager.removeItem(at: staged)
            try? fileManager.removeItem(at: appURL)
            do {
                try fileManager.moveItem(at: backup, to: appURL)
            } catch {
                keepWorkFolder = true
            }
            throw error
        }
        terminate()
    }

    // Opening the new copy while this process is still alive would just bring the old one forward.
    static func relaunchCommand(for appURL: URL, waitingFor pid: Int32) -> String {
        let quoted = appURL.path.replacingOccurrences(of: "'", with: "'\\''")
        return "while kill -0 \(pid) 2>/dev/null; do sleep \(exitPollSeconds); done; open '\(quoted)'"
    }

    private static func infoDictionary(of bundle: URL) throws -> [String: Any] {
        let plistURL = bundle.appendingPathComponent(infoPlistPath)
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw UpdateError.wrongBundle
        }
        return plist
    }

    private static func relaunchApp(_ appURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", relaunchCommand(for: appURL, waitingFor: ProcessInfo.processInfo.processIdentifier)]
        try process.run()
    }

    private static func terminateApp() {
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
}
