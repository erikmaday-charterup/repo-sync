import XCTest
@testable import RepoSync

final class PersistedStateTests: XCTestCase {
    func testOldStateWithoutCloneFieldsDecodes() throws {
        let json = """
        {"statuses":[],"access":{"working":{}}}
        """

        let state = try JSONDecoder().decode(PersistedState.self, from: Data(json.utf8))

        XCTAssertNil(state.knownRepos)
        XCTAssertEqual(state.pendingDeletions, [])
    }

    func testCloneFieldsSurviveEncodeAndDecode() throws {
        let state = PersistedState(
            lastSync: nil, statuses: [], access: .working, accessChecked: nil,
            knownRepos: ["a", "b"], pendingDeletions: ["b"]
        )

        let decoded = try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(state))

        XCTAssertEqual(decoded.knownRepos, ["a", "b"])
        XCTAssertEqual(decoded.pendingDeletions, ["b"])
    }
}
