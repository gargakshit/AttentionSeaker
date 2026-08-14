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

        var updatedSecond = second
        updatedSecond.reasons.formUnion(.authored)
        let third = AttentionRecord.stub(id: "third", number: 3, reasons: .reviewRequested)
        try store.replace(with: .stub(records: [updatedSecond, third]))

        items = try container.mainContext.fetch(FetchDescriptor<AttentionItem>())
        #expect(Set(items.map(\.nodeID)) == ["second", "third"])
        #expect(items.first(where: { $0.nodeID == "second" })?.reasons == [.mentioned, .authored])
        let insertedMetadata = try store.loadMetadata()
        #expect(insertedMetadata?.accountLogin == "octocat")
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
}
