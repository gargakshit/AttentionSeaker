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

    private(set) var authenticationState: AuthenticationState = .checking
    private(set) var refreshState: RefreshState = .idle
    private(set) var lastSuccessfulRefreshAt: Date?
    private(set) var truncatedReasons: AttentionReason = []
    private(set) var refreshIntervalMinutes: Int
    private(set) var launchAtLoginStatus: LaunchAtLoginStatus
    private(set) var cachedAccountLogin: String?
    private(set) var rateLimit: RateLimitInfo?

    @ObservationIgnored private let github: GitHubAttentionFetching
    @ObservationIgnored private let cache: AttentionCacheStoring
    @ObservationIgnored private let launchAtLogin: LaunchAtLoginControlling
    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private let schedulerSleep: (TimeInterval) async throws -> Void

    @ObservationIgnored private var schedulerTask: Task<Void, Never>?
    @ObservationIgnored private var accountGeneration = 0
    @ObservationIgnored private var hasStarted = false

    init(
        github: GitHubAttentionFetching,
        cache: AttentionCacheStoring,
        launchAtLogin: LaunchAtLoginControlling,
        userDefaults: UserDefaults = .standard,
        schedulerSleep: @escaping (TimeInterval) async throws -> Void = { interval in
            try await Task.sleep(for: .seconds(interval))
        }
    ) {
        self.github = github
        self.cache = cache
        self.launchAtLogin = launchAtLogin
        self.userDefaults = userDefaults
        self.schedulerSleep = schedulerSleep

        let storedInterval = userDefaults.object(forKey: Self.refreshIntervalKey) as? Int ?? 5
        refreshIntervalMinutes = Self.validatedRefreshInterval(storedInterval)
        launchAtLoginStatus = launchAtLogin.status

        if let metadata = try? cache.loadMetadata() {
            cachedAccountLogin = metadata.accountLogin
            lastSuccessfulRefreshAt = metadata.lastSuccessfulRefreshAt
            truncatedReasons = metadata.truncatedReasons
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
