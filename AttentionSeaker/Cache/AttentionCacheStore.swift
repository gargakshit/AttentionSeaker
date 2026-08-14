import Foundation
import SwiftData

@MainActor
protocol AttentionCacheStoring {
    func loadMetadata() throws -> CachedMetadata?
    func replace(with snapshot: AttentionSnapshot) throws
    func clear() throws
}

@MainActor
final class SwiftDataAttentionCacheStore: AttentionCacheStoring {
    private let context: ModelContext
    private let saveContext: (ModelContext) throws -> Void

    init(
        container: ModelContainer,
        saveContext: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) {
        context = container.mainContext
        self.saveContext = saveContext
        context.autosaveEnabled = false
    }

    func loadMetadata() throws -> CachedMetadata? {
        let descriptor = FetchDescriptor<CacheMetadata>()
        guard let metadata = try context.fetch(descriptor).first else {
            return nil
        }
        return CachedMetadata(
            accountLogin: metadata.accountLogin,
            lastSuccessfulRefreshAt: metadata.lastSuccessfulRefreshAt,
            truncatedReasons: AttentionReason(rawValue: metadata.truncatedReasonsRawValue)
        )
    }

    func replace(with snapshot: AttentionSnapshot) throws {
        do {
            let existingItems = try context.fetch(FetchDescriptor<AttentionItem>())
            let existingMetadata = try context.fetch(FetchDescriptor<CacheMetadata>())

            if let oldAccount = existingMetadata.first?.accountLogin,
               oldAccount.caseInsensitiveCompare(snapshot.accountLogin) != .orderedSame {
                existingItems.forEach(context.delete)
            }

            let retainedItems: [AttentionItem]
            if let oldAccount = existingMetadata.first?.accountLogin,
               oldAccount.caseInsensitiveCompare(snapshot.accountLogin) == .orderedSame {
                retainedItems = existingItems
            } else {
                retainedItems = []
            }

            var existingByID = Dictionary(
                uniqueKeysWithValues: retainedItems.map { ($0.nodeID, $0) }
            )
            let incomingIDs = Set(snapshot.records.map(\.nodeID))

            for item in retainedItems where !incomingIDs.contains(item.nodeID) {
                context.delete(item)
            }

            for record in snapshot.records {
                if let item = existingByID.removeValue(forKey: record.nodeID) {
                    item.update(from: record)
                } else {
                    context.insert(AttentionItem(record: record))
                }
            }

            let metadata: CacheMetadata
            if let first = existingMetadata.first {
                metadata = first
                for duplicate in existingMetadata.dropFirst() {
                    context.delete(duplicate)
                }
            } else {
                metadata = CacheMetadata(
                    accountLogin: snapshot.accountLogin,
                    lastSuccessfulRefreshAt: snapshot.fetchedAt,
                    truncatedReasons: snapshot.truncatedReasons
                )
                context.insert(metadata)
            }
            metadata.accountLogin = snapshot.accountLogin
            metadata.lastSuccessfulRefreshAt = snapshot.fetchedAt
            metadata.truncatedReasonsRawValue = snapshot.truncatedReasons.rawValue
            metadata.schemaVersion = 1

            try saveContext(context)
        } catch {
            context.rollback()
            throw error
        }
    }

    func clear() throws {
        do {
            try context.fetch(FetchDescriptor<AttentionItem>()).forEach(context.delete)
            try context.fetch(FetchDescriptor<CacheMetadata>()).forEach(context.delete)
            try saveContext(context)
        } catch {
            context.rollback()
            throw error
        }
    }
}
