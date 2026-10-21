import XCTest
@testable import RepoSync

final class HistoryTests: XCTestCase {
    private func run(cloned: [String] = [], pulled: [String] = [], skipped: [String] = []) -> SyncRun {
        SyncRun(
            started: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 5,
            trigger: .schedule,
            repoCount: 10,
            pulled: pulled.map { PulledRepo(name: $0, count: 1, commits: []) },
            skipped: skipped.map { SkippedRepo(name: $0, reason: "dirty", behind: 1) },
            cloned: cloned
        )
    }

    func testOldHistoryWithoutClonedDecodes() throws {
        let json = """
        [{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","started":720000000,"duration":8,"trigger":"schedule",
          "repoCount":78,"pulled":[],"skipped":[],"failed":[]}]
        """

        let runs = try JSONDecoder().decode([SyncRun].self, from: Data(json.utf8))

        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].cloned, [])
        XCTAssertEqual(runs[0].repoCount, 78)
    }

    func testClonedSurvivesEncodeAndDecode() throws {
        let original = run(cloned: ["a", "b"])

        let decoded = try JSONDecoder().decode(SyncRun.self, from: JSONEncoder().encode(original))

        XCTAssertEqual(decoded.cloned, ["a", "b"])
        XCTAssertEqual(decoded.id, original.id)
    }

    func testSummaryIncludesCloned() {
        XCTAssertEqual(run(cloned: ["a", "b"], pulled: ["c"]).summary, "2 cloned, 1 pulled")
    }

    func testClonedRunIsNotable() {
        XCTAssertTrue(run(cloned: ["a"]).isNotable(after: nil))
        XCTAssertFalse(run().isNotable(after: nil))
    }
}
