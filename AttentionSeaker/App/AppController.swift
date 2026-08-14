import AppKit
import Foundation
import Observation

enum AuthenticationState: Equatable {
    case checking
    case cliUnavailable
    case signedOut
    case signedIn(login: String)
    case failed(message: String)
}

enum RefreshState: Equatable {
    case idle
    case refreshing
    case failed(message: String)
}

@MainActor
@Observable
final class AppController {
    private static let refreshIntervalKey = "refreshIntervalMinutes"
    private static let issueNotificationReasonsKey = "issueNotificationReasons"
    private static let pullRequestNotificationReasonsKey = "pullRequestNotificationReasons"
    private static let pendingIssueNotificationBaselineKey =
        "pendingIssueNotificationBaselineReasons"
    private static let pendingPullRequestNotificationBaselineKey =
        "pendingPullRequestNotificationBaselineReasons"

    private(set) var authenticationState: AuthenticationState = .checking
    private(set) var refreshState: RefreshState = .idle
    private(set) var lastSuccessfulRefreshAt: Date?
    private(set) var truncatedReasons: AttentionReason = []
    private(set) var refreshIntervalMinutes: Int
    private(set) var launchAtLoginStatus: LaunchAtLoginStatus
    private(set) var cachedAccountLogin: String?
    private(set) var rateLimit: RateLimitInfo?
    private(set) var notificationPreferences: AttentionNotificationPreferences
    private(set) var notificationAuthorizationState: NotificationAuthorizationState = .notDetermined
    private(set) var notificationErrorMessage: String?
    private(set) var isRequestingNotificationAuthorization = false

    @ObservationIgnored private let github: GitHubAttentionFetching
    @ObservationIgnored private let cache: AttentionCacheStoring
    @ObservationIgnored private let launchAtLogin: LaunchAtLoginControlling
    @ObservationIgnored private let notifications: AttentionNotificationSending
    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private let schedulerSleep: (TimeInterval) async throws -> Void

    @ObservationIgnored private var schedulerTask: Task<Void, Never>?
    @ObservationIgnored private var accountGeneration = 0
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var pendingNotificationBaseline: AttentionNotificationPreferences

    init(
        github: GitHubAttentionFetching,
        cache: AttentionCacheStoring,
        launchAtLogin: LaunchAtLoginControlling,
        notifications: AttentionNotificationSending,
        userDefaults: UserDefaults = .standard,
        schedulerSleep: @escaping (TimeInterval) async throws -> Void = { interval in
            try await Task.sleep(for: .seconds(interval))
        }
    ) {
        self.github = github
        self.cache = cache
        self.launchAtLogin = launchAtLogin
        self.notifications = notifications
        self.userDefaults = userDefaults
        self.schedulerSleep = schedulerSleep

        let storedInterval = userDefaults.object(forKey: Self.refreshIntervalKey) as? Int ?? 5
        refreshIntervalMinutes = Self.validatedRefreshInterval(storedInterval)
        notificationPreferences = AttentionNotificationPreferences(
            issueReasons: AttentionReason(
                rawValue: userDefaults.integer(forKey: Self.issueNotificationReasonsKey)
            ),
            pullRequestReasons: AttentionReason(
                rawValue: userDefaults.integer(forKey: Self.pullRequestNotificationReasonsKey)
            )
        )
        pendingNotificationBaseline = AttentionNotificationPreferences(
            issueReasons: AttentionReason(
                rawValue: userDefaults.integer(
                    forKey: Self.pendingIssueNotificationBaselineKey
                )
            ),
            pullRequestReasons: AttentionReason(
                rawValue: userDefaults.integer(
                    forKey: Self.pendingPullRequestNotificationBaselineKey
                )
            )
        )
        launchAtLoginStatus = launchAtLogin.status

        if let metadata = try? cache.loadMetadata() {
            cachedAccountLogin = metadata.accountLogin
            lastSuccessfulRefreshAt = metadata.lastSuccessfulRefreshAt
            truncatedReasons = metadata.truncatedReasons
        } else {
            pendingNotificationBaseline.issueReasons.formUnion(
                notificationPreferences.issueReasons
            )
            pendingNotificationBaseline.pullRequestReasons.formUnion(
                notificationPreferences.pullRequestReasons
            )
            persistPendingNotificationBaseline()
        }
    }

