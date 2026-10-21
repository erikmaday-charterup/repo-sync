import XCTest
@testable import RepoSync

final class AppLocationTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/someone")

    private func needsMove(_ path: String) -> Bool {
        AppLocation.needsMove(bundleURL: URL(fileURLWithPath: path), home: home)
    }

    func testInApplicationsNeedsNoMove() {
        XCTAssertFalse(needsMove("/Applications/Repo Sync.app"))
    }

    func testInHomeApplicationsNeedsNoMove() {
        XCTAssertFalse(needsMove("/Users/someone/Applications/Repo Sync.app"))
    }

    func testInDownloadsNeedsMove() {
        XCTAssertTrue(needsMove("/Users/someone/Downloads/Repo Sync.app"))
    }

    func testAnotherUsersApplicationsNeedsMove() {
        XCTAssertTrue(needsMove("/Users/other/Applications/Repo Sync.app"))
    }

    func testApplicationsLookalikeNeedsMove() {
        XCTAssertTrue(needsMove("/Applications Backup/Repo Sync.app"))
    }

    func testTranslocatedNeedsMove() {
        XCTAssertTrue(needsMove("/private/var/folders/ab/cd/T/AppTranslocation/6F3A9E52/d/Repo Sync.app"))
    }

    func testTranslocatedFromApplicationsNeedsMove() {
        XCTAssertTrue(needsMove("/Applications/AppTranslocation/6F3A9E52/d/Repo Sync.app"))
    }

    func testBareExecutableDirectoryNeedsNoMove() {
        XCTAssertFalse(needsMove("/Users/someone/Code/repo-sync/.build/debug"))
    }

    func testDestinationPrefersSystemApplicationsWhenWritable() {
        let destination = AppLocation.destination(systemWritable: true, home: home, installedInSystem: false, installedInHome: false)
        XCTAssertEqual(destination.path, "/Applications/Repo Sync.app")
    }

    func testDestinationFallsBackToHomeApplications() {
        let destination = AppLocation.destination(systemWritable: false, home: home, installedInSystem: false, installedInHome: false)
        XCTAssertEqual(destination.path, "/Users/someone/Applications/Repo Sync.app")
    }

    func testDestinationReplacesExistingCopyInHomeApplicationsEvenWhenSystemIsWritable() {
        let destination = AppLocation.destination(systemWritable: true, home: home, installedInSystem: false, installedInHome: true)
        XCTAssertEqual(destination.path, "/Users/someone/Applications/Repo Sync.app")
    }

    func testDestinationReplacesExistingCopyInSystemApplicationsEvenWhenNotWritable() {
        let destination = AppLocation.destination(systemWritable: false, home: home, installedInSystem: true, installedInHome: false)
        XCTAssertEqual(destination.path, "/Applications/Repo Sync.app")
    }

    func testDestinationPrefersSystemCopyWhenBothExist() {
        let destination = AppLocation.destination(systemWritable: false, home: home, installedInSystem: true, installedInHome: true)
        XCTAssertEqual(destination.path, "/Applications/Repo Sync.app")
    }

    func testOpenAtLoginIsNotDefaultedBeforeTheMove() {
        XCTAssertFalse(AppLocation.shouldDefaultOpenAtLogin(
            alreadyDefaulted: false, bundleURL: URL(fileURLWithPath: "/Users/someone/Downloads/Repo Sync.app"), home: home
        ))
    }

    func testOpenAtLoginIsDefaultedOnceFromApplications() {
        let installed = URL(fileURLWithPath: "/Applications/Repo Sync.app")
        XCTAssertTrue(AppLocation.shouldDefaultOpenAtLogin(alreadyDefaulted: false, bundleURL: installed, home: home))
        XCTAssertFalse(AppLocation.shouldDefaultOpenAtLogin(alreadyDefaulted: true, bundleURL: installed, home: home))
    }
}
