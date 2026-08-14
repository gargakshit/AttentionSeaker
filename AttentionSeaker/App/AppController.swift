import AppKit
import Foundation
import Observation

enum AuthenticationState: Equatable {
    case notConfigured
    case signedOut
    case authorizing(DeviceAuthorization)
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

    private(set) var authenticationState: AuthenticationState
    private(set) var refreshState: RefreshState = .idle
    private(set) var lastSuccessfulRefreshAt: Date?
    private(set) var truncatedReasons: AttentionReason = []
    private(set) var refreshIntervalMinutes: Int
    private(set) var launchAtLoginStatus: LaunchAtLoginStatus
    private(set) var cachedAccountLogin: String?
    private(set) var rateLimit: RateLimitInfo?

    @ObservationIgnored private let configuration: AppConfiguration
    @ObservationIgnored private let oauth: OAuthAuthenticating
    @ObservationIgnored private let tokenStore: TokenStoring
    @ObservationIgnored private let github: GitHubAttentionFetching
    @ObservationIgnored private let cache: AttentionCacheStoring
    @ObservationIgnored private let launchAtLogin: LaunchAtLoginControlling
    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private let schedulerSleep: (TimeInterval) async throws -> Void

    @ObservationIgnored private var token: String?
    @ObservationIgnored private var authorizationTask: Task<Void, Never>?
    @ObservationIgnored private var schedulerTask: Task<Void, Never>?
    @ObservationIgnored private var authenticationStateBeforeAuthorization: AuthenticationState?
    @ObservationIgnored private var credentialGeneration = 0
    @ObservationIgnored private var hasStarted = false

    init(
        configuration: AppConfiguration,
        oauth: OAuthAuthenticating,
        tokenStore: TokenStoring,
        github: GitHubAttentionFetching,
        cache: AttentionCacheStoring,
        launchAtLogin: LaunchAtLoginControlling,
        userDefaults: UserDefaults = .standard,
        schedulerSleep: @escaping (TimeInterval) async throws -> Void = { interval in
            try await Task.sleep(for: .seconds(interval))
        }
    ) {
        self.configuration = configuration
        self.oauth = oauth
        self.tokenStore = tokenStore
        self.github = github
        self.cache = cache
        self.launchAtLogin = launchAtLogin
        self.userDefaults = userDefaults
        self.schedulerSleep = schedulerSleep

        let storedInterval = userDefaults.object(forKey: Self.refreshIntervalKey) as? Int ?? 5
        refreshIntervalMinutes = Self.validatedRefreshInterval(storedInterval)
        launchAtLoginStatus = launchAtLogin.status
        authenticationState = configuration.githubOAuthClientID == nil ? .notConfigured : .signedOut

        if let metadata = try? cache.loadMetadata() {
            cachedAccountLogin = metadata.accountLogin
            lastSuccessfulRefreshAt = metadata.lastSuccessfulRefreshAt
            truncatedReasons = metadata.truncatedReasons
        }
    }

    deinit {
        authorizationTask?.cancel()
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
        signedInLogin != nil && token != nil && !isRefreshing
    }

    var isLaunchAtLoginEnabled: Bool {
        launchAtLoginStatus == .enabled
    }

    var oauthClientID: String? {
        configuration.githubOAuthClientID
    }

    var manageGitHubAccessURL: URL? {
        configuration.githubOAuthClientID.flatMap {
            URL(string: "https://github.com/settings/connections/applications/\($0)")
        }
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        launchAtLoginStatus = launchAtLogin.status

        do {
            token = try tokenStore.readToken()
            if token != nil {
                credentialGeneration &+= 1
            }
        } catch {
            refreshState = .failed(message: error.localizedDescription)
        }

        if let token {
            do {
                let login = try await github.viewerLogin(token: token)
                if let cachedAccountLogin,
                   cachedAccountLogin.caseInsensitiveCompare(login) != .orderedSame {
                    try cache.clear()
                    resetCacheMetadata()
                }
                authenticationState = .signedIn(login: login)
                await refresh()
            } catch GitHubAPIError.unauthorized {
                invalidateToken()
                refreshState = .failed(message: GitHubAPIError.unauthorized.localizedDescription)
            } catch {
                refreshState = .failed(message: error.localizedDescription)
                if configuration.githubOAuthClientID == nil {
                    authenticationState = .notConfigured
                }
            }
        } else {
            authenticationState = configuration.githubOAuthClientID == nil ? .notConfigured : .signedOut
        }

        startScheduler()
    }

