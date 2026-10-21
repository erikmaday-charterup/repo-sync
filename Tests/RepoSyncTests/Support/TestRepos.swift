import Foundation
@testable import RepoSync

struct TestRepos {
    struct GitFailure: Error, CustomStringConvertible {
        let arguments: [String]
        let output: String
        var description: String { "git \(arguments.joined(separator: " ")) failed: \(output)" }
    }

    static let remoteURLPrefix = "https://github.com/test-org/"

    let root: URL
    let folder: URL
    let remotes: URL
    private let seeds: URL
    private let previousEnvironment: [String: String]

    static func makeSandbox() throws -> TestRepos {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("repo-sync-tests-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("code")
        let remotes = root.appendingPathComponent("remotes")
        let seeds = root.appendingPathComponent("seeds")
        for directory in [folder, remotes, seeds] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let config = """
        [user]
        \tname = Test
        \temail = test@example.com
        [init]
        \tdefaultBranch = main
        [url "\(remotes.path)/"]
        \tinsteadOf = \(remoteURLPrefix)

        """
        let configURL = root.appendingPathComponent("gitconfig")
        try config.write(to: configURL, atomically: true, encoding: .utf8)

        let previous = Git.environment
        Git.environment["GIT_CONFIG_GLOBAL"] = configURL.path
        Git.environment["GIT_CONFIG_NOSYSTEM"] = "1"
        return TestRepos(root: root, folder: folder, remotes: remotes, seeds: seeds, previousEnvironment: previous)
    }

    func makeRemote(_ name: String, commits: Int) throws {
        let bare = remotes.appendingPathComponent("\(name).git")
        let seed = seeds.appendingPathComponent(name)
        try git(["init", "-q", "--bare", "--initial-branch=main", bare.path], in: root)
        try git(["clone", "-q", bare.path, seed.path], in: root)
        try git(["commit", "-q", "--allow-empty", "-m", "first"], in: seed)
        for index in 1..<max(commits, 1) {
            try git(["commit", "-q", "--allow-empty", "-m", "seed \(index)"], in: seed)
        }
        try git(["push", "-q", "origin", "main"], in: seed)
    }

    func advance(_ name: String, by count: Int) throws {
        let seed = seeds.appendingPathComponent(name)
        for index in 1...count {
            try git(["commit", "-q", "--allow-empty", "-m", "remote \(index)"], in: seed)
        }
        try git(["push", "-q", "origin", "main"], in: seed)
    }

    @discardableResult
    func clone(_ name: String) throws -> URL {
        let destination = folder.appendingPathComponent(name)
        try git(["clone", "-q", "\(Self.remoteURLPrefix)\(name).git", destination.path], in: root)
        return destination
    }

    @discardableResult
    func git(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = Git.executable
        process.arguments = ["-C", directory.path] + arguments
        process.environment = Git.environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else { throw GitFailure(arguments: arguments, output: text) }
        return text
    }

    func cleanup() {
        Git.environment = previousEnvironment
        try? FileManager.default.removeItem(at: root)
    }
}