    deinit {
        schedulerTask?.cancel()
    }

    var isRefreshing: Bool {
        refreshState == .refreshing
    }

    var signedInLogin: String? {
        if case .signedIn(let login) = authenticationState {
            return login
        }
        return nil
    }

    var canRefresh: Bool {
        signedInLogin != nil && !isRefreshing
    }

    var isLaunchAtLoginEnabled: Bool {
        launchAtLoginStatus == .enabled
    }

    var gitHubCLIPath: String? {
        github.executableURL?.path
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        launchAtLoginStatus = launchAtLogin.status
        await refreshNotificationAuthorizationState()
        await recheckGitHub()
        startScheduler()
    }

    func recheckGitHub() async {
        accountGeneration &+= 1
        let checkGeneration = accountGeneration
        refreshState = .idle
        authenticationState = github.executableURL == nil ? .cliUnavailable : .checking

        guard github.executableURL != nil else { return }

        do {
            let login = try await github.viewerLogin()
            guard checkGeneration == accountGeneration else { return }

            if let cachedAccountLogin,
               cachedAccountLogin.caseInsensitiveCompare(login) != .orderedSame {
                try cache.clear()
                resetCacheMetadata()
                scheduleNotificationBaseline(for: notificationPreferences)
            }
            authenticationState = .signedIn(login: login)
            await refresh()
        } catch GitHubCLIError.executableNotFound {
            guard checkGeneration == accountGeneration else { return }
            authenticationState = .cliUnavailable
        } catch GitHubCLIError.notAuthenticated {
            guard checkGeneration == accountGeneration else { return }
            authenticationState = .signedOut
        } catch {
            guard checkGeneration == accountGeneration else { return }
            authenticationState = .failed(message: error.localizedDescription)
        }
    }

    func clearCache() {
        accountGeneration &+= 1
        var message: String?
        do {
            try cache.clear()
            resetCacheMetadata()
            scheduleNotificationBaseline(for: notificationPreferences)
        } catch {
            message = error.localizedDescription
        }
        refreshState = message.map(RefreshState.failed(message:)) ?? .idle
    }

    func refresh() async {
        guard !isRefreshing, let login = signedInLogin else { return }

        let refreshGeneration = accountGeneration
        refreshState = .refreshing
        do {
            let snapshot = try await github.fetchAttention(for: login)
            guard refreshGeneration == accountGeneration,
                  signedInLogin?.caseInsensitiveCompare(login) == .orderedSame
            else { return }

            try cache.replace(with: snapshot)
            cachedAccountLogin = snapshot.accountLogin
            lastSuccessfulRefreshAt = snapshot.fetchedAt
            truncatedReasons = snapshot.truncatedReasons
            rateLimit = snapshot.rateLimit
            refreshState = .idle
            guard applyPendingNotificationBaseline() else { return }
            await deliverNotificationsIfNeeded()
        } catch GitHubCLIError.notAuthenticated {
            guard refreshGeneration == accountGeneration else { return }
            accountGeneration &+= 1
            authenticationState = .signedOut
            refreshState = .failed(message: GitHubCLIError.notAuthenticated.localizedDescription)
        } catch GitHubCLIError.executableNotFound {
            guard refreshGeneration == accountGeneration else { return }
            accountGeneration &+= 1
            authenticationState = .cliUnavailable
            refreshState = .failed(message: GitHubCLIError.executableNotFound.localizedDescription)
        } catch {
            guard refreshGeneration == accountGeneration else { return }
            refreshState = .failed(message: error.localizedDescription)
        }
    }

    func updateRefreshInterval(_ minutes: Int) {
        let validated = Self.validatedRefreshInterval(minutes)
        guard validated != refreshIntervalMinutes else { return }
        refreshIntervalMinutes = validated
        userDefaults.set(validated, forKey: Self.refreshIntervalKey)
        if hasStarted {
            startScheduler()
        }
    }

    static func validatedRefreshInterval(_ minutes: Int) -> Int {
        min(max(minutes, 5), 1_440)
    }

    func isNotificationEnabled(kind: AttentionKind, reason: AttentionReason) -> Bool {
        notificationPreferences.isEnabled(kind: kind, reason: reason)
    }

