import Foundation

protocol GitHubAttentionFetching {
    var executableURL: URL? { get }
    func viewerLogin() async throws -> String
    func fetchAttention(for expectedLogin: String) async throws -> AttentionSnapshot
}

@MainActor
final class GitHubCLIClient: GitHubAttentionFetching {
    static let pageSize = 100
    static let maximumItemsPerReason = 1_000

    private let executor: GitHubCLIExecuting
    private let decoder: JSONDecoder

    init(executor: GitHubCLIExecuting) {
        self.executor = executor
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    var executableURL: URL? {
        executor.executableURL
    }

    func viewerLogin() async throws -> String {
        let request = GraphQLRequest(
            query: "query { viewer { login } }",
            variables: [:]
        )
        let response: GraphQLResponse<ViewerData> = try await execute(request)
        return try requireData(response).viewer.login
    }

    func fetchAttention(for expectedLogin: String) async throws -> AttentionSnapshot {
        let descriptors = AttentionSearchDescriptor.all(for: expectedLogin)
        let variables = Dictionary(
            uniqueKeysWithValues: descriptors.enumerated().map { index, descriptor in
                ("q\(index)", descriptor.query)
            }
        )
        let request = GraphQLRequest(query: Self.initialQuery, variables: variables)
        let response: GraphQLResponse<InitialSearchData> = try await execute(request)
        let initial = try requireData(response)

        guard initial.viewer.login.caseInsensitiveCompare(expectedLogin) == .orderedSame else {
            throw GitHubCLIError.accountChanged(expected: expectedLogin, actual: initial.viewer.login)
        }

        let initialConnections = [
            initial.assignedIssues,
            initial.authoredIssues,
            initial.mentionedIssues,
            initial.assignedPRs,
            initial.authoredPRs,
            initial.reviewPRs,
            initial.mentionedPRs,
        ]

        var recordsByID: [String: AttentionRecord] = [:]
        var truncatedReasons: AttentionReason = []
        var latestRateLimit = RateLimitInfo(
            remaining: initial.rateLimit.remaining,
            resetAt: initial.rateLimit.resetAt
        )

        for (descriptor, initialConnection) in zip(descriptors, initialConnections) {
            var connection = initialConnection
            var nodes = connection.nodes

            while connection.pageInfo.hasNextPage && nodes.count < Self.maximumItemsPerReason {
                guard let cursor = connection.pageInfo.endCursor else {
                    throw GitHubCLIError.invalidPagination
                }

                let page = try await fetchPage(query: descriptor.query, cursor: cursor)
                connection = page.search
                latestRateLimit = RateLimitInfo(
                    remaining: page.rateLimit.remaining,
                    resetAt: page.rateLimit.resetAt
                )
                nodes.append(contentsOf: connection.nodes)
            }

            if nodes.count > Self.maximumItemsPerReason {
                nodes = Array(nodes.prefix(Self.maximumItemsPerReason))
            }
            if connection.pageInfo.hasNextPage || initialConnection.issueCount > nodes.count {
                truncatedReasons.insert(descriptor.reason)
            }

            for node in nodes {
                let incoming = try node.record(reason: descriptor.reason, expectedKind: descriptor.kind)
                if var existing = recordsByID[incoming.nodeID] {
                    let combinedReasons = existing.reasons.union(incoming.reasons)
                    if incoming.lastActivityAt > existing.lastActivityAt {
                        var newest = incoming
                        newest.reasons = combinedReasons
                        recordsByID[incoming.nodeID] = newest
                    } else {
                        existing.reasons = combinedReasons
                        recordsByID[incoming.nodeID] = existing
                    }
                } else {
                    recordsByID[incoming.nodeID] = incoming
                }
            }
        }

        return AttentionSnapshot(
            records: recordsByID.values.sorted(by: Self.stableAttentionSort),
            accountLogin: initial.viewer.login,
            fetchedAt: Date(),
            truncatedReasons: truncatedReasons,
            rateLimit: latestRateLimit
        )
    }

    static func stableAttentionSort(_ lhs: AttentionRecord, _ rhs: AttentionRecord) -> Bool {
        if lhs.lastActivityAt != rhs.lastActivityAt {
            return lhs.lastActivityAt > rhs.lastActivityAt
        }
        let repositoryOrder = lhs.repositoryName.localizedStandardCompare(rhs.repositoryName)
        if repositoryOrder != .orderedSame {
            return repositoryOrder == .orderedAscending
        }
        return lhs.number < rhs.number
    }

    private func fetchPage(query: String, cursor: String) async throws -> PageSearchData {
        let request = GraphQLRequest(
            query: Self.pageQuery,
            variables: ["query": query, "cursor": cursor]
        )
        let response: GraphQLResponse<PageSearchData> = try await execute(request)
        return try requireData(response)
    }

    private func execute<T: Decodable>(_ request: GraphQLRequest) async throws -> GraphQLResponse<T> {
        let input = try JSONEncoder().encode(request)
        let result = try await executor.run(
            arguments: ["api", "graphql", "--input", "-"],
            standardInput: input
        )

        guard result.terminationStatus == 0 else {
            throw classifyFailure(result)
        }

        do {
            return try decoder.decode(GraphQLResponse<T>.self, from: result.standardOutput)
        } catch {
            throw GitHubCLIError.invalidResponse
        }
    }

    private func classifyFailure(_ result: GitHubCLIResult) -> GitHubCLIError {
        let output = String(data: result.standardOutput, encoding: .utf8) ?? ""
        let message = (result.standardError + "\n" + output).lowercased()
        if message.contains("auth login")
            || message.contains("not logged")
            || message.contains("bad credentials")
            || message.contains("authentication token")
            || message.contains("http 401") {
            return .notAuthenticated
        }
        if message.contains("rate limit") || message.contains("http 429") {
            return .rateLimited(resetAt: nil)
        }
        return .commandFailed(status: result.terminationStatus)
    }

    private func requireData<T>(_ response: GraphQLResponse<T>) throws -> T {
        if let errors = response.errors, !errors.isEmpty {
            let message = errors.map(\.message).joined(separator: "\n")
            if message.localizedCaseInsensitiveContains("rate limit") {
                throw GitHubCLIError.rateLimited(resetAt: nil)
            }
            throw GitHubCLIError.graphQL(message)
        }
        guard let data = response.data else {
            throw GitHubCLIError.invalidResponse
        }
        return data
    }

    static let nodeFields = """
        nodes {
          __typename
          ... on Issue {
            id
            number
            title
            url
            author { login }
            createdAt
            updatedAt
            timelineItems(last: 1) { updatedAt }
            repository { nameWithOwner }
          }
          ... on PullRequest {
            id
            number
            title
            url
            author { login }
            createdAt
            updatedAt
            timelineItems(last: 1) { updatedAt }
            isDraft
            repository { nameWithOwner }
          }
        }
        issueCount
        pageInfo { hasNextPage endCursor }
        """

    private static let initialQuery = """
        query($q0: String!, $q1: String!, $q2: String!, $q3: String!, $q4: String!, $q5: String!, $q6: String!) {
          viewer { login }
          rateLimit { remaining resetAt }
          assignedIssues: search(query: $q0, type: ISSUE, first: 100) { \(nodeFields) }
          authoredIssues: search(query: $q1, type: ISSUE, first: 100) { \(nodeFields) }
          mentionedIssues: search(query: $q2, type: ISSUE, first: 100) { \(nodeFields) }
          assignedPRs: search(query: $q3, type: ISSUE, first: 100) { \(nodeFields) }
          authoredPRs: search(query: $q4, type: ISSUE, first: 100) { \(nodeFields) }
          reviewPRs: search(query: $q5, type: ISSUE, first: 100) { \(nodeFields) }
          mentionedPRs: search(query: $q6, type: ISSUE, first: 100) { \(nodeFields) }
        }
        """

    private static let pageQuery = """
        query($query: String!, $cursor: String!) {
          rateLimit { remaining resetAt }
          search(query: $query, type: ISSUE, first: 100, after: $cursor) { \(nodeFields) }
        }
        """
}

enum GitHubCLIError: LocalizedError, Equatable {
    case executableNotFound
    case notAuthenticated
    case commandFailed(status: Int32)
    case rateLimited(resetAt: Date?)
    case graphQL(String)
    case invalidResponse
    case invalidPagination
    case unexpectedNodeType(String)
    case accountChanged(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "GitHub CLI was not found. Install gh with Homebrew, then try again."
        case .notAuthenticated:
            return "GitHub CLI is not authenticated. Run gh auth login, then try again."
        case .commandFailed(let status):
            return "GitHub CLI exited with status \(status)."
        case .rateLimited(let resetAt):
            if let resetAt {
                return "GitHub's API rate limit was reached. It resets \(resetAt.formatted(.relative(presentation: .named)))."
            }
            return "GitHub's API rate limit was reached."
        case .graphQL(let message):
            return message
        case .invalidResponse:
            return "GitHub CLI returned data the app could not read."
        case .invalidPagination:
            return "GitHub returned an invalid pagination cursor."
        case .unexpectedNodeType(let type):
            return "GitHub returned an unexpected search result type: \(type)."
        case .accountChanged:
            return "The authenticated GitHub account changed during refresh."
        }
    }
}

