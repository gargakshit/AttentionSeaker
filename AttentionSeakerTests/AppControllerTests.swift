import Foundation
import Testing
@testable import AttentionSeaker

@MainActor
struct AppControllerTests {
    @Test
    func startChecksTheGlobalCLIAccountAndRefreshesOnce() async {
        let github = StubGitHubClient(snapshot: .stub(records: [.stub()]))
        let cache = StubCacheStore()
        let controller = makeController(github: github, cache: cache)

        await controller.start()

        #expect(controller.authenticationState == .signedIn(login: "octocat"))
        #expect(github.fetchCount == 1)
        #expect(cache.snapshots.count == 1)
        #expect(controller.lastSuccessfulRefreshAt == github.snapshot.fetchedAt)
    }

    @Test
    func missingGlobalCLIHasADedicatedState() async {
        let github = StubGitHubClient()
        github.executableURL = nil
        let controller = makeController(github: github)

        await controller.start()

        #expect(controller.authenticationState == .cliUnavailable)
        #expect(github.fetchCount == 0)
    }

    @Test
    func refreshFailureLeavesTheLastGoodCacheUntouched() async {
        let date = Date(timeIntervalSince1970: 100)
        let github = StubGitHubClient()
        github.fetchError = StubError.expected
        let cache = StubCacheStore()
        cache.metadata = CachedMetadata(
            accountLogin: "octocat",
            lastSuccessfulRefreshAt: date,
            truncatedReasons: []
        )
        let controller = makeController(github: github, cache: cache)

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
    func unauthenticatedGlobalCLIKeepsCachedData() async {
        let github = StubGitHubClient()
        github.fetchError = GitHubCLIError.notAuthenticated
        let cache = StubCacheStore()
        cache.metadata = CachedMetadata(
            accountLogin: "octocat",
            lastSuccessfulRefreshAt: Date(timeIntervalSince1970: 100),
            truncatedReasons: []
        )
        let controller = makeController(github: github, cache: cache)

        await controller.start()

        #expect(cache.clearCount == 0)
        #expect(controller.authenticationState == .signedOut)
        #expect(controller.cachedAccountLogin == "octocat")
    }

    @Test
    func clearingCacheDoesNotModifyTheGlobalCLISession() async {
        let github = StubGitHubClient()
        let cache = StubCacheStore()
        let controller = makeController(github: github, cache: cache)
        await controller.start()

        controller.clearCache()

        #expect(cache.clearCount == 1)
        #expect(controller.authenticationState == .signedIn(login: "octocat"))
        #expect(controller.lastSuccessfulRefreshAt == nil)
    }

    @Test
    func aDifferentGlobalCLIAccountClearsThePreviousSnapshotFirst() async {
        let github = StubGitHubClient(snapshot: .stub(login: "new-user"))
        github.login = "new-user"
        let cache = StubCacheStore()
        cache.metadata = CachedMetadata(
            accountLogin: "old-user",
            lastSuccessfulRefreshAt: Date(timeIntervalSince1970: 100),
            truncatedReasons: []
        )
        let controller = makeController(github: github, cache: cache)

        await controller.start()

        #expect(cache.clearCount == 1)
        #expect(cache.snapshots.count == 1)
        #expect(controller.authenticationState == .signedIn(login: "new-user"))
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
        let github = StubGitHubClient()
        github.suspendsFetch = true
        let controller = makeController(github: github)

        let startTask = Task { await controller.start() }
        await waitUntil { github.fetchCount == 1 }

        await controller.refresh()
        #expect(github.fetchCount == 1)

        github.resumeFetch()
        await startTask.value
    }

    @Test
    func clearingCacheDuringRefreshCannotRepopulateIt() async {
        let github = StubGitHubClient(snapshot: .stub(records: [.stub()]))
        github.suspendsFetch = true
        let cache = StubCacheStore()
        let controller = makeController(github: github, cache: cache)

        let startTask = Task { await controller.start() }
        await waitUntil { github.fetchCount == 1 }
        controller.clearCache()
        github.resumeFetch()
        await startTask.value

        #expect(cache.snapshots.isEmpty)
        #expect(cache.clearCount == 1)
        #expect(controller.authenticationState == .signedIn(login: "octocat"))
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
