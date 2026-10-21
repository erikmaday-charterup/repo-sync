import Foundation

typealias HTTPTransport = (URLRequest) async throws -> (Data, HTTPURLResponse)

enum HTTPTransports {
    static let urlSession: HTTPTransport = { request in
        let (data, response) = try await URLSession.shared.data(for: request, delegate: RedirectPolicy.shared)
        guard let http = response as? HTTPURLResponse else { throw GitHubError.malformed }
        return (data, http)
    }
}

// Release downloads redirect to signed storage URLs, which reject a request that still carries the GitHub token.
final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
    static let shared = RedirectPolicy()
    private static let authorizationHeader = "Authorization"

    static func request(_ redirect: URLRequest, redirectedFrom original: URL?) -> URLRequest {
        let fromHost = original?.host?.lowercased()
        guard fromHost == nil || fromHost != redirect.url?.host?.lowercased() else { return redirect }
        var stripped = redirect
        stripped.setValue(nil, forHTTPHeaderField: authorizationHeader)
        return stripped
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(Self.request(request, redirectedFrom: task.originalRequest?.url))
    }
}

struct GitHubUser: Equatable {
    let login: String
}

struct GitHubRepo: Codable, Hashable {
    let name: String
    let cloneURL: URL
    let sizeKB: Int
    let archived: Bool
    let owner: String
}

struct Release: Equatable {
    let tag: String
    let htmlURL: URL
    let zipAssetID: Int?
}

enum GitHubError: Error, Equatable {
    case unauthorized
    case notFound
    case http(Int)
    case malformed
}

struct GitHubClient {
    private static let apiBase = "https://api.github.com"
    private static let apiVersion = "2022-11-28"
    private static let reposPageSize = 100
    private static let zipSuffix = ".zip"

    private let token: String?
    private let transport: HTTPTransport

    init(token: String?, transport: @escaping HTTPTransport = HTTPTransports.urlSession) {
        self.token = token
        self.transport = transport
    }

    func user() async throws -> GitHubUser {
        let (data, _) = try await send(apiRequest(path: "/user"))
        let wire: UserWire = try Self.decode(data)
        return GitHubUser(login: wire.login)
    }

    func organizations() async throws -> [String] {
        let (data, _) = try await send(apiRequest(path: "/user/memberships/orgs?state=active"))
        let memberships: [MembershipWire] = try Self.decode(data)
        return memberships.map(\.organization.login)
    }

    func repos(org: String) async throws -> [GitHubRepo] {
        var repos: [GitHubRepo] = []
        var next: URL? = URL(string: "\(Self.apiBase)/orgs/\(org)/repos?per_page=\(Self.reposPageSize)&type=all")
        while let url = next {
            let (data, response) = try await send(apiRequest(url: url))
            let page: [RepoWire] = try Self.decode(data)
            repos += page.map(\.repo)
            next = Self.nextPageURL(in: response)
        }
        return repos
    }

    func latestRelease(owner: String, repo: String) async throws -> Release {
        let (data, _) = try await send(apiRequest(path: "/repos/\(owner)/\(repo)/releases/latest"))
        let wire: ReleaseWire = try Self.decode(data)
        let zip = wire.assets.first { $0.name.hasSuffix(Self.zipSuffix) }
        return Release(tag: wire.tagName, htmlURL: wire.htmlURL, zipAssetID: zip?.id)
    }

    func downloadAsset(owner: String, repo: String, id: Int, to destination: URL) async throws {
        var request = try apiRequest(path: "/repos/\(owner)/\(repo)/releases/assets/\(id)")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let (data, _) = try await send(request)
        try data.write(to: destination, options: .atomic)
    }

    private func apiRequest(path: String) throws -> URLRequest {
        guard let url = URL(string: Self.apiBase + path) else { throw GitHubError.malformed }
        return apiRequest(url: url)
    }

    private func apiRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await transport(request)
        switch response.statusCode {
        case 200..<300: return (data, response)
        case 401: throw GitHubError.unauthorized
        case 404: throw GitHubError.notFound
        default: throw GitHubError.http(response.statusCode)
        }
    }

    private static func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw GitHubError.malformed
        }
    }

    private static func nextPageURL(in response: HTTPURLResponse) -> URL? {
        guard let link = response.value(forHTTPHeaderField: "Link") else { return nil }
        for part in link.split(separator: ",") {
            let pieces = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard pieces.count >= 2, pieces.dropFirst().contains("rel=\"next\""),
                  let target = pieces.first, target.hasPrefix("<"), target.hasSuffix(">") else { continue }
            return URL(string: String(target.dropFirst().dropLast()))
        }
        return nil
    }
}

private struct UserWire: Decodable {
    let login: String
}

private struct MembershipWire: Decodable {
    struct Organization: Decodable {
        let login: String
    }

    let organization: Organization
}

private struct RepoWire: Decodable {
    struct Owner: Decodable {
        let login: String
    }

    let name: String
    let cloneURL: URL
    let size: Int
    let archived: Bool
    let owner: Owner

    enum CodingKeys: String, CodingKey {
        case name
        case cloneURL = "clone_url"
        case size
        case archived
        case owner
    }

    var repo: GitHubRepo {
        GitHubRepo(name: name, cloneURL: cloneURL, sizeKB: size, archived: archived, owner: owner.login)
    }
}

private struct ReleaseWire: Decodable {
    struct Asset: Decodable {
        let id: Int
        let name: String
    }

    let tagName: String
    let htmlURL: URL
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
    }
}
