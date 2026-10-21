import Foundation

struct GitInstallation: Equatable {
    let version: String?
}

enum GitInstall {
    private static let xcodeSelect = URL(fileURLWithPath: "/usr/bin/xcode-select")
    private static let checkTimeout: TimeInterval = 15
    private static let versionPrefix = "git version "

    static func isInstalled() async -> Bool {
        await installation() != nil
    }

    // Without the command line tools, /usr/bin/git is a stub that pops the install dialog, so check xcode-select first.
    static func installation() async -> GitInstallation? {
        guard await run(xcodeSelect, ["-p"]).ok else { return nil }
        let git = await run(Git.executable, ["--version"])
        guard git.ok else { return nil }
        return GitInstallation(version: displayVersion(from: git.stdout))
    }

    static func requestInstall() {
        let process = Process()
        process.executableURL = xcodeSelect
        process.arguments = ["--install"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    static func displayVersion(from output: String) -> String? {
        guard let line = output.split(whereSeparator: \.isNewline).first, line.hasPrefix(versionPrefix) else { return nil }
        let number = line.dropFirst(versionPrefix.count).prefix { !$0.isWhitespace }
        let parts = number.split(separator: ".").prefix(2)
        guard parts.count == 2, parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        return parts.joined(separator: ".")
    }

    private static func run(_ executable: URL, _ arguments: [String]) async -> CommandResult {
        await Subprocess.run(executable, arguments, environment: Git.environment, timeout: checkTimeout)
    }
}
