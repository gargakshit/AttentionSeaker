import Foundation
@testable import AttentionSeaker

enum StubError: Error, Equatable {
    case expected
    case noResponse
}

@MainActor
final class StubGitHubCLIExecutor: GitHubCLIExecuting {
    struct Invocation {
        let arguments: [String]
        let standardInput: Data?
    }

    var executableURL: URL?
    var results: [GitHubCLIResult]
    var error: Error?
    private(set) var invocations: [Invocation] = []

    init(
        executableURL: URL? = URL(fileURLWithPath: "/opt/homebrew/bin/gh"),
        results: [GitHubCLIResult] = []
    ) {
        self.executableURL = executableURL
        self.results = results
    }

    func run(arguments: [String], standardInput: Data?) async throws -> GitHubCLIResult {
        invocations.append(Invocation(arguments: arguments, standardInput: standardInput))
        if let error { throw error }
        guard !results.isEmpty else { throw StubError.noResponse }
        return results.removeFirst()
    }
}

@MainActor
final class StubGitHubClient: GitHubAttentionFetching {
    var executableURL: URL? = URL(fileURLWithPath: "/opt/homebrew/bin/gh")
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

    func viewerLogin() async throws -> String {
        if let viewerError { throw viewerError }
        return login
    }

    func fetchAttention(for expectedLogin: String) async throws -> AttentionSnapshot {
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
    var notificationCandidates: [AttentionNotification] = []
    private(set) var snapshots: [AttentionSnapshot] = []
    private(set) var clearCount = 0
    private(set) var notificationBaselines: [AttentionNotificationPreferences] = []
    private(set) var notificationPreferences: [AttentionNotificationPreferences] = []

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

    func takeNotificationCandidates(
        matching preferences: AttentionNotificationPreferences
    ) throws -> [AttentionNotification] {
        if let error { throw error }
        notificationPreferences.append(preferences)
        let candidates = notificationCandidates
        notificationCandidates = []
        return candidates
    }

    func establishNotificationBaseline(
        matching preferences: AttentionNotificationPreferences
    ) throws {
        if let error { throw error }
        notificationBaselines.append(preferences)
        notificationCandidates.removeAll { notification in
            !preferences.matchingReasons(
                kind: notification.kind,
                itemReasons: notification.matchingReasons
            ).isEmpty
        }
    }

    func clear() throws {
        if let error { throw error }
        clearCount += 1
        metadata = nil
    }
}

@MainActor
final class StubNotificationSender: AttentionNotificationSending {
    var state: NotificationAuthorizationState = .denied
    var requestResult = true
    var error: Error?
    private(set) var requestCount = 0
    private(set) var sentNotifications: [AttentionNotification] = []
    private(set) var openSettingsCount = 0

    func authorizationState() async -> NotificationAuthorizationState {
        state
    }

    func requestAuthorization() async throws -> Bool {
        requestCount += 1
        if let error { throw error }
        state = requestResult ? .authorized : .denied
        return requestResult
    }

    func send(_ notifications: [AttentionNotification]) async throws {
        if let error { throw error }
        sentNotifications.append(contentsOf: notifications)
    }

    func openSystemSettings() {
        openSettingsCount += 1
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
        lastActivityAt: Date? = nil,
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
            lastActivityAt: lastActivityAt ?? updatedAt,
            isDraft: false,
            reasons: reasons
        )
    }
}

extension AttentionNotification {
    static func stub(
        id: String = "I_1",
        kind: AttentionKind = .issue,
        reasons: AttentionReason = .assigned
    ) -> AttentionNotification {
        AttentionNotification(
            nodeID: id,
            kind: kind,
            repositoryName: "owner/repo",
            number: 1,
            title: "An attention item",
            url: URL(string: "https://github.com/owner/repo/issues/1")!,
            matchingReasons: reasons
        )
    }
}
