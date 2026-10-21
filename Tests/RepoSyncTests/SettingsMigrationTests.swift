import XCTest
@testable import RepoSync

final class SettingsMigrationTests: XCTestCase {
    private var domains: [String] = []

    override func tearDown() {
        for domain in domains { UserDefaults.standard.removePersistentDomain(forName: domain) }
        domains = []
        super.tearDown()
    }

    private func makeSuite(_ label: String) -> (defaults: UserDefaults, domain: String) {
        let domain = "reposync.tests.\(label).\(UUID().uuidString)"
        domains.append(domain)
        let defaults = UserDefaults(suiteName: domain)!
        defaults.removePersistentDomain(forName: domain)
        return (defaults, domain)
    }

    private func seedLegacy(_ legacy: UserDefaults) {
        legacy.set("/Users/someone/Code", forKey: "folderPath")
        legacy.set("organizations", forKey: "repoFilter")
        legacy.set("acme", forKey: "organizations")
        legacy.set(30, forKey: "intervalMinutes")
        legacy.set(["acme", "other"], forKey: "cloneOrgs")
        legacy.set(["acme/skipped"], forKey: "exclusions")
        legacy.set(true, forKey: "launchedBefore")
        legacy.set(true, forKey: "onboardingDismissed")
        legacy.set(Date(timeIntervalSince1970: 1_700_000_000), forKey: "lastUpdateCheck")
    }

    func testLegacyDomainIsTheOldBundleIdentifier() {
        XCTAssertEqual(SettingsMigration.legacyDomain, "com.charterup.RepoSync")
    }

    func testCopiesEveryLegacyKeyWhenNewDomainIsEmpty() {
        let old = makeSuite("old")
        let new = makeSuite("new")
        seedLegacy(old.defaults)

        let migrated = SettingsMigration.run(defaults: new.defaults, domain: new.domain, legacyDomain: old.domain)

        XCTAssertTrue(migrated)
        XCTAssertEqual(new.defaults.string(forKey: "folderPath"), "/Users/someone/Code")
        XCTAssertEqual(new.defaults.string(forKey: "repoFilter"), "organizations")
        XCTAssertEqual(new.defaults.string(forKey: "organizations"), "acme")
        XCTAssertEqual(new.defaults.integer(forKey: "intervalMinutes"), 30)
        XCTAssertEqual(new.defaults.stringArray(forKey: "cloneOrgs"), ["acme", "other"])
        XCTAssertEqual(new.defaults.stringArray(forKey: "exclusions"), ["acme/skipped"])
        XCTAssertTrue(new.defaults.bool(forKey: "launchedBefore"))
        XCTAssertTrue(new.defaults.bool(forKey: "onboardingDismissed"))
        XCTAssertEqual(new.defaults.object(forKey: "lastUpdateCheck") as? Date, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testLeavesTheLegacyDomainUntouched() {
        let old = makeSuite("old")
        let new = makeSuite("new")
        seedLegacy(old.defaults)
        let before = old.defaults.persistentDomain(forName: old.domain) as NSDictionary?

        SettingsMigration.run(defaults: new.defaults, domain: new.domain, legacyDomain: old.domain)

        XCTAssertEqual(old.defaults.persistentDomain(forName: old.domain) as NSDictionary?, before)
    }

    func testDoesNothingWhenNewDomainAlreadyHasSettings() {
        let old = makeSuite("old")
        let new = makeSuite("new")
        seedLegacy(old.defaults)
        new.defaults.set("/Users/someone/Elsewhere", forKey: "folderPath")

        let migrated = SettingsMigration.run(defaults: new.defaults, domain: new.domain, legacyDomain: old.domain)

        XCTAssertFalse(migrated)
        XCTAssertEqual(new.defaults.string(forKey: "folderPath"), "/Users/someone/Elsewhere")
        XCTAssertNil(new.defaults.string(forKey: "organizations"))
    }

    func testDoesNothingWhenLegacyDomainIsEmpty() {
        let old = makeSuite("old")
        let new = makeSuite("new")

        let migrated = SettingsMigration.run(defaults: new.defaults, domain: new.domain, legacyDomain: old.domain)

        XCTAssertFalse(migrated)
        XCTAssertNil(new.defaults.persistentDomain(forName: new.domain))
    }

    func testRunsOnlyOnce() {
        let old = makeSuite("old")
        let new = makeSuite("new")
        seedLegacy(old.defaults)
        XCTAssertTrue(SettingsMigration.run(defaults: new.defaults, domain: new.domain, legacyDomain: old.domain))
        new.defaults.set("/Users/someone/Moved", forKey: "folderPath")
        old.defaults.set("/Users/someone/ChangedLater", forKey: "folderPath")

        let migratedAgain = SettingsMigration.run(defaults: new.defaults, domain: new.domain, legacyDomain: old.domain)

        XCTAssertFalse(migratedAgain)
        XCTAssertEqual(new.defaults.string(forKey: "folderPath"), "/Users/someone/Moved")
    }
}
