import Foundation
import Testing
@testable import AttentionSeaker

@MainActor
struct GitHubCLIClientTests {
    @Test
    func invokesGlobalGitHubCLIWithGraphQLOnStandardInput() async throws {
        let executor = StubGitHubCLIExecutor(results: [jsonResult(initialPayload(connections: [:]))])
        let client = GitHubCLIClient(executor: executor)

        _ = try await client.fetchAttention(for: "octocat")

        #expect(executor.invocations.count == 1)
        #expect(executor.invocations[0].arguments == ["api", "graphql", "--input", "-"])
        let input = try #require(executor.invocations[0].standardInput)
        let body = try #require(String(data: input, encoding: .utf8))
        #expect(body.contains("assignedIssues"))
        #expect(body.contains("review-requested:octocat"))
        #expect(
            GitHubCLIClient.nodeFields
                .components(separatedBy: "timelineItems(last: 1) { updatedAt }").count - 1 == 2
        )
        #expect(
            GitHubCLIClient.nodeFields
                .components(separatedBy: "reviewDecision").count - 1 == 1
        )
        let issueFragment = try #require(
            GitHubCLIClient.nodeFields.components(separatedBy: "... on PullRequest {").first
        )
        #expect(!issueFragment.contains("reviewDecision"))
        #expect(!body.localizedCaseInsensitiveContains("access_token"))
        #expect(!body.localizedCaseInsensitiveContains("bearer"))
    }

    @Test
    func decodesNullableAuthorsAndMergesReasonsByNodeID() async throws {
        let issue = node(id: "I_1", type: "Issue", number: 7, repository: "owner/repo", author: nil)
        let payload = initialPayload(connections: [
            "assignedIssues": connection(nodes: [issue], total: 1),
            "mentionedIssues": connection(nodes: [issue], total: 1),
        ])
        let executor = StubGitHubCLIExecutor(results: [jsonResult(payload)])
        let client = GitHubCLIClient(executor: executor)

        let snapshot = try await client.fetchAttention(for: "octocat")

        #expect(snapshot.records.count == 1)
        #expect(snapshot.records[0].authorLogin == nil)
        #expect(snapshot.records[0].reasons == [.assigned, .mentioned])
        #expect(snapshot.accountLogin == "octocat")
        #expect(!snapshot.records[0].isApproved)
        #expect(snapshot.records[0].lastActivityAt > snapshot.records[0].updatedAt)
    }

    @Test
    func decodesDraftPullRequestsWithDeletedAuthors() async throws {
        var pullRequest = node(
            id: "PR_1",
            type: "PullRequest",
            number: 12,
            repository: "owner/repo",
            author: nil,
            reviewDecision: "APPROVED"
        )
        pullRequest["isDraft"] = true
        let payload = initialPayload(connections: [
            "reviewPRs": connection(nodes: [pullRequest], total: 1),
            "mentionedPRs": connection(nodes: [pullRequest], total: 1),
        ])
        let client = GitHubCLIClient(
            executor: StubGitHubCLIExecutor(results: [jsonResult(payload)])
        )

        let snapshot = try await client.fetchAttention(for: "octocat")

        #expect(snapshot.records.count == 1)
        #expect(snapshot.records[0].kind == .pullRequest)
        #expect(snapshot.records[0].isDraft)
        #expect(snapshot.records[0].isApproved)
        #expect(snapshot.records[0].authorLogin == nil)
        #expect(snapshot.records[0].reasons == [.reviewRequested, .mentioned])
        #expect(snapshot.records[0].lastActivityAt > snapshot.records[0].updatedAt)
    }

    @Test
    func nonApprovedReviewDecisionsDecodeAsFalse() async throws {
        let pullRequests = [
            node(
                id: "PR_changes",
                type: "PullRequest",
                number: 1,
                repository: "owner/repo",
                author: "author",
                reviewDecision: "CHANGES_REQUESTED"
            ),
            node(
                id: "PR_required",
                type: "PullRequest",
                number: 2,
                repository: "owner/repo",
                author: "author",
                reviewDecision: "REVIEW_REQUIRED"
            ),
            node(
                id: "PR_null",
                type: "PullRequest",
                number: 3,
                repository: "owner/repo",
                author: "author"
            ),
            node(
                id: "PR_future",
                type: "PullRequest",
                number: 4,
                repository: "owner/repo",
                author: "author",
                reviewDecision: "FUTURE_DECISION"
            ),
        ]
        let payload = initialPayload(connections: [
            "authoredPRs": connection(nodes: pullRequests, total: pullRequests.count),
        ])
        let client = GitHubCLIClient(
            executor: StubGitHubCLIExecutor(results: [jsonResult(payload)])
        )

        let snapshot = try await client.fetchAttention(for: "octocat")

        #expect(snapshot.records.count == 4)
        #expect(snapshot.records.allSatisfy { !$0.isApproved })
    }

    @Test
    func deduplicationRetainsTheNewestTimelineActivity() async throws {
        let older = node(
            id: "I_1",
            type: "Issue",
            number: 7,
            repository: "owner/repo",
            author: "author",
            lastActivityAt: "2026-08-14T11:30:00Z"
        )
        let newer = node(
            id: "I_1",
            type: "Issue",
            number: 7,
            repository: "owner/repo",
            author: "author",
            lastActivityAt: "2026-08-14T13:00:00Z"
        )
        let payload = initialPayload(connections: [
            "assignedIssues": connection(nodes: [older], total: 1),
            "mentionedIssues": connection(nodes: [newer], total: 1),
        ])
        let client = GitHubCLIClient(
            executor: StubGitHubCLIExecutor(results: [jsonResult(payload)])
        )

        let snapshot = try await client.fetchAttention(for: "octocat")
        let expectedDate = try #require(
            ISO8601DateFormatter().date(from: "2026-08-14T13:00:00Z")
        )

        #expect(snapshot.records.count == 1)
        #expect(snapshot.records[0].lastActivityAt == expectedDate)
        #expect(snapshot.records[0].reasons == [.assigned, .mentioned])
    }

    @Test
    func deduplicationPrefersTheLaterApprovalStateWhenActivityTimestampsMatch() async throws {
        let awaitingReview = node(
            id: "PR_1",
            type: "PullRequest",
            number: 7,
            repository: "owner/repo",
            author: "author",
            reviewDecision: "REVIEW_REQUIRED"
        )
        let approved = node(
            id: "PR_1",
            type: "PullRequest",
            number: 7,
            repository: "owner/repo",
            author: "author",
            reviewDecision: "APPROVED"
        )
        let payload = initialPayload(connections: [
            "assignedPRs": connection(nodes: [awaitingReview], total: 1),
            "mentionedPRs": connection(nodes: [approved], total: 1),
        ])
        let client = GitHubCLIClient(
            executor: StubGitHubCLIExecutor(results: [jsonResult(payload)])
        )

        let snapshot = try await client.fetchAttention(for: "octocat")

        #expect(snapshot.records.count == 1)
        #expect(snapshot.records[0].isApproved)
        #expect(snapshot.records[0].reasons == [.assigned, .mentioned])
    }

    @Test
    func rejectsMissingTimelineActivity() async {
        var issue = node(
            id: "I_1",
            type: "Issue",
            number: 7,
            repository: "owner/repo",
            author: "author"
        )
        issue.removeValue(forKey: "timelineItems")
        let payload = initialPayload(connections: [
            "assignedIssues": connection(nodes: [issue], total: 1),
        ])
        let client = GitHubCLIClient(
            executor: StubGitHubCLIExecutor(results: [jsonResult(payload)])
        )

        await #expect(throws: GitHubCLIError.invalidResponse) {
            try await client.fetchAttention(for: "octocat")
        }
    }

    @Test
    func rejectsMalformedTimelineActivity() async {
        let issue = node(
            id: "I_1",
            type: "Issue",
            number: 7,
            repository: "owner/repo",
            author: "author",
            lastActivityAt: "not-a-timestamp"
        )
        let payload = initialPayload(connections: [
            "assignedIssues": connection(nodes: [issue], total: 1),
        ])
        let client = GitHubCLIClient(
            executor: StubGitHubCLIExecutor(results: [jsonResult(payload)])
        )

        await #expect(throws: GitHubCLIError.invalidResponse) {
            try await client.fetchAttention(for: "octocat")
        }
    }

    @Test
    func paginatesEachAliasIndependently() async throws {
        let issueOne = issueNode(index: 1)
        let issueTwo = issueNode(index: 2)
        let prOne = node(id: "PR_1", type: "PullRequest", number: 1, repository: "o/r", author: "a")
        let prTwo = node(id: "PR_2", type: "PullRequest", number: 2, repository: "o/r", author: "a")
        let initial = initialPayload(connections: [
            "assignedIssues": connection(nodes: [issueOne], total: 2, hasNext: true, cursor: "issue-cursor"),
            "authoredPRs": connection(nodes: [prOne], total: 2, hasNext: true, cursor: "pr-cursor"),
        ])
        let executor = StubGitHubCLIExecutor(results: [
            jsonResult(initial),
            jsonResult(pagePayload(connection: connection(nodes: [issueTwo], total: 2))),
            jsonResult(pagePayload(connection: connection(nodes: [prTwo], total: 2))),
        ])
        let client = GitHubCLIClient(executor: executor)

        let snapshot = try await client.fetchAttention(for: "octocat")

        #expect(Set(snapshot.records.map(\.nodeID)) == ["I_1", "I_2", "PR_1", "PR_2"])
        #expect(snapshot.truncatedReasons.isEmpty)
        #expect(executor.invocations.count == 3)
    }

    @Test
    func paginatesToTheDefensiveCapAndMarksTruncation() async throws {
        let firstConnection = connection(
            nodes: (0..<100).map { issueNode(index: $0) },
            total: 1_001,
            hasNext: true,
            cursor: "cursor-0"
        )
        var results = [jsonResult(initialPayload(connections: ["assignedIssues": firstConnection]))]

        for page in 1...9 {
            let start = page * 100
            let payload = pagePayload(connection: connection(
                nodes: (start..<(start + 100)).map { issueNode(index: $0) },
                total: 1_001,
                hasNext: true,
                cursor: "cursor-\(page)"
            ))
            results.append(jsonResult(payload))
        }

        let executor = StubGitHubCLIExecutor(results: results)
        let snapshot = try await GitHubCLIClient(executor: executor)
            .fetchAttention(for: "octocat")

        #expect(snapshot.records.count == 1_000)
        #expect(snapshot.truncatedReasons == .assigned)
        #expect(executor.invocations.count == 10)
    }

    @Test
    func rejectsGraphQLPartialFailures() async {
        var payload = initialPayload(connections: [:])
        payload["errors"] = [["message": "Search failed"]]
        let client = GitHubCLIClient(
            executor: StubGitHubCLIExecutor(results: [jsonResult(payload)])
        )

        await #expect(throws: GitHubCLIError.graphQL("Search failed")) {
            try await client.fetchAttention(for: "octocat")
        }
    }

    @Test
    func mapsGlobalCLIAuthenticationAndRateLimitFailures() async {
        let authClient = GitHubCLIClient(executor: StubGitHubCLIExecutor(results: [
            GitHubCLIResult(
                standardOutput: Data(),
                standardError: "To get started with GitHub CLI, run gh auth login",
                terminationStatus: 1
            ),
        ]))
        await #expect(throws: GitHubCLIError.notAuthenticated) {
            try await authClient.viewerLogin()
        }

        let rateClient = GitHubCLIClient(executor: StubGitHubCLIExecutor(results: [
            GitHubCLIResult(
                standardOutput: Data(),
                standardError: "API rate limit exceeded",
                terminationStatus: 1
            ),
        ]))
        await #expect(throws: GitHubCLIError.rateLimited(resetAt: nil)) {
            try await rateClient.viewerLogin()
        }
    }

    private var aliases: [String] {
        [
            "assignedIssues", "authoredIssues", "mentionedIssues",
            "assignedPRs", "authoredPRs", "reviewPRs", "mentionedPRs",
        ]
    }

    private var rateLimit: [String: Any] {
        ["remaining": 4_999, "resetAt": "2026-08-14T12:00:00Z"]
    }

    private func initialPayload(connections overrides: [String: [String: Any]]) -> [String: Any] {
        var data: [String: Any] = [
            "viewer": ["login": "octocat"],
            "rateLimit": rateLimit,
        ]
        for alias in aliases {
            data[alias] = overrides[alias] ?? connection(nodes: [], total: 0)
        }
        return ["data": data]
    }

    private func pagePayload(connection: [String: Any]) -> [String: Any] {
        ["data": ["rateLimit": rateLimit, "search": connection]]
    }

    private func connection(
        nodes: [[String: Any]],
        total: Int,
        hasNext: Bool = false,
        cursor: String? = nil
    ) -> [String: Any] {
        let endCursor: Any = if let cursor { cursor } else { NSNull() }
        return [
            "nodes": nodes,
            "issueCount": total,
            "pageInfo": ["hasNextPage": hasNext, "endCursor": endCursor],
        ]
    }

    private func issueNode(index: Int) -> [String: Any] {
        node(
            id: "I_\(index)",
            type: "Issue",
            number: index + 1,
            repository: "owner/repo",
            author: "author"
        )
    }

    private func node(
        id: String,
        type: String,
        number: Int,
        repository: String,
        author: String?,
        updatedAt: String = "2026-08-14T11:00:00Z",
        lastActivityAt: String = "2026-08-14T11:30:00Z",
        reviewDecision: String? = nil
    ) -> [String: Any] {
        var value: [String: Any] = [
            "__typename": type,
            "id": id,
            "number": number,
            "title": "Item \(number)",
            "url": "https://github.com/\(repository)/issues/\(number)",
            "createdAt": "2026-08-14T10:00:00Z",
            "updatedAt": updatedAt,
            "timelineItems": ["updatedAt": lastActivityAt],
            "repository": ["nameWithOwner": repository],
        ]
        value["author"] = author.map { ["login": $0] } ?? NSNull()
        if type == "PullRequest" {
            value["isDraft"] = false
            value["reviewDecision"] = reviewDecision ?? NSNull()
        }
        return value
    }

    private func jsonResult(_ object: [String: Any]) -> GitHubCLIResult {
        GitHubCLIResult(
            standardOutput: try! JSONSerialization.data(withJSONObject: object),
            standardError: "",
            terminationStatus: 0
        )
    }
}
