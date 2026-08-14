import Foundation
import SwiftData

enum AttentionKind: String, Codable, Sendable {
    case issue
    case pullRequest
}

struct AttentionReason: OptionSet, Codable, Hashable, Sendable {
    let rawValue: Int

    static let assigned = AttentionReason(rawValue: 1 << 0)
    static let authored = AttentionReason(rawValue: 1 << 1)
    static let reviewRequested = AttentionReason(rawValue: 1 << 2)
    static let mentioned = AttentionReason(rawValue: 1 << 3)

    static let displayOrder: [(reason: AttentionReason, title: String)] = [
        (.reviewRequested, "Review"),
        (.assigned, "Assigned"),
        (.mentioned, "Mentioned"),
        (.authored, "Authored"),
    ]
}

struct AttentionRecord: Identifiable, Equatable, Sendable {
    var id: String { nodeID }

    let nodeID: String
    let kind: AttentionKind
    let repositoryName: String
    let number: Int
    let title: String
    let url: URL
    let authorLogin: String?
    let createdAt: Date
    let updatedAt: Date
    let isDraft: Bool
    var reasons: AttentionReason
}

struct RateLimitInfo: Equatable, Sendable {
    let remaining: Int
    let resetAt: Date
}

struct AttentionSnapshot: Equatable, Sendable {
    let records: [AttentionRecord]
    let accountLogin: String
    let fetchedAt: Date
    let truncatedReasons: AttentionReason
    let rateLimit: RateLimitInfo
}

struct CachedMetadata: Equatable, Sendable {
    let accountLogin: String
    let lastSuccessfulRefreshAt: Date
    let truncatedReasons: AttentionReason
}

@Model
final class AttentionItem {
    @Attribute(.unique) var nodeID: String
    var kindRawValue: String
    var repositoryName: String
    var number: Int
    var title: String
    var urlString: String
    var authorLogin: String?
    var createdAt: Date
    var updatedAt: Date
    var isDraft: Bool
    var reasonsRawValue: Int

    init(record: AttentionRecord) {
        nodeID = record.nodeID
        kindRawValue = record.kind.rawValue
        repositoryName = record.repositoryName
        number = record.number
        title = record.title
        urlString = record.url.absoluteString
        authorLogin = record.authorLogin
        createdAt = record.createdAt
        updatedAt = record.updatedAt
        isDraft = record.isDraft
        reasonsRawValue = record.reasons.rawValue
    }

    var kind: AttentionKind {
        AttentionKind(rawValue: kindRawValue) ?? .issue
    }

    var reasons: AttentionReason {
        AttentionReason(rawValue: reasonsRawValue)
    }

    var url: URL? {
        URL(string: urlString)
    }

    func update(from record: AttentionRecord) {
        kindRawValue = record.kind.rawValue
        repositoryName = record.repositoryName
        number = record.number
        title = record.title
        urlString = record.url.absoluteString
        authorLogin = record.authorLogin
        createdAt = record.createdAt
        updatedAt = record.updatedAt
        isDraft = record.isDraft
        reasonsRawValue = record.reasons.rawValue
    }
}

@Model
final class CacheMetadata {
    @Attribute(.unique) var identifier: String
    var accountLogin: String
    var lastSuccessfulRefreshAt: Date
    var truncatedReasonsRawValue: Int
    var schemaVersion: Int

    init(
        identifier: String = CacheMetadata.singletonIdentifier,
        accountLogin: String,
        lastSuccessfulRefreshAt: Date,
        truncatedReasons: AttentionReason,
        schemaVersion: Int = 1
    ) {
        self.identifier = identifier
        self.accountLogin = accountLogin
        self.lastSuccessfulRefreshAt = lastSuccessfulRefreshAt
        truncatedReasonsRawValue = truncatedReasons.rawValue
        self.schemaVersion = schemaVersion
    }

    static let singletonIdentifier = "attention-cache"
}
