import Foundation

protocol GitHubAttentionFetching {
    func viewerLogin(token: String) async throws -> String
    func fetchAttention(for expectedLogin: String, token: String) async throws -> AttentionSnapshot
}

@MainActor
final class GitHubAPIClient: GitHubAttentionFetching {
    static let pageSize = 100
    static let maximumItemsPerReason = 1_000

    private let transport: HTTPTransporting
    private let decoder: JSONDecoder

    init(transport: HTTPTransporting) {
        self.transport = transport
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func viewerLogin(token: String) async throws -> String {
        let request = GraphQLRequest(
            query: "query { viewer { login } }",
            variables: [:]
        )
        let response: GraphQLResponse<ViewerData> = try await execute(request, token: token)
        return try requireData(response).viewer.login
    }

    func fetchAttention(for expectedLogin: String, token: String) async throws -> AttentionSnapshot {
        let descriptors = AttentionSearchDescriptor.all(for: expectedLogin)
        let variables = Dictionary(
            uniqueKeysWithValues: descriptors.enumerated().map { index, descriptor in
                ("q\(index)", descriptor.query)
            }
        )
        let request = GraphQLRequest(query: Self.initialQuery, variables: variables)
        let response: GraphQLResponse<InitialSearchData> = try await execute(request, token: token)
        let initial = try requireData(response)

        guard initial.viewer.login.caseInsensitiveCompare(expectedLogin) == .orderedSame else {
            throw GitHubAPIError.accountChanged(expected: expectedLogin, actual: initial.viewer.login)
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
                    throw GitHubAPIError.invalidPagination
                }

                let page = try await fetchPage(query: descriptor.query, cursor: cursor, token: token)
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
                    existing.reasons.formUnion(incoming.reasons)
                    recordsByID[incoming.nodeID] = existing
                } else {
                    recordsByID[incoming.nodeID] = incoming
                }
            }
        }

        let records = recordsByID.values.sorted(by: Self.stableAttentionSort)
        return AttentionSnapshot(
            records: records,
            accountLogin: initial.viewer.login,
            fetchedAt: Date(),
            truncatedReasons: truncatedReasons,
            rateLimit: latestRateLimit
        )
    }

    static func stableAttentionSort(_ lhs: AttentionRecord, _ rhs: AttentionRecord) -> Bool {
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        let repositoryOrder = lhs.repositoryName.localizedStandardCompare(rhs.repositoryName)
        if repositoryOrder != .orderedSame {
            return repositoryOrder == .orderedAscending
        }
        return lhs.number < rhs.number
    }

    private func fetchPage(query: String, cursor: String, token: String) async throws -> PageSearchData {
        let request = GraphQLRequest(
            query: Self.pageQuery,
            variables: ["query": query, "cursor": cursor]
        )
        let response: GraphQLResponse<PageSearchData> = try await execute(request, token: token)
        return try requireData(response)
    }

    private func execute<T: Decodable>(
        _ graphQLRequest: GraphQLRequest,
        token: String
    ) async throws -> GraphQLResponse<T> {
        var request = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(graphQLRequest)

        let (data, response) = try await transport.data(for: request)
        switch response.statusCode {
        case 200:
            break
        case 401:
            throw GitHubAPIError.unauthorized
        case 403, 429:
            let resetAt = response.value(forHTTPHeaderField: "x-ratelimit-reset")
                .flatMap(TimeInterval.init)
                .map(Date.init(timeIntervalSince1970:))
            throw GitHubAPIError.rateLimited(resetAt: resetAt)
        default:
            throw GitHubAPIError.httpStatus(response.statusCode)
        }

        do {
            return try decoder.decode(GraphQLResponse<T>.self, from: data)
        } catch {
            throw GitHubAPIError.invalidResponse
        }
    }

    private func requireData<T>(_ response: GraphQLResponse<T>) throws -> T {
        if let errors = response.errors, !errors.isEmpty {
            throw GitHubAPIError.graphQL(errors.map(\.message).joined(separator: "\n"))
        }
        guard let data = response.data else {
            throw GitHubAPIError.invalidResponse
        }
        return data
    }

    private static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "AttentionSeaker/\(version)"
    }

    private static let nodeFields = """
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

enum GitHubAPIError: LocalizedError, Equatable {
    case unauthorized
    case rateLimited(resetAt: Date?)
    case httpStatus(Int)
    case graphQL(String)
    case invalidResponse
    case invalidPagination
    case unexpectedNodeType(String)
    case accountChanged(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Your GitHub authorization is no longer valid. Connect GitHub again."
        case .rateLimited(let resetAt):
            if let resetAt {
                return "GitHub's API rate limit was reached. It resets \(resetAt.formatted(.relative(presentation: .named)))."
            }
            return "GitHub's API rate limit was reached."
        case .httpStatus(let status):
            return "GitHub returned HTTP status \(status)."
        case .graphQL(let message):
            return message
        case .invalidResponse:
            return "GitHub returned data the app could not read."
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
            throw GitHubAPIError.unexpectedNodeType(typeName)
        }
        guard kind == expectedKind else {
            throw GitHubAPIError.unexpectedNodeType(typeName)
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
            isDraft: isDraft ?? false,
            reasons: reason
        )
    }
}

private struct SearchAuthor: Decodable {
    let login: String
}

private struct SearchRepository: Decodable {
    let nameWithOwner: String
}

