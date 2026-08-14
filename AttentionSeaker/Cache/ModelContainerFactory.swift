import Foundation
import SwiftData

enum ModelContainerFactory {
    static func makePersistentContainer() -> ModelContainer {
        let schema = Schema([
            AttentionItem.self,
            CacheMetadata.self,
        ])

        do {
            return try makeContainer(schema: schema)
        } catch {
            removeCacheStoreFiles()
            do {
                return try makeContainer(schema: schema)
            } catch {
                fatalError("Could not create the disposable AttentionSeaker cache: \(error)")
            }
        }
    }

    static func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema([
            AttentionItem.self,
            CacheMetadata.self,
        ])
        let configuration = ModelConfiguration(
            "AttentionCacheTests",
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        container.mainContext.autosaveEnabled = false
        return container
    }

    private static func makeContainer(schema: Schema) throws -> ModelContainer {
        let directory = cacheDirectory
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let configuration = ModelConfiguration(
            "AttentionCache",
            schema: schema,
            url: storeURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        container.mainContext.autosaveEnabled = false
        return container
    }

    private static var cacheDirectory: URL {
        let caches = try? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return (caches ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("AttentionSeaker", isDirectory: true)
    }

    private static var storeURL: URL {
        cacheDirectory.appendingPathComponent("AttentionCache.store")
    }

    private static func removeCacheStoreFiles() {
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: storeURL.path + suffix)
            )
        }
    }
}

