import Foundation
import Testing
@testable import AttentionSeaker

@MainActor
struct GitHubAPIClientTests {
    @Test
    func decodesNullableAuthorsAndMergesReasonsByNodeID() async throws {
        let issue = node(
            id: "I_1",
            type: "Issue",
            number: 7,
            repository: "owner/repo",
            author: nil
        )
        let payload = initialPayload(connections: [
            "assignedIssues": connection(nodes: [issue], total: 1),
            "mentionedIssues": connection(nodes: [issue], total: 1),
        ])
        let transport = StubHTTPTransport(stubs: [jsonStub(payload)])
        let client = GitHubAPIClient(transport: transport)

        let snapshot = try await client.fetchAttention(for: "octocat", token: "token")

        #expect(snapshot.records.count == 1)
        #expect(snapshot.records[0].authorLogin == nil)
        #expect(snapshot.records[0].reasons == [.assigned, .mentioned])
        #expect(snapshot.accountLogin == "octocat")
        #expect(transport.requests.count == 1)
    }

    @Test
    func decodesDraftPullRequestsWithDeletedAuthors() async throws {
        var pullRequest = node(
            id: "PR_1",
            type: "PullRequest",
            number: 12,
            repository: "owner/repo",
            author: nil
        )
        pullRequest["isDraft"] = true
        let payload = initialPayload(connections: [
            "reviewPRs": connection(nodes: [pullRequest], total: 1),
            "mentionedPRs": connection(nodes: [pullRequest], total: 1),
        ])
        let client = GitHubAPIClient(transport: StubHTTPTransport(stubs: [jsonStub(payload)]))

        let snapshot = try await client.fetchAttention(for: "octocat", token: "token")

        #expect(snapshot.records.count == 1)
        #expect(snapshot.records[0].kind == .pullRequest)
        #expect(snapshot.records[0].isDraft)
        #expect(snapshot.records[0].authorLogin == nil)
        #expect(snapshot.records[0].reasons == [.reviewRequested, .mentioned])
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
        let issuePage = pagePayload(connection: connection(nodes: [issueTwo], total: 2))
        let prPage = pagePayload(connection: connection(nodes: [prTwo], total: 2))
        let transport = StubHTTPTransport(stubs: [initial, issuePage, prPage].map(jsonStub))
        let client = GitHubAPIClient(transport: transport)

        let snapshot = try await client.fetchAttention(for: "octocat", token: "token")

        #expect(Set(snapshot.records.map(\.nodeID)) == ["I_1", "I_2", "PR_1", "PR_2"])
        #expect(snapshot.truncatedReasons.isEmpty)
        #expect(transport.requests.count == 3)
    }

    @Test
    func paginatesToTheDefensiveCapAndMarksTruncation() async throws {
        let firstNodes = (0..<100).map { issueNode(index: $0) }
        let firstConnection = connection(
            nodes: firstNodes,
            total: 1_001,
            hasNext: true,
            cursor: "cursor-0"
        )
        var stubs = [jsonStub(initialPayload(connections: ["assignedIssues": firstConnection]))]

        for page in 1...9 {
            let start = page * 100
            let nodes = (start..<(start + 100)).map { issueNode(index: $0) }
            let payload: [String: Any] = [
                "data": [
                    "rateLimit": rateLimit,
                    "search": connection(
                        nodes: nodes,
                        total: 1_001,
                        hasNext: true,
                        cursor: "cursor-\(page)"
                    ),
                ],
            ]
            stubs.append(jsonStub(payload))
        }

        let transport = StubHTTPTransport(stubs: stubs)
        let client = GitHubAPIClient(transport: transport)
        let snapshot = try await client.fetchAttention(for: "octocat", token: "token")

        #expect(snapshot.records.count == 1_000)
        #expect(snapshot.truncatedReasons == .assigned)
        #expect(transport.requests.count == 10)
    }

    @Test
    func rejectsGraphQLPartialFailures() async {
        var payload = initialPayload(connections: [:])
        payload["errors"] = [["message": "Search failed"]]
        let transport = StubHTTPTransport(stubs: [jsonStub(payload)])
        let client = GitHubAPIClient(transport: transport)

        await #expect(throws: GitHubAPIError.graphQL("Search failed")) {
            try await client.fetchAttention(for: "octocat", token: "token")
        }
    }

    private var aliases: [String] {
        return [
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
            "pageInfo": [
                "hasNextPage": hasNext,
                "endCursor": endCursor,
            ],
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
        author: String?
    ) -> [String: Any] {
        var value: [String: Any] = [
            "__typename": type,
            "id": id,
            "number": number,
            "title": "Item \(number)",
            "url": "https://github.com/\(repository)/issues/\(number)",
            "createdAt": "2026-08-14T10:00:00Z",
            "updatedAt": "2026-08-14T11:00:00Z",
            "repository": ["nameWithOwner": repository],
        ]
        value["author"] = author.map { ["login": $0] } ?? NSNull()
        if type == "PullRequest" {
            value["isDraft"] = false
        }
        return value
    }

    private func jsonStub(_ object: [String: Any]) -> StubHTTPTransport.Stub {
        StubHTTPTransport.Stub(
            data: try! JSONSerialization.data(withJSONObject: object),
            statusCode: 200,
            headers: [:]
        )
    }
}
