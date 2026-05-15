import Foundation
import SwiftData

@Model
final class CachedComic {
    @Attribute(.unique) var id: String
    var title: String
    var author: String?
    var coverUrl: String?
    var pageCount: Int
    var lastReadPage: Int
    var isFavorite: Bool
    var rating: Double?
    var type: String?
    var progress: Int
    var lastReadAt: Date?
    var cachedAt: Date

    init(
        id: String,
        title: String,
        author: String? = nil,
        coverUrl: String? = nil,
        pageCount: Int = 0,
        lastReadPage: Int = 0,
        isFavorite: Bool = false,
        rating: Double? = nil,
        type: String? = nil,
        progress: Int = 0,
        lastReadAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.coverUrl = coverUrl
        self.pageCount = pageCount
        self.lastReadPage = lastReadPage
        self.isFavorite = isFavorite
        self.rating = rating
        self.type = type
        self.progress = progress
        self.lastReadAt = lastReadAt
        self.cachedAt = Date()
    }

    convenience init(from comic: Comic) {
        self.init(
            id: comic.id,
            title: comic.title,
            author: comic.author,
            coverUrl: comic.coverUrl,
            pageCount: comic.pageCount,
            lastReadPage: comic.lastReadPage,
            isFavorite: comic.isFavorite,
            rating: comic.rating,
            type: comic.type,
            progress: comic.progress
        )
    }
}

@Model
final class ServerRecord {
    @Attribute(.unique) var url: String
    var username: String?
    var lastUsed: Date

    init(url: String, username: String? = nil) {
        self.url = url
        self.username = username
        self.lastUsed = Date()
    }
}
