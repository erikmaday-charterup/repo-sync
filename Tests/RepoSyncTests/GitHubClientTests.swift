import XCTest
@testable import RepoSync

private final class StubTransport {
    struct Stub {
        var status: Int = 200
        var body: Data
        var headers: [String: String] = [:]
    }

    private var stubs: [String: Stub] = [:]
    private(set) var requests: [URLRequest] = []

    func stub(_ url: String, fixture: String, status: Int = 200, headers: [String: String] = [:]) throws {
        stubs[url] = Stub(status: status, body: try Self.fixtureData(fixture), headers: headers)
    }

    func stub(_ url: String, body: Data, status: Int = 200, headers: [String: String] = [:]) {
        stubs[url] = Stub(status: status, body: body, headers: headers)
    }

    static func fixtureData(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    var transport: HTTPTransport {
        { [self] request in
            requests.append(request)
            let key = request.url?.absoluteString ?? ""
            guard let stub = stubs[key] else { throw URLError(.unsupportedURL) }
            let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: nil, headerFields: stub.headers)!
            return (stub.body, response)
        }
    }
}

final class GitHubClientTests: XCTestCase {
    private let reposURL = "https://api.github.com/orgs/test-org/repos?per_page=100&type=all"
    private let reposPage2URL = "https://api.github.com/organizations/1/repos?per_page=100&type=all&page=2"

    private var stub: StubTransport!
    private var destination: URL!

