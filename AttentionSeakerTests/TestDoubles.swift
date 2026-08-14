import Foundation
@testable import AttentionSeaker

enum StubError: Error, Equatable {
    case expected
    case noResponse
}

@MainActor
final class StubHTTPTransport: HTTPTransporting {
    struct Stub {
        let data: Data
        let statusCode: Int
        let headers: [String: String]
    }

    private(set) var requests: [URLRequest] = []
    var stubs: [Stub]

    init(stubs: [Stub] = []) {
        self.stubs = stubs
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !stubs.isEmpty else { throw StubError.noResponse }
        let stub = stubs.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        return (stub.data, response)
    }
}

@MainActor
final class StubTokenStore: TokenStoring {
    var token: String?
    var error: Error?
    private(set) var savedTokens: [String] = []
    private(set) var deleteCount = 0

    init(token: String? = nil) {
        self.token = token
    }

    func readToken() throws -> String? {
        if let error { throw error }
        return token
    }

    func saveToken(_ token: String) throws {
        if let error { throw error }
        self.token = token
        savedTokens.append(token)
    }

    func deleteToken() throws {
        if let error { throw error }
        token = nil
        deleteCount += 1
    }
}

@MainActor
final class StubOAuthClient: OAuthAuthenticating {
    var authorization = DeviceAuthorization(
        deviceCode: "device",
        userCode: "ABCD-EFGH",
        verificationURL: AppConfiguration.deviceAuthorizationURL,
        expiresAt: Date().addingTimeInterval(900),
        pollingInterval: 5
    )
    var accessToken = OAuthAccessToken(value: "new-token", scopes: ["repo"])
    var error: Error?
    private(set) var cancelCount = 0

    func requestDeviceAuthorization(clientID: String) async throws -> DeviceAuthorization {
        if let error { throw error }
        return authorization
    }

    func waitForAccessToken(clientID: String, authorization: DeviceAuthorization) async throws -> OAuthAccessToken {
        if let error { throw error }
        return accessToken
    }

    func cancel() {
        cancelCount += 1
    }
}

@MainActor
final class StubGitHubClient: GitHubAttentionFetching {
    var login = "octocat"
    var snapshot: AttentionSnapshot
    var viewerError: Error?
    var fetchError: Error?
    var suspendsFetch = false
    private(set) var fetchCount = 0
    private var fetchContinuation: CheckedContinuation<Void, Never>?

    init(snapshot: AttentionSnapshot? = nil) {
        self.snapshot = snapshot ?? .stub()
    }

    func viewerLogin(token: String) async throws -> String {
        if let viewerError { throw viewerError }
        return login
    }

    func fetchAttention(for expectedLogin: String, token: String) async throws -> AttentionSnapshot {
        fetchCount += 1
        if suspendsFetch {
            await withCheckedContinuation { continuation in
                fetchContinuation = continuation
            }
        }
        if let fetchError { throw fetchError }
        return snapshot
    }

    func resumeFetch() {
        suspendsFetch = false
        fetchContinuation?.resume()
        fetchContinuation = nil
    }
}

@MainActor
final class StubCacheStore: AttentionCacheStoring {
    var metadata: CachedMetadata?
    var error: Error?
    private(set) var snapshots: [AttentionSnapshot] = []
    private(set) var clearCount = 0

    func loadMetadata() throws -> CachedMetadata? {
        if let error { throw error }
        return metadata
    }

    func replace(with snapshot: AttentionSnapshot) throws {
        if let error { throw error }
        snapshots.append(snapshot)
        metadata = CachedMetadata(
            accountLogin: snapshot.accountLogin,
            lastSuccessfulRefreshAt: snapshot.fetchedAt,
            truncatedReasons: snapshot.truncatedReasons
        )
    }

    func clear() throws {
        if let error { throw error }
        clearCount += 1
        metadata = nil
    }
}

@MainActor
final class StubLaunchAtLoginController: LaunchAtLoginControlling {
    var status: LaunchAtLoginStatus = .disabled
    var error: Error?

    func setEnabled(_ enabled: Bool) throws {
        if let error { throw error }
        status = enabled ? .enabled : .disabled
    }

    func openSystemSettings() {}
}

extension AttentionSnapshot {
    static func stub(
        records: [AttentionRecord] = [],
        login: String = "octocat",
        date: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> AttentionSnapshot {
        AttentionSnapshot(
            records: records,
            accountLogin: login,
            fetchedAt: date,
            truncatedReasons: [],
            rateLimit: RateLimitInfo(remaining: 4_999, resetAt: date.addingTimeInterval(3_600))
        )
    }
}

extension AttentionRecord {
    static func stub(
        id: String = "I_1",
        kind: AttentionKind = .issue,
        repository: String = "owner/repo",
        number: Int = 1,
        updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        reasons: AttentionReason = .assigned
    ) -> AttentionRecord {
        AttentionRecord(
            nodeID: id,
            kind: kind,
            repositoryName: repository,
            number: number,
            title: "An attention item",
            url: URL(string: "https://github.com/owner/repo/issues/\(number)")!,
            authorLogin: "author",
            createdAt: updatedAt.addingTimeInterval(-3_600),
            updatedAt: updatedAt,
            isDraft: false,
            reasons: reasons
        )
    }
}
