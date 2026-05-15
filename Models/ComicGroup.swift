import Foundation

struct ComicGroup: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let coverUrl: String?
    let author: String?
    let description: String?
    let comicCount: Int?
    let sortOrder: Int?
}

struct GroupListResponse: Codable {
    let groups: [ComicGroup]
}

struct GroupDetailResponse: Codable {
    let id: Int
    let name: String
    let coverUrl: String?
    let author: String?
    let description: String?
    let comics: [GroupComicItem]
}

struct GroupComicItem: Codable, Identifiable, Hashable {
    let id: String
    let filename: String?
    let title: String
    let pageCount: Int
    let fileSize: Int64?
    let lastReadPage: Int
    let totalReadTime: Int?
    let coverUrl: String?
    let sortIndex: Int?
    let readingStatus: String?

    var progress: Int {
        guard pageCount > 0 else { return 0 }
        return min(100, Int(Double(lastReadPage) / Double(pageCount) * 100))
    }
}