    override func setUp() {
        stub = StubTransport()
        destination = FileManager.default.temporaryDirectory.appendingPathComponent("GitHubClientTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: destination)
    }

    private func client(token: String? = "gho_test") -> GitHubClient {
        GitHubClient(token: token, transport: stub.transport)
    }

    private func repoPageOneJSON() throws -> Data {
        let repos: [[String: Any]] = (1...100).map { index in
            ["name": "repo-\(index)", "clone_url": "https://github.com/test-org/repo-\(index).git",
             "size": index, "archived": false, "owner": ["login": "test-org"]]
        }
        return try JSONSerialization.data(withJSONObject: repos)
    }

    private func stubRepoPages() throws {
        stub.stub(reposURL, body: try repoPageOneJSON(), headers: ["Link": "<\(reposPage2URL)>; rel=\"next\", <\(reposPage2URL)>; rel=\"last\""])
        try stub.stub(reposPage2URL, fixture: "repos_page2")
    }

    func testUserParsesLogin() async throws {
        try stub.stub("https://api.github.com/user", fixture: "user")
        let user = try await client().user()
        XCTAssertEqual(user.login, "octocat")
    }

    func testOrganizationsReadsMembershipLogins() async throws {
        try stub.stub("https://api.github.com/user/memberships/orgs?state=active", fixture: "memberships")
        let organizations = try await client().organizations()
        XCTAssertEqual(organizations, ["example-org", "another-org"])
    }

    func testReposFollowsPagination() async throws {
        try stubRepoPages()
        let repos = try await client().repos(org: "test-org")
        XCTAssertEqual(repos.count, 103)
        XCTAssertEqual(stub.requests.map { $0.url?.absoluteString }, [reposURL, reposPage2URL])
    }

    func testReposMapsArchivedAndSize() async throws {
        try stubRepoPages()
        let repos = try await client().repos(org: "test-org")
        let legacy = try XCTUnwrap(repos.first { $0.name == "legacy" })
        XCTAssertTrue(legacy.archived)
        XCTAssertEqual(legacy.cloneURL, URL(string: "https://github.com/test-org/legacy.git"))
        XCTAssertEqual(legacy.owner, "test-org")
        let beta = try XCTUnwrap(repos.first { $0.name == "beta" })
        XCTAssertFalse(beta.archived)
        XCTAssertEqual(beta.sizeKB, 512000)
    }

    func test401MapsToUnauthorized() async throws {
        let bad = Data(#"{"message":"Bad credentials"}"#.utf8)
        let urls = [
            "https://api.github.com/user",
            "https://api.github.com/user/memberships/orgs?state=active",
            reposURL,
            "https://api.github.com/repos/o/r/releases/latest",
            "https://api.github.com/repos/o/r/releases/assets/7",
        ]
        for url in urls { stub.stub(url, body: bad, status: 401) }
        let client = client()
        await assertUnauthorized { _ = try await client.user() }
        await assertUnauthorized { _ = try await client.organizations() }
        await assertUnauthorized { _ = try await client.repos(org: "test-org") }
        await assertUnauthorized { _ = try await client.latestRelease(owner: "o", repo: "r") }
        await assertUnauthorized { try await client.downloadAsset(owner: "o", repo: "r", id: 7, to: self.destination) }
    }

    func testOtherStatusesMapToNotFoundAndHTTP() async throws {
        stub.stub("https://api.github.com/user", body: Data(), status: 500)
        stub.stub("https://api.github.com/repos/o/r/releases/latest", body: Data(), status: 404)
        do {
            _ = try await client().user()
            XCTFail("expected http error")
        } catch let error as GitHubError {
            XCTAssertEqual(error, .http(500))
        }
        do {
            _ = try await client().latestRelease(owner: "o", repo: "r")
            XCTFail("expected not found")
        } catch let error as GitHubError {
            XCTAssertEqual(error, .notFound)
        }
    }

    func testLatestReleasePicksZipAsset() async throws {
        try stub.stub("https://api.github.com/repos/erikmaday-charterup/repo-sync/releases/latest", fixture: "latest_release")
        let release = try await client().latestRelease(owner: "erikmaday-charterup", repo: "repo-sync")
        XCTAssertEqual(release.tag, "v1.2.0")
        XCTAssertEqual(release.htmlURL, URL(string: "https://github.com/erikmaday-charterup/repo-sync/releases/tag/v1.2.0"))
        XCTAssertEqual(release.zipAssetID, 202)
    }

    func testLatestReleaseWithoutZipHasNoAssetID() async throws {
        stub.stub("https://api.github.com/repos/o/r/releases/latest",
                  body: Data(#"{"tag_name":"v1","html_url":"https://github.com/o/r/releases/tag/v1","assets":[{"id":1,"name":"a.dmg"}]}"#.utf8))
        let release = try await client().latestRelease(owner: "o", repo: "r")
        XCTAssertNil(release.zipAssetID)
    }

    func testDownloadAssetWritesBodyWithOctetStreamAccept() async throws {
        let payload = Data([0x50, 0x4B, 0x03, 0x04, 0x01, 0x02])
        stub.stub("https://api.github.com/repos/o/r/releases/assets/202", body: payload)
        try await client().downloadAsset(owner: "o", repo: "r", id: 202, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/octet-stream")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer gho_test")
    }

    func testRequestsCarryBearerToken() async throws {
        try stub.stub("https://api.github.com/user", fixture: "user")
        _ = try await client(token: "gho_secret").user()
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer gho_secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
    }

    func testRequestsWithoutTokenOmitAuthorization() async throws {
        try stub.stub("https://api.github.com/user", fixture: "user")
        _ = try await client(token: nil).user()
        XCTAssertNil(stub.requests.first?.value(forHTTPHeaderField: "Authorization"))
    }

    private func assertUnauthorized(_ call: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await call()
            XCTFail("expected unauthorized", file: file, line: line)
        } catch let error as GitHubError {
            XCTAssertEqual(error, .unauthorized, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    func testRedirectToAnotherHostDropsTheAuthorizationHeader() throws {
        let original = try XCTUnwrap(URL(string: "https://api.github.com/repos/o/r/releases/assets/1"))
        var redirect = URLRequest(url: try XCTUnwrap(URL(string: "https://objects.githubusercontent.com/signed?sig=abc")))
        redirect.setValue("Bearer gho_test", forHTTPHeaderField: "Authorization")
        redirect.setValue("application/octet-stream", forHTTPHeaderField: "Accept")

        let followed = RedirectPolicy.request(redirect, redirectedFrom: original)

        XCTAssertNil(followed.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(followed.value(forHTTPHeaderField: "Accept"), "application/octet-stream")
    }

    func testRedirectOnTheSameHostKeepsTheAuthorizationHeader() throws {
        let original = try XCTUnwrap(URL(string: "https://api.github.com/orgs/old-name/repos"))
        var redirect = URLRequest(url: try XCTUnwrap(URL(string: "https://API.github.com/organizations/1/repos")))
        redirect.setValue("Bearer gho_test", forHTTPHeaderField: "Authorization")

        let followed = RedirectPolicy.request(redirect, redirectedFrom: original)

        XCTAssertEqual(followed.value(forHTTPHeaderField: "Authorization"), "Bearer gho_test")
    }
}
