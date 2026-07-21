import Foundation

struct ReadingGroupContext {
    let groupId: Int
    let volumeIds: [String]
    let currentIndex: Int

    var nextVolumeId: String? {
        let next = currentIndex + 1
        return next < volumeIds.count ? volumeIds[next] : nil
    }

    var previousVolumeId: String? {
        let prev = currentIndex - 1
        return prev >= 0 ? volumeIds[prev] : nil
    }
}

struct ComicGroup: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let coverUrl: String?
    let author: String?
    let description: String?
    let comicCount: Int?
    let sortOrder: Int?
    let firstComicId: String?
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
        return min(100, Int(Double(lastReadPage + 1) / Double(pageCount) * 100))
    }
}

// MARK: - 目录作品

struct SeriesListResponse: Codable {
    let series: [SeriesSummary]
}

struct SeriesDetailResponse: Codable {
    let series: SeriesSummary
    let sections: [SeriesSection]
    let unsectioned: [SeriesItem]
}

struct SeriesSummary: Codable, Identifiable, Hashable {
    let id: String
    let libraryId: String
    let rootRelativePath: String
    let title: String
    let sortTitle: String?
    let coverComicId: String?
    let coverUrl: String?
    let itemCount: Int
    let sectionCount: Int
    let completedItemCount: Int
    let totalReadTime: Int
    let fileSize: Int64
    let lastReadAt: String?
    let isFavorite: Bool
    let manualLocked: Bool
    let canManage: Bool?
    let createdAt: String
    let updatedAt: String

    var progress: Int {
        guard itemCount > 0 else { return 0 }
        return min(100, Int(Double(completedItemCount) / Double(itemCount) * 100))
    }
}

struct SeriesSection: Codable, Identifiable {
    let id: String
    let title: String
    let relativePath: String
    let kind: String
    let seasonNumber: Int?
    let sortIndex: Int
    let manualLocked: Bool
    let items: [SeriesItem]
}

struct SeriesItem: Codable, Identifiable {
    let comic: Comic
    let sectionId: String?
    let sortIndex: Int
    let displayLabel: String

    var id: String { comic.id }
    var title: String { displayLabel.isEmpty ? comic.title : displayLabel }
}
