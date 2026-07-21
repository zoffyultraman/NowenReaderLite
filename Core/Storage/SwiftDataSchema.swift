import Foundation
import SwiftData

// MARK: - Versioned Schema

enum SchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [CachedComic.self, ServerRecord.self, SavedAccount.self]
    }
}

enum SchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        [CachedComic.self, ServerRecord.self, SavedAccount.self, DownloadedComicRecord.self]
    }
}

// MARK: - Migration Plan

enum ReaderMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [SchemaV1.self, SchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [] // lightweight migration 自动处理，无需显式阶段
    }
}

// MARK: - ModelContext 扩展

extension ModelContext {
    /// 安全保存，失败时记录日志
    func saveOrLog(label: String = "") {
        do {
            try save()
        } catch {
            AppLogger.error("SwiftData 保存失败\(label.isEmpty ? "" : " (\(label))"): \(error)")
        }
    }

    /// 安全 fetch，失败时记录日志并返回空数组
    func fetchOrLog<T>(_ descriptor: FetchDescriptor<T>, label: String = "") -> [T] {
        do {
            return try fetch(descriptor)
        } catch {
            AppLogger.error("SwiftData 查询失败\(label.isEmpty ? "" : " (\(label))"): \(error)")
            return []
        }
    }
}

extension Date {
    var iso8601String: String {
        ISO8601DateFormatter().string(from: self)
    }

    static func fromISO8601(_ string: String) -> Date? {
        ISO8601DateFormatter().date(from: string)
    }
}

@Model
final class CachedComic {
    @Attribute(.unique) var id: String
    var title: String
    var author: String?
    var coverUrl: String?
    var pageCount: Int
    var lastReadPage: Int
    var isFavorite: Bool
    var readingStatus: String?
    var rating: Double?
    var type: String?
    var progress: Int
    var lastReadAt: Date?
    var cachedAt: Date

    init() {
        self.id = ""
        self.title = ""
        self.pageCount = 0
        self.lastReadPage = 0
        self.isFavorite = false
        self.progress = 0
        self.cachedAt = Date()
    }

    static func from(_ comic: Comic) -> CachedComic {
        let c = CachedComic()
        c.id = comic.id
        c.title = comic.title
        c.author = comic.author
        c.coverUrl = comic.coverUrl
        c.pageCount = comic.pageCount
        c.lastReadPage = comic.lastReadPage
        c.isFavorite = comic.isFavorite
        c.readingStatus = comic.readingStatus
        c.rating = comic.rating
        c.type = comic.type
        c.progress = comic.progress
        c.lastReadAt = comic.lastReadAt.flatMap { Date.fromISO8601($0) }
        c.cachedAt = Date()
        return c
    }

    /// 转换为 Comic 模型（部分字段使用默认值）
    func toComic() -> Comic {
        Comic(
            id: id,
            title: title,
            author: author,
            publisher: nil,
            description: nil,
            genre: nil,
            language: nil,
            year: nil,
            pageCount: pageCount,
            fileSize: nil,
            lastReadPage: lastReadPage,
            totalReadTime: nil,
            readingStatus: readingStatus,
            lastReadAt: lastReadAt?.iso8601String,
            metadataSource: nil,
            coverUrl: coverUrl,
            coverAspectRatio: nil,
            rating: rating,
            isFavorite: isFavorite,
            type: type,
            filename: nil,
            titleSortKey: nil,
            sortOrder: nil,
            tags: nil,
            categories: nil
        )
    }
}

@Model
final class ServerRecord: Identifiable {
    var id: String { url }
    @Attribute(.unique) var url: String
    var username: String?
    var lastUsed: Date
    @Relationship(inverse: \SavedAccount.boundServers)
    var boundAccount: SavedAccount?

    /// 兼容旧代码的便捷访问
    var boundAccountId: String? { boundAccount?.id }

    init(url: String, username: String? = nil) {
        self.url = url
        self.username = username
        self.lastUsed = Date()
    }
}

@Model
final class SavedAccount: Identifiable {
    @Attribute(.unique) var id: String
    var alias: String
    var username: String
    var lastUsed: Date?
    @Relationship
    var boundServers: [ServerRecord] = []

    init(alias: String, username: String) {
        self.id = UUID().uuidString
        self.alias = alias
        self.username = username
    }
}

// MARK: - 离线下载记录

@Model
final class DownloadedComicRecord {
    @Attribute(.unique) var comicId: String
    var title: String
    var pageCount: Int
    var state: String       // DownloadState.rawValue
    var downloadedAt: Date

    init(comicId: String, title: String, pageCount: Int, state: String) {
        self.comicId = comicId
        self.title = title
        self.pageCount = pageCount
        self.state = state
        self.downloadedAt = Date()
    }
}
