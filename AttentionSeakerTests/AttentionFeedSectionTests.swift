import Testing
@testable import AttentionSeaker

@MainActor
struct AttentionFeedSectionTests {
    @Test
    func streamIncludesEveryAttentionItem() {
        #expect(AttentionFeedSection.stream.includes(kind: .pullRequest, reasons: .assigned))
        #expect(AttentionFeedSection.stream.includes(kind: .issue, reasons: .authored))
    }

    @Test
    func pullRequestsIncludeOnlyReviewMentionAndAuthoredReasons() {
        let section = AttentionFeedSection.pullRequests

        #expect(section.includes(kind: .pullRequest, reasons: .reviewRequested))
        #expect(section.includes(kind: .pullRequest, reasons: .mentioned))
        #expect(section.includes(kind: .pullRequest, reasons: .authored))
        #expect(section.includes(kind: .pullRequest, reasons: [.assigned, .mentioned]))
        #expect(!section.includes(kind: .pullRequest, reasons: .assigned))
        #expect(!section.includes(kind: .issue, reasons: .reviewRequested))
    }

    @Test
    func issuesIncludeAssignedMentionedAndAuthoredReasons() {
        let section = AttentionFeedSection.issues

        #expect(section.includes(kind: .issue, reasons: .assigned))
        #expect(section.includes(kind: .issue, reasons: .mentioned))
        #expect(section.includes(kind: .issue, reasons: .authored))
        #expect(section.includes(kind: .issue, reasons: [.authored, .assigned]))
        #expect(!section.includes(kind: .issue, reasons: .reviewRequested))
        #expect(!section.includes(kind: .pullRequest, reasons: .mentioned))
    }
}
