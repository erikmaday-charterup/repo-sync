// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RepoSync",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "RepoSync", path: "Sources/RepoSync"),
        .testTarget(name: "RepoSyncTests", dependencies: ["RepoSync"], path: "Tests/RepoSyncTests", resources: [.copy("Fixtures")])
    ]
)