    func setNotificationEnabled(
        _ enabled: Bool,
        kind: AttentionKind,
        reason: AttentionReason
    ) {
        let wasEnabled = notificationPreferences.isEnabled(kind: kind, reason: reason)
        guard enabled != wasEnabled else { return }

        notificationPreferences.setEnabled(enabled, kind: kind, reason: reason)
        persistNotificationPreferences()

        pendingNotificationBaseline.setEnabled(enabled, kind: kind, reason: reason)
        persistPendingNotificationBaseline()

        if enabled, !isRefreshing, lastSuccessfulRefreshAt != nil {
            _ = applyPendingNotificationBaseline()
        }
    }

    func requestNotificationAuthorization() async {
        guard !isRequestingNotificationAuthorization else { return }
        isRequestingNotificationAuthorization = true
        defer { isRequestingNotificationAuthorization = false }

        do {
            if await notifications.authorizationState() == .notDetermined {
                _ = try await notifications.requestAuthorization()
            }
            notificationErrorMessage = nil
            await refreshNotificationAuthorizationState()
        } catch {
            notificationErrorMessage = error.localizedDescription
            await refreshNotificationAuthorizationState()
        }
    }

    func refreshNotificationAuthorizationState() async {
        notificationAuthorizationState = await notifications.authorizationState()
    }

    func openNotificationSettings() {
        notifications.openSystemSettings()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try launchAtLogin.setEnabled(enabled)
            launchAtLoginStatus = launchAtLogin.status
        } catch {
            launchAtLoginStatus = launchAtLogin.status
            refreshState = .failed(message: error.localizedDescription)
        }
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLoginStatus = launchAtLogin.status
    }

    func openLoginItemsSettings() {
        launchAtLogin.openSystemSettings()
    }

    func openTerminal() {
        NSWorkspace.shared.open(
            URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        )
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func resetCacheMetadata() {
        cachedAccountLogin = nil
        lastSuccessfulRefreshAt = nil
        truncatedReasons = []
        rateLimit = nil
    }

    private func deliverNotificationsIfNeeded() async {
        guard !notificationPreferences.isEmpty else { return }

        await refreshNotificationAuthorizationState()
        guard notificationAuthorizationState == .authorized else { return }

        do {
            let candidates = try cache.takeNotificationCandidates(
                matching: notificationPreferences
            )
            guard !candidates.isEmpty else { return }
            try await notifications.send(candidates)
            notificationErrorMessage = nil
        } catch {
            notificationErrorMessage = error.localizedDescription
        }
    }

    private func scheduleNotificationBaseline(
        for preferences: AttentionNotificationPreferences
    ) {
        pendingNotificationBaseline.issueReasons.formUnion(preferences.issueReasons)
        pendingNotificationBaseline.pullRequestReasons.formUnion(preferences.pullRequestReasons)
        persistPendingNotificationBaseline()
    }

    @discardableResult
    private func applyPendingNotificationBaseline() -> Bool {
        guard !pendingNotificationBaseline.isEmpty else { return true }

        do {
            try cache.establishNotificationBaseline(matching: pendingNotificationBaseline)
            pendingNotificationBaseline = .none
            persistPendingNotificationBaseline()
            notificationErrorMessage = nil
            return true
        } catch {
            notificationErrorMessage = error.localizedDescription
            return false
        }
    }

    private func persistNotificationPreferences() {
        userDefaults.set(
            notificationPreferences.issueReasons.rawValue,
            forKey: Self.issueNotificationReasonsKey
        )
        userDefaults.set(
            notificationPreferences.pullRequestReasons.rawValue,
            forKey: Self.pullRequestNotificationReasonsKey
        )
    }

    private func persistPendingNotificationBaseline() {
        userDefaults.set(
            pendingNotificationBaseline.issueReasons.rawValue,
            forKey: Self.pendingIssueNotificationBaselineKey
        )
        userDefaults.set(
            pendingNotificationBaseline.pullRequestReasons.rawValue,
            forKey: Self.pendingPullRequestNotificationBaselineKey
        )
    }

    private func startScheduler() {
        schedulerTask?.cancel()
        let interval = refreshIntervalMinutes
        let sleep = schedulerSleep
        schedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await sleep(TimeInterval(interval * 60))
                } catch {
                    return
                }
                guard let self else { return }
                await self.refresh()
            }
        }
    }
}
