import Foundation

// Mac folders are case-insensitive by default, so "Foo" on GitHub and a "foo" folder are the same repo.
enum RepoName {
    static func key(_ name: String) -> String {
        name.lowercased()
    }

    static func keys<Names: Sequence>(_ names: Names) -> Set<String> where Names.Element == String {
        Set(names.map(key))
    }
}

extension Set where Element == String {
    func containsRepo(_ name: String) -> Bool {
        contains(name) || contains { RepoName.key($0) == RepoName.key(name) }
    }

    mutating func removeRepo(_ name: String) {
        self = filter { RepoName.key($0) != RepoName.key(name) }
    }

    // Keeps the spelling already here when a name differs only by case.
    func unionRepos<Names: Sequence>(_ names: Names) -> Set<String> where Names.Element == String {
        var result = self
        var keys = RepoName.keys(self)
        for name in names where keys.insert(RepoName.key(name)).inserted {
            result.insert(name)
        }
        return result
    }
}

extension Array where Element == String {
    func containsRepo(_ name: String) -> Bool {
        contains { RepoName.key($0) == RepoName.key(name) }
    }

    mutating func removeRepo(_ name: String) {
        removeAll { RepoName.key($0) == RepoName.key(name) }
    }
}