private struct GraphQLRequest: Encodable {
    let query: String
    let variables: [String: String]
}

private struct GraphQLResponse<Payload: Decodable>: Decodable {
    let data: Payload?
    let errors: [GraphQLError]?
}

private struct GraphQLError: Decodable {
    let message: String
}

private struct ViewerData: Decodable {
    let viewer: Viewer
}

private struct Viewer: Decodable {
    let login: String
}

private struct InitialSearchData: Decodable {
    let viewer: Viewer
    let rateLimit: GraphQLRateLimit
    let assignedIssues: SearchConnection
    let authoredIssues: SearchConnection
    let mentionedIssues: SearchConnection
    let assignedPRs: SearchConnection
    let authoredPRs: SearchConnection
    let reviewPRs: SearchConnection
    let mentionedPRs: SearchConnection
}

private struct PageSearchData: Decodable {
    let rateLimit: GraphQLRateLimit
    let search: SearchConnection
}

private struct GraphQLRateLimit: Decodable {
    let remaining: Int
    let resetAt: Date
}

private struct SearchConnection: Decodable {
    let nodes: [SearchNode]
    let issueCount: Int
    let pageInfo: PageInfo
}

private struct PageInfo: Decodable {
    let hasNextPage: Bool
    let endCursor: String?
}

