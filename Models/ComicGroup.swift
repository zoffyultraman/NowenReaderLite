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
    let contentType: String?
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
    let comicCount: Int?
    let seriesList: [GroupSeriesItem]
    let comics: [GroupComicItem]

    enum CodingKeys: String, CodingKey {
        case id, name, coverUrl, author, description, comicCount, seriesList, comics
    }

    init(
        id: Int,
        name: String,
        coverUrl: String?,
        author: String?,
        description: String?,
        comicCount: Int?,
        seriesList: [GroupSeriesItem] = [],
        comics: [GroupComicItem]
    ) {
        self.id = id
        self.name = name
        self.coverUrl = coverUrl
        self.author = author
        self.description = description
        self.comicCount = comicCount
        self.seriesList = seriesList
        self.comics = comics
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        coverUrl = try container.decodeIfPresent(String.self, forKey: .coverUrl)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        comicCount = try container.decodeIfPresent(Int.self, forKey: .comicCount)
        seriesList = try container.decodeIfPresent([GroupSeriesItem].self, forKey: .seriesList) ?? []
        comics = try container.decodeIfPresent([GroupComicItem].self, forKey: .comics) ?? []
    }

    var sortedComics: [GroupComicItem] {
        comics.sorted {
            if ($0.sortIndex ?? Int.max) != ($1.sortIndex ?? Int.max) {
                return ($0.sortIndex ?? Int.max) < ($1.sortIndex ?? Int.max)
            }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    var sortedSeriesList: [GroupSeriesItem] {
        seriesList.sorted {
            if ($0.sortIndex ?? Int.max) != ($1.sortIndex ?? Int.max) {
                return ($0.sortIndex ?? Int.max) < ($1.sortIndex ?? Int.max)
            }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    var readingUnits: [GroupComicItem] {
        var seen = Set<String>()
        var units: [GroupComicItem] = []
        for series in sortedSeriesList {
            for comic in series.sortedComics where seen.insert(comic.id).inserted {
                units.append(comic)
            }
        }
        for comic in sortedComics where seen.insert(comic.id).inserted {
            units.append(comic)
        }
        return units
    }

    var displayCount: Int {
        comicCount ?? readingUnits.count
    }

    var fallbackCoverComicId: String? {
        sortedSeriesList
            .compactMap { $0.coverComicId?.nilIfEmpty }
            .first ?? readingUnits.first?.id.nilIfEmpty
    }
}

struct GroupSeriesItem: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let rootRelativePath: String?
    let coverComicId: String?
    let coverUrl: String?
    let sortIndex: Int?
    let comics: [GroupComicItem]

    enum CodingKeys: String, CodingKey {
        case id, title, rootRelativePath, coverComicId, coverUrl, sortIndex, comics
    }

    init(
        id: String,
        title: String,
        rootRelativePath: String?,
        coverComicId: String?,
        coverUrl: String?,
        sortIndex: Int?,
        comics: [GroupComicItem] = []
    ) {
        self.id = id
        self.title = title
        self.rootRelativePath = rootRelativePath
        self.coverComicId = coverComicId
        self.coverUrl = coverUrl
        self.sortIndex = sortIndex
        self.comics = comics
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        rootRelativePath = try container.decodeIfPresent(String.self, forKey: .rootRelativePath)
        coverComicId = try container.decodeIfPresent(String.self, forKey: .coverComicId)
        coverUrl = try container.decodeIfPresent(String.self, forKey: .coverUrl)
        sortIndex = try container.decodeIfPresent(Int.self, forKey: .sortIndex)
        comics = try container.decodeIfPresent([GroupComicItem].self, forKey: .comics) ?? []
    }

    var sortedComics: [GroupComicItem] {
        comics.sorted {
            if ($0.sortIndex ?? Int.max) != ($1.sortIndex ?? Int.max) {
                return ($0.sortIndex ?? Int.max) < ($1.sortIndex ?? Int.max)
            }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
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
    let lastReadAt: String?
    let type: String?

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

// MARK: - 合集选择器逻辑作品

struct CatalogItemListResponse: Codable {
    let items: [CatalogItem]
    let page: Int
    let pageSize: Int
    let total: Int
    let totalPages: Int
}

struct CatalogItem: Codable, Identifiable, Hashable {
    let id: String
    let kind: String
    let title: String
    let coverUrl: String?
    let itemCount: Int
    let libraryId: String?

    var isSeries: Bool { kind == "series" }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
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
