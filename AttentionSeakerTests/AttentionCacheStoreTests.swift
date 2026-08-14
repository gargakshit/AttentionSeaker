import Foundation
import SwiftData
import Testing
@testable import AttentionSeaker

@MainActor
struct AttentionCacheStoreTests {
    @Test
    func replacesUpdatesAndDeletesSnapshotItems() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let store = SwiftDataAttentionCacheStore(container: container)
        let first = AttentionRecord.stub(id: "first", number: 1, reasons: .assigned)
        let second = AttentionRecord.stub(id: "second", number: 2, reasons: .mentioned)

        try store.replace(with: .stub(records: [first, second]))
        var items = try container.mainContext.fetch(FetchDescriptor<AttentionItem>())
        #expect(items.count == 2)

        let updatedSecond = AttentionRecord.stub(
            id: "second",
            number: 2,
            updatedAt: second.updatedAt,
            lastActivityAt: second.lastActivityAt.addingTimeInterval(300),
            reasons: [.mentioned, .authored]
        )
        let third = AttentionRecord.stub(id: "third", number: 3, reasons: .reviewRequested)
        try store.replace(with: .stub(records: [updatedSecond, third]))

        items = try container.mainContext.fetch(FetchDescriptor<AttentionItem>())
        #expect(Set(items.map(\.nodeID)) == ["second", "third"])
        #expect(items.first(where: { $0.nodeID == "second" })?.reasons == [.mentioned, .authored])
        #expect(
            items.first(where: { $0.nodeID == "second" })?.lastActivityAt
                == updatedSecond.lastActivityAt
        )
        let insertedMetadata = try store.loadMetadata()
        #expect(insertedMetadata?.accountLogin == "octocat")
        let metadataModels = try container.mainContext.fetch(FetchDescriptor<CacheMetadata>())
        #expect(metadataModels.first?.schemaVersion == 3)
    }

    @Test
    func aDifferentAccountReplacesTheEntireCache() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let store = SwiftDataAttentionCacheStore(container: container)
        try store.replace(with: .stub(records: [.stub(id: "old")], login: "old-user"))
        try store.replace(with: .stub(records: [.stub(id: "new")], login: "new-user"))

        let items = try container.mainContext.fetch(FetchDescriptor<AttentionItem>())
        #expect(items.map(\.nodeID) == ["new"])
        let updatedMetadata = try store.loadMetadata()
        #expect(updatedMetadata?.accountLogin == "new-user")
    }

    @Test
    func clearRemovesItemsAndMetadata() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let store = SwiftDataAttentionCacheStore(container: container)
        try store.replace(with: .stub(records: [.stub()]))

        try store.clear()

        #expect(try container.mainContext.fetchCount(FetchDescriptor<AttentionItem>()) == 0)
        let clearedMetadata = try store.loadMetadata()
        #expect(clearedMetadata == nil)
    }

    @Test
    func saveFailureRollsBackEverySnapshotMutation() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let store = SwiftDataAttentionCacheStore(container: container)
        let original = AttentionRecord.stub(id: "original", number: 1, reasons: .assigned)
        try store.replace(with: .stub(records: [original]))

        let failingStore = SwiftDataAttentionCacheStore(
            container: container,
            saveContext: { _ in throw StubError.expected }
        )
        let replacement = AttentionRecord.stub(id: "replacement", number: 2, reasons: .mentioned)

        #expect(throws: StubError.expected) {
            try failingStore.replace(with: .stub(records: [replacement], login: "another-account"))
        }

        let items = try container.mainContext.fetch(FetchDescriptor<AttentionItem>())
        let metadata = try store.loadMetadata()
        #expect(items.map(\.nodeID) == ["original"])
        #expect(items.first?.reasons == .assigned)
        #expect(metadata?.accountLogin == "octocat")
    }

    @Test
    func notificationCandidatesAreClaimedOnlyOncePerItem() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let store = SwiftDataAttentionCacheStore(container: container)
        let record = AttentionRecord.stub(id: "assigned-issue", reasons: .assigned)
        let preferences = AttentionNotificationPreferences(
            issueReasons: .assigned,
            pullRequestReasons: []
        )
        try store.replace(with: .stub(records: [record]))

        let first = try store.takeNotificationCandidates(matching: preferences)
        let second = try store.takeNotificationCandidates(matching: preferences)
        let laterActivity = AttentionRecord.stub(
            id: "assigned-issue",
            updatedAt: record.updatedAt,
            lastActivityAt: record.lastActivityAt.addingTimeInterval(300),
            reasons: .assigned
        )
        try store.replace(with: .stub(records: [laterActivity]))
        let afterUpdate = try store.takeNotificationCandidates(matching: preferences)

        #expect(first.map(\.nodeID) == ["assigned-issue"])
        #expect(second.isEmpty)
        #expect(afterUpdate.isEmpty)
        let item = try container.mainContext.fetch(FetchDescriptor<AttentionItem>()).first
        #expect(item?.hasBeenNotified == true)
        #expect(item?.lastActivityAt == laterActivity.lastActivityAt)
    }

    @Test
    func notificationBaselineMarksCurrentItemsButLeavesFutureItemsEligible() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let store = SwiftDataAttentionCacheStore(container: container)
        let existing = AttentionRecord.stub(id: "existing", reasons: .assigned)
        let preferences = AttentionNotificationPreferences(
            issueReasons: .assigned,
            pullRequestReasons: []
        )
        try store.replace(with: .stub(records: [existing]))

        try store.establishNotificationBaseline(matching: preferences)
        let future = AttentionRecord.stub(id: "future", number: 2, reasons: .assigned)
        try store.replace(with: .stub(records: [existing, future]))
        let candidates = try store.takeNotificationCandidates(matching: preferences)

        #expect(candidates.map(\.nodeID) == ["future"])
    }

    @Test
    func notificationCandidatesRespectKindSpecificReasons() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let store = SwiftDataAttentionCacheStore(container: container)
        let records = [
            AttentionRecord.stub(id: "authored-issue", kind: .issue, reasons: .authored),
            AttentionRecord.stub(id: "assigned-issue", kind: .issue, reasons: .assigned),
            AttentionRecord.stub(
                id: "review-pr",
                kind: .pullRequest,
                reasons: .reviewRequested
            ),
            AttentionRecord.stub(id: "assigned-pr", kind: .pullRequest, reasons: .assigned),
        ]
        try store.replace(with: .stub(records: records))
        let preferences = AttentionNotificationPreferences(
            issueReasons: .authored,
            pullRequestReasons: .reviewRequested
        )

        let candidates = try store.takeNotificationCandidates(matching: preferences)

        #expect(Set(candidates.map(\.nodeID)) == ["authored-issue", "review-pr"])
    }

    @Test
    func notificationClaimSaveFailureRollsBackNotifiedState() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let store = SwiftDataAttentionCacheStore(container: container)
        try store.replace(with: .stub(records: [.stub(id: "issue", reasons: .mentioned)]))
        let preferences = AttentionNotificationPreferences(
            issueReasons: .mentioned,
            pullRequestReasons: []
        )
        let failingStore = SwiftDataAttentionCacheStore(
            container: container,
            saveContext: { _ in throw StubError.expected }
        )

        #expect(throws: StubError.expected) {
            try failingStore.takeNotificationCandidates(matching: preferences)
        }

        let candidates = try store.takeNotificationCandidates(matching: preferences)
        #expect(candidates.map(\.nodeID) == ["issue"])
    }
}