private struct SearchNode: Decodable {
    let typeName: String
    let id: String
    let number: Int
    let title: String
    let url: URL
    let author: SearchAuthor?
    let createdAt: Date
    let updatedAt: Date
    let timelineItems: TimelineSummary
    let isDraft: Bool?
    let repository: SearchRepository

    enum CodingKeys: String, CodingKey {
        case typeName = "__typename"
        case id
        case number
        case title
        case url
        case author
        case createdAt
        case updatedAt
        case timelineItems
        case isDraft
        case repository
    }

    func record(reason: AttentionReason, expectedKind: AttentionKind) throws -> AttentionRecord {
        let kind: AttentionKind
        switch typeName {
        case "Issue":
            kind = .issue
        case "PullRequest":
            kind = .pullRequest
        default:
            throw GitHubCLIError.unexpectedNodeType(typeName)
        }
        guard kind == expectedKind else {
            throw GitHubCLIError.unexpectedNodeType(typeName)
        }

        return AttentionRecord(
            nodeID: id,
            kind: kind,
            repositoryName: repository.nameWithOwner,
            number: number,
            title: title,
            url: url,
            authorLogin: author?.login,
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastActivityAt: timelineItems.updatedAt,
            isDraft: isDraft ?? false,
            reasons: reason
        )
    }
}

private struct TimelineSummary: Decodable {
    let updatedAt: Date
}

private struct SearchAuthor: Decodable {
    let login: String
}

private struct SearchRepository: Decodable {
    let nameWithOwner: String
}
