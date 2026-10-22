import XCTest
@testable import RepoSync

private final class AssetTransport {
    private(set) var requests: [URLRequest] = []
    var releaseJSON = Data()
    var assetData = Data()

    var transport: HTTPTransport {
        { [self] request in
            requests.append(request)
            let url = request.url!
            let body = url.path.contains("/releases/assets/") ? assetData : releaseJSON
            return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }
}

final class UpdaterTests: XCTestCase {
    private let bundleID = "com.erikmaday.RepoSync"
    private let assetID = 4242

    private var root: URL!
    private var applications: URL!
    private var appURL: URL!
    private var stub: AssetTransport!
    private var relaunched: [URL] = []
    private var terminateCount = 0

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("UpdaterTests-\(UUID().uuidString)", isDirectory: true)
        applications = root.appendingPathComponent("Applications", isDirectory: true)
        appURL = applications.appendingPathComponent("Repo Sync.app", isDirectory: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        try makeBundle(at: appURL, identifier: bundleID, version: "1.0", marker: "old")
        stub = AssetTransport()
        relaunched = []
        terminateCount = 0
    }

    override func tearDown() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: applications.path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: appURL.path)
        try? FileManager.default.removeItem(at: root)
    }

    private func makeBundle(at url: URL, identifier: String, version: String, marker: String) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleShortVersionString": version,
            "CFBundleName": "Repo Sync"
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data(marker.utf8).write(to: contents.appendingPathComponent("marker.txt"))
    }

    private func zippedBundle(identifier: String, version: String, marker: String = "new") throws -> Data {
        let source = root.appendingPathComponent("zip-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let bundle = source.appendingPathComponent("Repo Sync.app", isDirectory: true)
        try makeBundle(at: bundle, identifier: identifier, version: version, marker: marker)
        let zip = root.appendingPathComponent("bundle-\(UUID().uuidString).zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", bundle.path, zip.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return try Data(contentsOf: zip)
    }

    private func releaseJSON(tag: String, assets: [[String: Any]]? = nil) throws -> Data {
        let assetList = assets ?? [["id": assetID, "name": "Repo-Sync.zip"]]
        let body: [String: Any] = [
            "tag_name": tag,
            "html_url": "https://github.com/erikmaday-charterup/repo-sync/releases/tag/\(tag)",
            "assets": assetList
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    private func updater(current: String = "1.0.0") throws -> Updater {
        Updater(
            current: try XCTUnwrap(Version(current)),
            client: GitHubClient(token: "gho_test", transport: stub.transport),
            relaunch: { [self] url in relaunched.append(url) },
            terminate: { [self] in terminateCount += 1 }
        )
    }

    private func release(tag: String = "v1.1.0", assetID: Int? = 4242) -> Release {
        Release(
            tag: tag,
            htmlURL: URL(string: "https://github.com/erikmaday-charterup/repo-sync/releases/tag/\(tag)")!,
            zipAssetID: assetID
        )
    }

    private func marker(of bundle: URL) -> String? {
        try? String(contentsOf: bundle.appendingPathComponent("Contents/marker.txt"), encoding: .utf8)
    }

    func testVersionParsingAndOrdering() throws {
        XCTAssertGreaterThan(try XCTUnwrap(Version("v1.10.0")), try XCTUnwrap(Version("1.9.9")))
        XCTAssertEqual(try XCTUnwrap(Version("1.0")), try XCTUnwrap(Version("1.0.0")))
        XCTAssertEqual(try XCTUnwrap(Version("v2")), try XCTUnwrap(Version("2.0.0")))
        XCTAssertLessThan(try XCTUnwrap(Version("1.0.9")), try XCTUnwrap(Version("1.1")))
        XCTAssertEqual(try XCTUnwrap(Version("v1.2.3")).description, "1.2.3")
        for invalid in ["", "v", "1.2.3.4", "1.x", "1..2", "1.2.3-beta", "latest", "V1.0", "vv1.0", " 1.0", "1.-2"] {
            XCTAssertNil(Version(invalid), "\(invalid) should not parse")
        }
    }

    func testCheckReportsNewerRelease() async throws {
        stub.releaseJSON = try releaseJSON(tag: "v1.1.0")
        let result = try await updater().check()
        guard case .available(let version, let release) = result else { return XCTFail("expected available, got \(result)") }
        XCTAssertEqual(version, Version("1.1.0"))
        XCTAssertEqual(release.tag, "v1.1.0")
        XCTAssertEqual(release.zipAssetID, assetID)
        XCTAssertEqual(
            stub.requests.first?.url?.absoluteString,
            "https://api.github.com/repos/erikmaday-charterup/repo-sync/releases/latest"
        )
    }

    func testCheckReportsUpToDateForSameVersion() async throws {
        stub.releaseJSON = try releaseJSON(tag: "v1.0.0")
        let result = try await updater(current: "1.0").check()
        guard case .upToDate = result else { return XCTFail("expected upToDate, got \(result)") }
    }

    func testCheckReportsUpToDateForOlderRelease() async throws {
        stub.releaseJSON = try releaseJSON(tag: "v0.9.0")
        let result = try await updater().check()
        guard case .upToDate = result else { return XCTFail("expected upToDate, got \(result)") }
    }

    func testCheckRejectsUnparsableTag() async throws {
        stub.releaseJSON = try releaseJSON(tag: "nightly")
        do {
            _ = try await updater().check()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? GitHubError, .malformed)
        }
    }

    func testCheckDueWhenNeverCheckedOrADayHasPassed() {
        let now = Date()
        XCTAssertTrue(Updater.isCheckDue(lastCheck: nil, now: now))
        XCTAssertTrue(Updater.isCheckDue(lastCheck: now.addingTimeInterval(-24 * 3600), now: now))
        XCTAssertFalse(Updater.isCheckDue(lastCheck: now.addingTimeInterval(-24 * 3600 + 1), now: now))
        XCTAssertFalse(Updater.isCheckDue(lastCheck: now, now: now))
    }

    func testCheckDueWhenClockMovedBackwards() {
        let now = Date()
        XCTAssertTrue(Updater.isCheckDue(lastCheck: now.addingTimeInterval(3600), now: now))
    }

    func testInstallRejectsWrongBundleID() async throws {
        stub.assetData = try zippedBundle(identifier: "com.example.Other", version: "1.1.0")
        do {
            try await updater().install(release(), appURL: appURL)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? UpdateError, .wrongBundle)
        }
        XCTAssertEqual(marker(of: appURL), "old")
        XCTAssertTrue(relaunched.isEmpty)
        XCTAssertEqual(terminateCount, 0)
    }

    func testInstallRejectsOlderVersion() async throws {
        stub.assetData = try zippedBundle(identifier: bundleID, version: "0.9.0")
        do {
            try await updater().install(release(tag: "v0.9.0"), appURL: appURL)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? UpdateError, .notNewer)
        }
        XCTAssertEqual(marker(of: appURL), "old")
        XCTAssertTrue(relaunched.isEmpty)
    }

    func testInstallRejectsSameVersion() async throws {
        stub.assetData = try zippedBundle(identifier: bundleID, version: "1.0.0")
        do {
            try await updater().install(release(tag: "v1.0.0"), appURL: appURL)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? UpdateError, .notNewer)
        }
    }

    func testInstallSwapsBundleInPlace() async throws {
        stub.assetData = try zippedBundle(identifier: bundleID, version: "1.1.0")
        try await updater().install(release(), appURL: appURL)

        XCTAssertEqual(marker(of: appURL), "new")
        XCTAssertEqual(relaunched, [appURL])
        XCTAssertEqual(terminateCount, 1)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: applications.path)
        XCTAssertEqual(leftovers, ["Repo Sync.app"])
        let request = try XCTUnwrap(stub.requests.last)
        XCTAssertEqual(request.url?.path, "/repos/erikmaday-charterup/repo-sync/releases/assets/\(assetID)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/octet-stream")
    }

    func testInstallRestoresBackupWhenRelaunchFails() async throws {
        stub.assetData = try zippedBundle(identifier: bundleID, version: "1.1.0")
        struct LaunchFailure: Error {}
        let failing = Updater(
            current: try XCTUnwrap(Version("1.0.0")),
            client: GitHubClient(token: "gho_test", transport: stub.transport),
            relaunch: { _ in throw LaunchFailure() },
            terminate: { [self] in terminateCount += 1 }
        )
        do {
            try await failing.install(release(), appURL: appURL)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error is LaunchFailure)
        }
        XCTAssertEqual(marker(of: appURL), "old")
        XCTAssertEqual(terminateCount, 0)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: applications.path)
        XCTAssertEqual(leftovers, ["Repo Sync.app"])
    }

    func testInstallThrowsNotWritableWithReleasePage() async throws {
        stub.assetData = try zippedBundle(identifier: bundleID, version: "1.1.0")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: applications.path)
        let target = release()
        do {
            try await updater().install(target, appURL: appURL)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? UpdateError, .notWritable(releasePage: target.htmlURL))
        }
        XCTAssertEqual(marker(of: appURL), "old")
        XCTAssertTrue(stub.requests.isEmpty)
        XCTAssertTrue(relaunched.isEmpty)
    }

    func testInstallThrowsNotWritableWhenBundleItselfIsReadOnly() async throws {
        stub.assetData = try zippedBundle(identifier: bundleID, version: "1.1.0")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: appURL.path)
        let target = release()
        do {
            try await updater().install(target, appURL: appURL)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? UpdateError, .notWritable(releasePage: target.htmlURL))
        }
        XCTAssertEqual(marker(of: appURL), "old")
        XCTAssertTrue(stub.requests.isEmpty)
        XCTAssertTrue(relaunched.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: applications.path), ["Repo Sync.app"])
    }

    func testRelaunchCommandWaitsForTheOldProcessAndQuotesThePath() {
        let url = URL(fileURLWithPath: "/Users/o'neil/Applications/Repo Sync.app")
        XCTAssertEqual(
            Updater.relaunchCommand(for: url, waitingFor: 4321),
            "while kill -0 4321 2>/dev/null; do sleep 0.2; done; open '/Users/o'\\''neil/Applications/Repo Sync.app'"
        )
    }

    func testCheckTreatsAReleaseWithoutAZipAsUpToDate() async throws {
        stub.releaseJSON = try releaseJSON(tag: "v1.1.0", assets: [["id": 7, "name": "notes.txt"]])
        let result = try await updater().check()
        guard case .upToDate = result else { return XCTFail("expected upToDate, got \(result)") }
    }
}
