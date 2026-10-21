import AppKit

enum AppLocation {
    enum MoveError: LocalizedError {
        case toolFailed(String, Int32)

        var errorDescription: String? {
            switch self {
            case .toolFailed(let tool, let status): return "\(tool) exited with status \(status)."
            }
        }
    }

    static let appBundleName = "Repo Sync.app"
    private static let applicationsFolderName = "Applications"
    private static let translocationMarker = "/AppTranslocation/"
    private static let quarantineAttribute = "com.apple.quarantine"
    private static let securityFrameworkPath = "/System/Library/Frameworks/Security.framework/Security"
    private static let translocationSymbol = "SecTranslocateCreateOriginalPathForURL"
    private static let stagingBundleName = "Repo Sync (installing).app"
    static let dittoPath = "/usr/bin/ditto"
    private static let xattrPath = "/usr/bin/xattr"
    private static let openPath = "/usr/bin/open"

    private static let systemApplications = URL(fileURLWithPath: "/Applications", isDirectory: true)

    private static func homeApplications(_ home: URL) -> URL {
        home.appendingPathComponent(applicationsFolderName, isDirectory: true)
    }

    static func needsMove(bundleURL: URL, home: URL) -> Bool {
        guard bundleURL.pathExtension == "app" else { return false }
        let path = bundleURL.standardizedFileURL.path
        if path.contains(translocationMarker) { return true }
        let installRoots = [systemApplications, homeApplications(home)].map { $0.standardizedFileURL.path + "/" }
        return !installRoots.contains { path.hasPrefix($0) }
    }

    // Registering from Downloads would point login at a copy that's about to be moved, so wait for the relaunch from Applications.
    static func shouldDefaultOpenAtLogin(alreadyDefaulted: Bool, bundleURL: URL, home: URL) -> Bool {
        !alreadyDefaulted && !needsMove(bundleURL: bundleURL, home: home)
    }

    static func destination(systemWritable: Bool, home: URL, installedInSystem: Bool, installedInHome: Bool) -> URL {
        let folder: URL
        if installedInSystem {
            folder = systemApplications
        } else if installedInHome {
            folder = homeApplications(home)
        } else {
            folder = systemWritable ? systemApplications : homeApplications(home)
        }
        return folder.appendingPathComponent(appBundleName, isDirectory: true)
    }

    // On success the app relaunches from the new copy and this call terminates the current process.
    @MainActor
    static func moveAndRelaunch() throws {
        let fileManager = FileManager.default
        let source = Bundle.main.bundleURL
        let home = fileManager.homeDirectoryForCurrentUser
        let target = destination(
            systemWritable: fileManager.isWritableFile(atPath: systemApplications.path),
            home: home,
            installedInSystem: fileManager.fileExists(atPath: systemApplications.appendingPathComponent(appBundleName).path),
            installedInHome: fileManager.fileExists(atPath: homeApplications(home).appendingPathComponent(appBundleName).path)
        )
        let folder = target.deletingLastPathComponent()
        let staging = folder.appendingPathComponent(stagingBundleName, isDirectory: true)

        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try? fileManager.removeItem(at: staging)
        do {
            try run(dittoPath, [source.path, staging.path])
            try run(xattrPath, ["-dr", quarantineAttribute, staging.path])
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.trashItem(at: target, resultingItemURL: nil)
            }
            try fileManager.moveItem(at: staging, to: target)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }

        // The copy is already in place, so a failure to trash the original doesn't block the relaunch.
        if let original = originalLocation(of: source), original.standardizedFileURL != target.standardizedFileURL {
            try? fileManager.trashItem(at: original, resultingItemURL: nil)
        }

        try run(openPath, ["-n", target.path])
        NSApp.terminate(nil)
    }

    private static func originalLocation(of bundleURL: URL) -> URL? {
        guard bundleURL.path.contains(translocationMarker) else { return bundleURL }
        return translocatedOriginal(of: bundleURL)
    }

    private typealias OriginalPathLookup = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?

    // Not in the public SDK headers, so it's looked up at runtime.
    private static func translocatedOriginal(of url: URL) -> URL? {
        guard let handle = dlopen(securityFrameworkPath, RTLD_LAZY),
              let symbol = dlsym(handle, translocationSymbol) else { return nil }
        let lookup = unsafeBitCast(symbol, to: OriginalPathLookup.self)
        var error: Unmanaged<CFError>?
        guard let original = lookup(url as CFURL, &error) else {
            error?.release()
            return nil
        }
        return original.takeRetainedValue() as URL
    }

    static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw MoveError.toolFailed(URL(fileURLWithPath: tool).lastPathComponent, process.terminationStatus)
        }
    }
}
