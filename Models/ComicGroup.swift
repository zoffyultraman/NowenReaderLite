import Foundation

struct ReadingGroupContext: Sendable {
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

struct ComicGroup: Codable, Identifiable, Hashable, Sendable {
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

struct GroupListResponse: Codable, Sendable {
    let groups: [ComicGroup]
}

struct GroupDetailResponse: Codable, Sendable {
    let id: Int
    let name: String
    let coverUrl: String?
    let author: String?
    let description: String?
    let comicCount: Int?
    let seriesList: [GroupSeriesItem]
    let comics: [GroupComicItem]
    let sortedSeriesList: [GroupSeriesItem]
    let sortedComics: [GroupComicItem]
    let readingUnits: [GroupComicItem]

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
        sortedSeriesList = Self.sortSeries(seriesList)
        sortedComics = Self.sortComics(comics)
        readingUnits = Self.makeReadingUnits(
            seriesList: sortedSeriesList,
            comics: sortedComics
        )
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
        sortedSeriesList = Self.sortSeries(seriesList)
        sortedComics = Self.sortComics(comics)
        readingUnits = Self.makeReadingUnits(
            seriesList: sortedSeriesList,
            comics: sortedComics
        )
    }

    private static func sortComics(_ comics: [GroupComicItem]) -> [GroupComicItem] {
        comics.sorted {
            if ($0.sortIndex ?? Int.max) != ($1.sortIndex ?? Int.max) {
                return ($0.sortIndex ?? Int.max) < ($1.sortIndex ?? Int.max)
            }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private static func sortSeries(_ seriesList: [GroupSeriesItem]) -> [GroupSeriesItem] {
        seriesList.sorted {
            if ($0.sortIndex ?? Int.max) != ($1.sortIndex ?? Int.max) {
                return ($0.sortIndex ?? Int.max) < ($1.sortIndex ?? Int.max)
            }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private static func makeReadingUnits(
        seriesList: [GroupSeriesItem],
        comics: [GroupComicItem]
    ) -> [GroupComicItem] {
        var seen = Set<String>()
        var units: [GroupComicItem] = []
        for series in seriesList {
            for comic in series.sortedComics where seen.insert(comic.id).inserted {
                units.append(comic)
            }
        }
        for comic in comics where seen.insert(comic.id).inserted {
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

struct GroupSeriesItem: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let rootRelativePath: String?
    let coverComicId: String?
    let coverUrl: String?
    let sortIndex: Int?
    let comics: [GroupComicItem]
    let sortedComics: [GroupComicItem]

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
        sortedComics = Self.sortComics(comics)
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
        sortedComics = Self.sortComics(comics)
    }

    private static func sortComics(_ comics: [GroupComicItem]) -> [GroupComicItem] {
        comics.sorted {
            if ($0.sortIndex ?? Int.max) != ($1.sortIndex ?? Int.max) {
                return ($0.sortIndex ?? Int.max) < ($1.sortIndex ?? Int.max)
            }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
}

struct GroupComicItem: Codable, Identifiable, Hashable, Sendable {
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

struct SeriesListResponse: Codable, Sendable {
    let series: [SeriesSummary]
}

struct SeriesDetailResponse: Codable, Sendable {
    let series: SeriesSummary
    let sections: [SeriesSection]
    let unsectioned: [SeriesItem]
}

struct SeriesSummary: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let libraryId: String
    let contentType: String?
    let rootRelativePath: String
    let title: String
    let sortTitle: String?
    let coverComicId: String?
    let coverUrl: String?
    let author: String?
    let description: String?
    let year: Int?
    let publisher: String?
    let language: String?
    let genre: String?
    let status: String?
    let externalRating: Double?
    let externalRatingMax: Double?
    let externalRatingSource: String?
    let tags: [TagItem]?
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

struct CatalogItemListResponse: Codable, Sendable {
    let items: [CatalogItem]
    let page: Int
    let pageSize: Int
    let total: Int
    let totalPages: Int
}

struct CatalogItem: Codable, Identifiable, Hashable, Sendable {
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

struct SeriesSection: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let relativePath: String
    let kind: String
    let seasonNumber: Int?
    let sortIndex: Int
    let manualLocked: Bool
    let items: [SeriesItem]
}

struct SeriesItem: Codable, Identifiable, Sendable {
    let comic: Comic
    let sectionId: String?
    let sortIndex: Int
    let displayLabel: String

    var id: String { comic.id }
    var title: String { displayLabel.isEmpty ? comic.title : displayLabel }
}
