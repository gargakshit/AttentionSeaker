import Foundation

struct AttentionSearchDescriptor: Identifiable, Equatable, Sendable {
    let alias: String
    let kind: AttentionKind
    let reason: AttentionReason
    let query: String

    var id: String { alias }

    static func all(for login: String) -> [AttentionSearchDescriptor] {
        [
            AttentionSearchDescriptor(
                alias: "assignedIssues",
                kind: .issue,
                reason: .assigned,
                query: "is:open is:issue archived:false assignee:\(login) sort:updated-desc"
            ),
            AttentionSearchDescriptor(
                alias: "authoredIssues",
                kind: .issue,
                reason: .authored,
                query: "is:open is:issue archived:false author:\(login) sort:updated-desc"
            ),
            AttentionSearchDescriptor(
                alias: "mentionedIssues",
                kind: .issue,
                reason: .mentioned,
                query: "is:open is:issue archived:false mentions:\(login) in:comments sort:updated-desc"
            ),
            AttentionSearchDescriptor(
                alias: "assignedPRs",
                kind: .pullRequest,
                reason: .assigned,
                query: "is:open is:pr archived:false assignee:\(login) sort:updated-desc"
            ),
            AttentionSearchDescriptor(
                alias: "authoredPRs",
                kind: .pullRequest,
                reason: .authored,
                query: "is:open is:pr archived:false author:\(login) sort:updated-desc"
            ),
            AttentionSearchDescriptor(
                alias: "reviewPRs",
                kind: .pullRequest,
                reason: .reviewRequested,
                query: "is:open is:pr archived:false review-requested:\(login) sort:updated-desc"
            ),
            AttentionSearchDescriptor(
                alias: "mentionedPRs",
                kind: .pullRequest,
                reason: .mentioned,
                query: "is:open is:pr archived:false mentions:\(login) in:comments sort:updated-desc"
            ),
        ]
    }
}

