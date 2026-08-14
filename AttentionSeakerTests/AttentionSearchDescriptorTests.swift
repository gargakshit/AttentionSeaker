import Foundation
import Testing
@testable import AttentionSeaker

@MainActor
struct AttentionSearchDescriptorTests {
    @Test
    func buildsTheSevenExactQueries() {
        let descriptors = AttentionSearchDescriptor.all(for: "octocat")

        #expect(descriptors.count == 7)
        #expect(descriptors.map(\.query) == [
            "is:open is:issue archived:false assignee:octocat sort:updated-desc",
            "is:open is:issue archived:false author:octocat sort:updated-desc",
            "is:open is:issue archived:false mentions:octocat in:comments sort:updated-desc",
            "is:open is:pr archived:false assignee:octocat sort:updated-desc",
            "is:open is:pr archived:false author:octocat sort:updated-desc",
            "is:open is:pr archived:false review-requested:octocat sort:updated-desc",
            "is:open is:pr archived:false mentions:octocat in:comments sort:updated-desc",
        ])
        #expect(descriptors[5].reason == .reviewRequested)
        #expect(descriptors[2].query.contains("in:comments"))
        #expect(descriptors[6].query.contains("in:comments"))
    }

    @Test
    func validatesRefreshIntervalBounds() {
        #expect(AppController.validatedRefreshInterval(4) == 5)
        #expect(AppController.validatedRefreshInterval(5) == 5)
        #expect(AppController.validatedRefreshInterval(1_440) == 1_440)
        #expect(AppController.validatedRefreshInterval(1_441) == 1_440)
    }

    @Test
    func stableSortUsesDateThenRepositoryThenNumber() {
        let date = Date(timeIntervalSince1970: 10)
        let records = [
            AttentionRecord.stub(id: "3", repository: "b/repo", number: 1, updatedAt: date),
            AttentionRecord.stub(id: "2", repository: "a/repo", number: 2, updatedAt: date),
            AttentionRecord.stub(id: "1", repository: "a/repo", number: 1, updatedAt: date),
            AttentionRecord.stub(id: "4", repository: "z/repo", number: 1, updatedAt: date.addingTimeInterval(1)),
        ]

        let sorted = records.sorted(by: GitHubCLIClient.stableAttentionSort)
        #expect(sorted.map(\.nodeID) == ["4", "1", "2", "3"])
    }
}
