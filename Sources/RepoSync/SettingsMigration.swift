import Foundation

enum SettingsMigration {
    static let legacyDomain = "com.charterup.RepoSync"

    // Copies the old bundle identifier's settings once, and only while the new domain holds none of those keys.
    @discardableResult
    static func run(defaults: UserDefaults, domain: String, legacyDomain: String = SettingsMigration.legacyDomain) -> Bool {
        guard let legacy = defaults.persistentDomain(forName: legacyDomain), !legacy.isEmpty else { return false }
        let current = defaults.persistentDomain(forName: domain) ?? [:]
        guard legacy.keys.allSatisfy({ current[$0] == nil }) else { return false }
        for (key, value) in legacy { defaults.set(value, forKey: key) }
        return true
    }
}