    func connectGitHub() {
        guard authorizationTask == nil,
              let clientID = configuration.githubOAuthClientID
        else {
            if configuration.githubOAuthClientID == nil {
                authenticationState = .notConfigured
            }
            return
        }

        refreshState = .idle
        if authenticationStateBeforeAuthorization == nil {
            if case .signedIn = authenticationState {
                authenticationStateBeforeAuthorization = authenticationState
            } else {
                authenticationStateBeforeAuthorization = .signedOut
            }
        }
        authorizationTask = Task { [weak self] in
            guard let self else { return }
            await self.performAuthorization(clientID: clientID)
        }
    }

    func cancelAuthorization() {
        oauth.cancel()
        authorizationTask?.cancel()
        authorizationTask = nil
        authenticationState = authenticationStateBeforeAuthorization
            ?? (configuration.githubOAuthClientID == nil ? .notConfigured : .signedOut)
        authenticationStateBeforeAuthorization = nil
    }

    func signOutAndClearCache() {
        cancelAuthorization()
        authenticationStateBeforeAuthorization = nil
        credentialGeneration &+= 1
        var messages: [String] = []

        do {
            try tokenStore.deleteToken()
        } catch {
            messages.append(error.localizedDescription)
        }
        token = nil

        do {
            try cache.clear()
            resetCacheMetadata()
        } catch {
            messages.append(error.localizedDescription)
        }

        authenticationState = configuration.githubOAuthClientID == nil ? .notConfigured : .signedOut
        refreshState = messages.isEmpty ? .idle : .failed(message: messages.joined(separator: "\n"))
    }

    func refresh() async {
        guard !isRefreshing,
              let activeToken = token,
              let login = signedInLogin
        else { return }

        let refreshGeneration = credentialGeneration
        refreshState = .refreshing
        do {
            let snapshot = try await github.fetchAttention(for: login, token: activeToken)
            guard refreshGeneration == credentialGeneration,
                  token == activeToken,
                  signedInLogin?.caseInsensitiveCompare(login) == .orderedSame
            else { return }
            try cache.replace(with: snapshot)
            cachedAccountLogin = snapshot.accountLogin
            lastSuccessfulRefreshAt = snapshot.fetchedAt
            truncatedReasons = snapshot.truncatedReasons
            rateLimit = snapshot.rateLimit
            refreshState = .idle
        } catch GitHubAPIError.unauthorized {
            guard refreshGeneration == credentialGeneration else { return }
            invalidateToken()
            refreshState = .failed(message: GitHubAPIError.unauthorized.localizedDescription)
        } catch {
            guard refreshGeneration == credentialGeneration else { return }
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

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func performAuthorization(clientID: String) async {
        defer { authorizationTask = nil }
        do {
            let authorization = try await oauth.requestDeviceAuthorization(clientID: clientID)
            try Task.checkCancellation()
            authenticationState = .authorizing(authorization)

            let accessToken = try await oauth.waitForAccessToken(
                clientID: clientID,
                authorization: authorization
            )
            try Task.checkCancellation()

            let login = try await github.viewerLogin(token: accessToken.value)
            if let cachedAccountLogin,
               cachedAccountLogin.caseInsensitiveCompare(login) != .orderedSame {
                try cache.clear()
                resetCacheMetadata()
            }

            try tokenStore.saveToken(accessToken.value)
            credentialGeneration &+= 1
            token = accessToken.value
            authenticationStateBeforeAuthorization = nil
            authenticationState = .signedIn(login: login)
            await refresh()
        } catch is CancellationError {
            authenticationState = authenticationStateBeforeAuthorization
                ?? (configuration.githubOAuthClientID == nil ? .notConfigured : .signedOut)
            authenticationStateBeforeAuthorization = nil
        } catch {
            authenticationState = .failed(message: error.localizedDescription)
        }
    }

    private func invalidateToken() {
        credentialGeneration &+= 1
        try? tokenStore.deleteToken()
        token = nil
        authenticationState = configuration.githubOAuthClientID == nil ? .notConfigured : .signedOut
    }

    private func resetCacheMetadata() {
        cachedAccountLogin = nil
        lastSuccessfulRefreshAt = nil
        truncatedReasons = []
        rateLimit = nil
    }

    private func startScheduler() {
        schedulerTask?.cancel()
        let interval = refreshIntervalMinutes
        schedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await schedulerSleep(TimeInterval(interval * 60))
                } catch {
                    return
                }
                guard let self else { return }
                await self.refresh()
            }
        }
    }
}
