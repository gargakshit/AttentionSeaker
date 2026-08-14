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
    func successfulRefreshSendsEachClaimedNotificationOnce() async {
        let cache = StubCacheStore()
        cache.metadata = CachedMetadata(
            accountLogin: "octocat",
            lastSuccessfulRefreshAt: Date(timeIntervalSince1970: 100),
            truncatedReasons: []
        )
        let notifications = StubNotificationSender()
        notifications.state = .authorized
        let controller = makeController(cache: cache, notifications: notifications)
        controller.setNotificationEnabled(true, kind: .issue, reason: .assigned)
        cache.notificationCandidates = [
            .stub(id: "issue", kind: .issue, reasons: .assigned),
        ]

        await controller.start()
        await controller.refresh()

        #expect(notifications.sentNotifications.map(\.nodeID) == ["issue"])
        #expect(cache.notificationPreferences.count == 2)
        #expect(cache.notificationBaselines.count == 1)
    }

    @Test
    func enablingATypeCanRequestSystemAuthorization() async {
        let notifications = StubNotificationSender()
        notifications.state = .notDetermined
        let controller = makeController(notifications: notifications)

        controller.setNotificationEnabled(true, kind: .pullRequest, reason: .reviewRequested)
        await controller.requestNotificationAuthorization()

        #expect(controller.isNotificationEnabled(kind: .pullRequest, reason: .reviewRequested))
        #expect(notifications.requestCount == 1)
        #expect(controller.notificationAuthorizationState == .authorized)
    }

    @Test
    func notificationSelectionsAndPendingBaselinePersist() async {
        let suiteName = "AttentionSeakerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstController = makeController(userDefaults: defaults)
        firstController.setNotificationEnabled(true, kind: .issue, reason: .assigned)
        firstController.setNotificationEnabled(true, kind: .pullRequest, reason: .reviewRequested)

        let restoredCache = StubCacheStore()
        restoredCache.notificationCandidates = [
            .stub(id: "existing-issue", kind: .issue, reasons: .assigned),
            .stub(id: "existing-pr", kind: .pullRequest, reasons: .reviewRequested),
        ]
        let notifications = StubNotificationSender()
        notifications.state = .authorized
        let restoredController = makeController(
            cache: restoredCache,
            notifications: notifications,
            userDefaults: defaults
        )
        #expect(restoredController.isNotificationEnabled(kind: .issue, reason: .assigned))
        #expect(!restoredController.isNotificationEnabled(kind: .pullRequest, reason: .assigned))
        #expect(restoredController.isNotificationEnabled(
            kind: .pullRequest,
            reason: .reviewRequested
        ))

        await restoredController.start()

        #expect(restoredCache.notificationBaselines.count == 1)
        #expect(notifications.sentNotifications.isEmpty)
    }

    @Test
    func enablingAReasonBaselinesTheCurrentSnapshotButNotFutureItems() async {
        let cache = StubCacheStore()
        cache.metadata = CachedMetadata(
            accountLogin: "octocat",
            lastSuccessfulRefreshAt: Date(timeIntervalSince1970: 100),
            truncatedReasons: []
        )
        cache.notificationCandidates = [
            .stub(id: "existing", kind: .issue, reasons: .mentioned),
        ]
        let notifications = StubNotificationSender()
        notifications.state = .authorized
        let controller = makeController(cache: cache, notifications: notifications)

        controller.setNotificationEnabled(true, kind: .issue, reason: .mentioned)
        await controller.start()
        #expect(notifications.sentNotifications.isEmpty)

        cache.notificationCandidates = [
            .stub(id: "future", kind: .issue, reasons: .mentioned),
        ]
        await controller.refresh()

        #expect(notifications.sentNotifications.map(\.nodeID) == ["future"])
    }

    @Test
    func enablingDuringInitialSyncDefersTheBaselineUntilTheSnapshotArrives() async {
        let github = StubGitHubClient()
        github.suspendsFetch = true
        let cache = StubCacheStore()
        cache.notificationCandidates = [
            .stub(id: "initial", kind: .pullRequest, reasons: .reviewRequested),
        ]
        let notifications = StubNotificationSender()
        notifications.state = .authorized
        let controller = makeController(
            github: github,
            cache: cache,
            notifications: notifications
        )

        let startTask = Task { await controller.start() }
        await waitUntil { github.fetchCount == 1 }
        controller.setNotificationEnabled(true, kind: .pullRequest, reason: .reviewRequested)
        #expect(cache.notificationBaselines.isEmpty)

        github.resumeFetch()
        await startTask.value

        #expect(cache.notificationBaselines.count == 1)
        #expect(notifications.sentNotifications.isEmpty)
    }

    @Test
    func failedRefreshDoesNotClaimOrSendNotifications() async {
        let github = StubGitHubClient()
        github.fetchError = StubError.expected
        let cache = StubCacheStore()
        cache.notificationCandidates = [.stub(id: "issue", kind: .issue, reasons: .assigned)]
        let notifications = StubNotificationSender()
        notifications.state = .authorized
        let controller = makeController(
            github: github,
            cache: cache,
            notifications: notifications
        )
        controller.setNotificationEnabled(true, kind: .issue, reason: .assigned)

        await controller.start()

        #expect(cache.notificationPreferences.isEmpty)
        #expect(notifications.sentNotifications.isEmpty)
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
        notifications: StubNotificationSender? = nil,
        userDefaults: UserDefaults? = nil,
        schedulerSleep: @escaping (TimeInterval) async throws -> Void = { interval in
            try await Task.sleep(for: .seconds(interval))
        }
    ) -> AppController {
        let defaults: UserDefaults
        if let userDefaults {
            defaults = userDefaults
        } else {
            let suiteName = "AttentionSeakerTests.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
        }
        return AppController(
            github: github ?? StubGitHubClient(),
            cache: cache ?? StubCacheStore(),
            launchAtLogin: launchAtLogin ?? StubLaunchAtLoginController(),
            notifications: notifications ?? StubNotificationSender(),
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
