import Foundation

// MARK: - 漫画/小说数据模型

struct Comic: Codable, Identifiable {
    let id: String
    let title: String
    let author: String?
    let publisher: String?
    let description: String?
    let genre: String?
    let language: String?
    let year: Int?
    let pageCount: Int
    let fileSize: Int64?
    let lastReadPage: Int
    let totalReadTime: Int?
    let readingStatus: String?
    let lastReadAt: String?
    let metadataSource: String?
    let coverUrl: String?
    let coverAspectRatio: Double?
    let rating: Double?
    let isFavorite: Bool
    let type: String? // "comic" | "novel"
    let filename: String?
    let titleSortKey: String?
    let sortOrder: Int?
    let tags: [TagItem]?
    let categories: [CategoryItem]?

    var progress: Int {
        guard pageCount > 0 else { return 0 }
        return min(100, Int(Double(lastReadPage + 1) / Double(pageCount) * 100))
    }

    var isNovel: Bool { type?.lowercased() == "novel" }
    var isSeriesShelfItem: Bool { id.hasPrefix(Self.seriesShelfPrefix) }
    var seriesId: String? { Self.seriesId(from: id) }
    var sortTitle: String {
        guard let titleSortKey, !titleSortKey.isEmpty else { return title }
        return titleSortKey
    }

    var seriesProgress: Int {
        guard isSeriesShelfItem, pageCount > 0 else { return progress }
        guard lastReadAt != nil || lastReadPage > 0 else { return 0 }
        let currentItem = min(max(lastReadPage + 1, 0), pageCount)
        return min(100, Int(Double(currentItem) / Double(pageCount) * 100))
    }

    enum ContentType: String {
        case comic, novel
    }

    var contentType: ContentType? {
        guard let type else { return nil }
        return ContentType(rawValue: type.lowercased())
    }

    enum CodingKeys: String, CodingKey {
        case id, title, author, publisher, description, genre, language
        case year, pageCount, fileSize, lastReadPage, totalReadTime
        case readingStatus, lastReadAt, metadataSource, coverUrl
        case coverAspectRatio, rating, isFavorite, type, filename
        case titleSortKey, sortOrder, tags, categories
    }

    static let seriesShelfPrefix = "series-"

    static func seriesId(from shelfId: String) -> String? {
        guard shelfId.hasPrefix(seriesShelfPrefix) else { return nil }
        return String(shelfId.dropFirst(seriesShelfPrefix.count))
    }
}

struct TagItem: Codable, Hashable {
    let id: Int?
    let name: String
    let color: String?
}

struct CategoryItem: Codable, Hashable {
    let id: Int
    let name: String
    let slug: String?
}

// MARK: - 列表响应

struct ComicListResponse: Codable {
    let comics: [Comic]
    let total: Int
    let page: Int
    let pageSize: Int
    let totalPages: Int

    enum CodingKeys: String, CodingKey {
        case comics = "comics"
        case total, page, pageSize, totalPages
    }
}

// MARK: - 页面列表

struct PageList: Codable {
    let totalPages: Int
    let isNovel: Bool?
    let isPdf: Bool?
    let pages: [PageEntry]?
}

struct PageEntry: Codable {
    let index: Int
    let name: String?
    let title: String?
}

// MARK: - 章节内容

struct ChapterContent: Codable {
    let title: String?
    let content: String?
    let chapterIndex: Int?
    let totalChapters: Int?
    let mimeType: String?
}
