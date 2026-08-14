import Foundation
import Testing
@testable import AttentionSeaker

@MainActor
struct AppControllerTests {
    @Test
    func startValidatesSavedTokenAndRefreshesOnce() async {
        let tokenStore = StubTokenStore(token: "saved-token")
        let github = StubGitHubClient(snapshot: .stub(records: [.stub()]))
        let cache = StubCacheStore()
        let controller = makeController(tokenStore: tokenStore, github: github, cache: cache)

        await controller.start()

        #expect(controller.authenticationState == .signedIn(login: "octocat"))
        #expect(github.fetchCount == 1)
        #expect(cache.snapshots.count == 1)
        #expect(controller.lastSuccessfulRefreshAt == github.snapshot.fetchedAt)
    }

    @Test
    func refreshFailureLeavesTheLastGoodCacheUntouched() async {
        let date = Date(timeIntervalSince1970: 100)
        let metadata = CachedMetadata(
            accountLogin: "octocat",
            lastSuccessfulRefreshAt: date,
            truncatedReasons: []
        )
        let tokenStore = StubTokenStore(token: "saved-token")
        let github = StubGitHubClient()
        github.fetchError = StubError.expected
        let cache = StubCacheStore()
        cache.metadata = metadata
        let controller = makeController(tokenStore: tokenStore, github: github, cache: cache)

        await controller.start()

        #expect(cache.snapshots.isEmpty)
        #expect(cache.clearCount == 0)
        #expect(controller.lastSuccessfulRefreshAt == date)
        guard case .failed = controller.refreshState else {
            Issue.record("Expected failed refresh state")
            return
        }
    }

    @Test
    func unauthorizedRefreshDeletesTokenButKeepsCachedData() async {
        let tokenStore = StubTokenStore(token: "saved-token")
        let github = StubGitHubClient()
        github.fetchError = GitHubAPIError.unauthorized
        let cache = StubCacheStore()
        cache.metadata = CachedMetadata(
            accountLogin: "octocat",
            lastSuccessfulRefreshAt: Date(timeIntervalSince1970: 100),
            truncatedReasons: []
        )
        let controller = makeController(tokenStore: tokenStore, github: github, cache: cache)

        await controller.start()

        #expect(tokenStore.token == nil)
        #expect(cache.clearCount == 0)
        #expect(controller.authenticationState == .signedOut)
    }

    @Test
    func signingOutDeletesTokenAndCache() async {
        let tokenStore = StubTokenStore(token: "saved-token")
        let github = StubGitHubClient()
        let cache = StubCacheStore()
        let controller = makeController(tokenStore: tokenStore, github: github, cache: cache)
        await controller.start()

        controller.signOutAndClearCache()

        #expect(tokenStore.token == nil)
        #expect(cache.clearCount == 1)
        #expect(controller.authenticationState == .signedOut)
        #expect(controller.lastSuccessfulRefreshAt == nil)
    }

    @Test
    func launchAtLoginUsesServiceStatusAsSourceOfTruth() {
        let launch = StubLaunchAtLoginController()
        let controller = makeController(launchAtLogin: launch)

        controller.setLaunchAtLogin(true)
        #expect(controller.launchAtLoginStatus == .enabled)

        controller.setLaunchAtLogin(false)
        #expect(controller.launchAtLoginStatus == .disabled)
    }

    @Test
    func overlappingRefreshesAreSingleFlight() async {
        let tokenStore = StubTokenStore(token: "saved-token")
        let github = StubGitHubClient()
        github.suspendsFetch = true
        let controller = makeController(tokenStore: tokenStore, github: github)

        let startTask = Task { await controller.start() }
        await waitUntil { github.fetchCount == 1 }

        await controller.refresh()
        #expect(github.fetchCount == 1)

        github.resumeFetch()
        await startTask.value
    }

    @Test
    func signingOutDuringRefreshCannotRepopulateTheClearedCache() async {
        let tokenStore = StubTokenStore(token: "saved-token")
        let github = StubGitHubClient(snapshot: .stub(records: [.stub()]))
        github.suspendsFetch = true
        let cache = StubCacheStore()
        let controller = makeController(tokenStore: tokenStore, github: github, cache: cache)

        let startTask = Task { await controller.start() }
        await waitUntil { github.fetchCount == 1 }
        controller.signOutAndClearCache()
        github.resumeFetch()
        await startTask.value

        #expect(cache.snapshots.isEmpty)
        #expect(cache.clearCount == 1)
        #expect(tokenStore.token == nil)
        #expect(controller.authenticationState == .signedOut)
    }

    @Test
    func changingTheIntervalCancelsAndReschedulesImmediately() async {
        var requestedSleeps: [TimeInterval] = []
        let controller = makeController { interval in
            requestedSleeps.append(interval)
            try await Task.sleep(for: .seconds(3_600))
        }

        await controller.start()
        await waitUntil { requestedSleeps.count == 1 }
        controller.updateRefreshInterval(10)
        await waitUntil { requestedSleeps.count == 2 }

        #expect(requestedSleeps == [300, 600])
    }

    private func makeController(
        tokenStore: StubTokenStore? = nil,
        github: StubGitHubClient? = nil,
        cache: StubCacheStore? = nil,
        launchAtLogin: StubLaunchAtLoginController? = nil,
        schedulerSleep: @escaping (TimeInterval) async throws -> Void = { interval in
            try await Task.sleep(for: .seconds(interval))
        }
    ) -> AppController {
        let suiteName = "AttentionSeakerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return AppController(
            configuration: AppConfiguration(githubOAuthClientID: "client-id"),
            oauth: StubOAuthClient(),
            tokenStore: tokenStore ?? StubTokenStore(),
            github: github ?? StubGitHubClient(),
            cache: cache ?? StubCacheStore(),
            launchAtLogin: launchAtLogin ?? StubLaunchAtLoginController(),
            userDefaults: defaults,
            schedulerSleep: schedulerSleep
        )
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for an asynchronous test condition")
    }
}
