import Foundation

// MARK: - 多格式版本与物理目录位置模型

/// 单个格式版本对应的书库相对目录与（管理员可见的）物理路径
struct ComicFileLocation: Codable, Equatable, Hashable, Sendable {
    let libraryId: String
    let libraryName: String
    let filename: String
    let relativePath: String
    let relativeDir: String
    let baseName: String
    let format: String
    let editionLabel: String?
    let canDownload: Bool
    let canManage: Bool
    let rootPath: String?
    let realDirPath: String?
    let absolutePath: String?
    let existsOnDisk: Bool?

    init(
        libraryId: String = "",
        libraryName: String = "",
        filename: String = "",
        relativePath: String = "",
        relativeDir: String = "",
        baseName: String = "",
        format: String = "",
        editionLabel: String? = nil,
        canDownload: Bool = false,
        canManage: Bool = false,
        rootPath: String? = nil,
        realDirPath: String? = nil,
        absolutePath: String? = nil,
        existsOnDisk: Bool? = nil
    ) {
        self.libraryId = libraryId
        self.libraryName = libraryName
        self.filename = filename
        self.relativePath = relativePath
        self.relativeDir = relativeDir
        self.baseName = baseName
        self.format = format.uppercased()
        self.editionLabel = editionLabel
        self.canDownload = canDownload
        self.canManage = canManage
        self.rootPath = rootPath
        self.realDirPath = realDirPath
        self.absolutePath = absolutePath
        self.existsOnDisk = existsOnDisk
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        libraryId = try container.decodeIfPresent(String.self, forKey: .libraryId) ?? ""
        libraryName = try container.decodeIfPresent(String.self, forKey: .libraryName) ?? ""
        filename = try container.decodeIfPresent(String.self, forKey: .filename) ?? ""
        relativePath = try container.decodeIfPresent(String.self, forKey: .relativePath) ?? ""
        relativeDir = try container.decodeIfPresent(String.self, forKey: .relativeDir) ?? ""
        baseName = try container.decodeIfPresent(String.self, forKey: .baseName) ?? ""
        format = (try container.decodeIfPresent(String.self, forKey: .format) ?? "").uppercased()
        editionLabel = try container.decodeIfPresent(String.self, forKey: .editionLabel)
        canDownload = try container.decodeIfPresent(Bool.self, forKey: .canDownload) ?? false
        canManage = try container.decodeIfPresent(Bool.self, forKey: .canManage) ?? false
        rootPath = try container.decodeIfPresent(String.self, forKey: .rootPath)
        realDirPath = try container.decodeIfPresent(String.self, forKey: .realDirPath)
        absolutePath = try container.decodeIfPresent(String.self, forKey: .absolutePath)
        existsOnDisk = try container.decodeIfPresent(Bool.self, forKey: .existsOnDisk)
    }

    var displayLibraryName: String {
        if !libraryName.isEmpty { return libraryName }
        return libraryId.isEmpty ? "默认书库" : libraryId
    }

    var displayRelativeSummary: String {
        let dir = relativeDir.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !dir.isEmpty || !name.isEmpty {
            let pathPart = dir.isEmpty ? "" : " / \(dir)"
            let basePart = name.isEmpty ? "" : " · \(name)"
            return "\(displayLibraryName)\(pathPart)\(basePart)"
        }
        let rel = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        return rel.isEmpty ? displayLibraryName : "\(displayLibraryName) / \(rel)"
    }

    var isImageFolder: Bool {
        filename.hasSuffix("/") || format.uppercased() == "FOLDER"
    }
}

/// 同一本书下的单个格式/版本条目
struct ComicEditionInfo: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id: String { comicId }
    let comicId: String
    let title: String
    let format: String
    let editionLabel: String?
    let isCurrent: Bool
    let isFormatPrimary: Bool
    let isPreferred: Bool
    let detectionSource: String?
    let fileSize: Int64
    let pageCount: Int
    let lastReadPage: Int
    let lastReadAt: String?
    let readingStatus: String?
    let totalReadTime: Int
    let readerUrl: String?
    let downloadUrl: String?
    let fileLocation: ComicFileLocation?

    init(
        comicId: String,
        title: String = "",
        format: String = "",
        editionLabel: String? = nil,
        isCurrent: Bool = false,
        isFormatPrimary: Bool = false,
        isPreferred: Bool = false,
        detectionSource: String? = nil,
        fileSize: Int64 = 0,
        pageCount: Int = 0,
        lastReadPage: Int = 0,
        lastReadAt: String? = nil,
        readingStatus: String? = nil,
        totalReadTime: Int = 0,
        readerUrl: String? = nil,
        downloadUrl: String? = nil,
        fileLocation: ComicFileLocation? = nil
    ) {
        self.comicId = comicId
        self.title = title
        self.format = format.uppercased()
        self.editionLabel = editionLabel
        self.isCurrent = isCurrent
        self.isFormatPrimary = isFormatPrimary
        self.isPreferred = isPreferred
        self.detectionSource = detectionSource
        self.fileSize = fileSize
        self.pageCount = pageCount
        self.lastReadPage = lastReadPage
        self.lastReadAt = lastReadAt
        self.readingStatus = readingStatus
        self.totalReadTime = totalReadTime
        self.readerUrl = readerUrl
        self.downloadUrl = downloadUrl
        self.fileLocation = fileLocation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        comicId = try container.decodeIfPresent(String.self, forKey: .comicId) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        format = (try container.decodeIfPresent(String.self, forKey: .format) ?? "").uppercased()
        editionLabel = try container.decodeIfPresent(String.self, forKey: .editionLabel)
        isCurrent = try container.decodeIfPresent(Bool.self, forKey: .isCurrent) ?? false
        isFormatPrimary = try container.decodeIfPresent(Bool.self, forKey: .isFormatPrimary) ?? false
        isPreferred = try container.decodeIfPresent(Bool.self, forKey: .isPreferred) ?? false
        detectionSource = try container.decodeIfPresent(String.self, forKey: .detectionSource)
        fileSize = try container.decodeIfPresent(Int64.self, forKey: .fileSize) ?? 0
        pageCount = max(0, try container.decodeIfPresent(Int.self, forKey: .pageCount) ?? 0)
        lastReadPage = max(0, try container.decodeIfPresent(Int.self, forKey: .lastReadPage) ?? 0)
        lastReadAt = try container.decodeIfPresent(String.self, forKey: .lastReadAt)
        readingStatus = try container.decodeIfPresent(String.self, forKey: .readingStatus)
        totalReadTime = max(0, try container.decodeIfPresent(Int.self, forKey: .totalReadTime) ?? 0)
        readerUrl = try container.decodeIfPresent(String.self, forKey: .readerUrl)
        downloadUrl = try container.decodeIfPresent(String.self, forKey: .downloadUrl)
        fileLocation = try container.decodeIfPresent(ComicFileLocation.self, forKey: .fileLocation)
    }

    var isPdf: Bool {
        format.uppercased() == "PDF" || fileLocation?.filename.lowercased().hasSuffix(".pdf") == true
    }

    var isImageFolder: Bool {
        format.uppercased() == "FOLDER" || fileLocation?.isImageFolder == true
    }

    var canDownloadOriginalFile: Bool {
        let hasDownloadURL = !(downloadUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (fileLocation?.canDownload == true || hasDownloadURL) && !isImageFolder
    }

    var displayFormat: String {
        let trimmed = format.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed.uppercased() }
        let extracted = Comic.extractFormat(from: fileLocation?.filename)
        return extracted.isEmpty ? "BOOK" : extracted
    }

    var displayChipLabel: String {
        let label = (editionLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? displayFormat : "\(displayFormat) · \(label)"
    }

    var hasReadingProgress: Bool {
        (lastReadAt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            || lastReadPage > 0
            || readingStatus == "reading"
            || readingStatus == "finished"
    }

    var progress: Int {
        if readingStatus == "finished" { return 100 }
        guard pageCount > 0, hasReadingProgress else { return 0 }
        let current = min(max(lastReadPage + 1, 0), pageCount)
        let percent = Int((Double(current) / Double(pageCount) * 100).rounded())
        return min(100, max(1, percent))
    }
}

// MARK: - 漫画/小说数据模型

struct Comic: Codable, Identifiable, Equatable, Sendable {
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
    let lastReadPositionRatio: Double?
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
    let libraryId: String?
    let canManage: Bool?
    let canDownload: Bool?
    let comicCount: Int?
    let relativePath: String?
    let format: String?
    let editionLabel: String?
    let editionGroupId: String?
    let formats: [String]?
    let editionCount: Int?
    let preferredComicId: String?
    let fileLocation: ComicFileLocation?
    let editions: [ComicEditionInfo]?
    let tags: [TagItem]?
    let categories: [CategoryItem]?

    init(
        id: String,
        title: String,
        author: String? = nil,
        publisher: String? = nil,
        description: String? = nil,
        genre: String? = nil,
        language: String? = nil,
        year: Int? = nil,
        pageCount: Int,
        fileSize: Int64? = nil,
        lastReadPage: Int,
        lastReadPositionRatio: Double? = nil,
        totalReadTime: Int? = nil,
        readingStatus: String? = nil,
        lastReadAt: String? = nil,
        metadataSource: String? = nil,
        coverUrl: String? = nil,
        coverAspectRatio: Double? = nil,
        rating: Double? = nil,
        isFavorite: Bool,
        type: String? = nil,
        filename: String? = nil,
        titleSortKey: String? = nil,
        sortOrder: Int? = nil,
        libraryId: String? = nil,
        canManage: Bool? = nil,
        canDownload: Bool? = nil,
        comicCount: Int? = nil,
        relativePath: String? = nil,
        format: String? = nil,
        editionLabel: String? = nil,
        editionGroupId: String? = nil,
        formats: [String]? = nil,
        editionCount: Int? = nil,
        preferredComicId: String? = nil,
        fileLocation: ComicFileLocation? = nil,
        editions: [ComicEditionInfo]? = nil,
        tags: [TagItem]? = nil,
        categories: [CategoryItem]? = nil
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.publisher = publisher
        self.description = description
        self.genre = genre
        self.language = language
        self.year = year
        self.pageCount = max(0, pageCount)
        self.fileSize = fileSize
        self.lastReadPage = max(0, lastReadPage)
        self.lastReadPositionRatio = lastReadPositionRatio.map { min(max($0, 0.0), 1.0) }
        self.totalReadTime = totalReadTime
        self.readingStatus = readingStatus
        self.lastReadAt = lastReadAt
        self.metadataSource = metadataSource
        self.coverUrl = coverUrl
        self.coverAspectRatio = coverAspectRatio
        self.rating = rating
        self.isFavorite = isFavorite
        self.type = type
        self.filename = filename
        self.titleSortKey = titleSortKey
        self.sortOrder = sortOrder
        self.libraryId = libraryId
        self.canManage = canManage
        self.canDownload = canDownload
        self.comicCount = comicCount
        self.relativePath = relativePath
        self.format = format?.uppercased()
        self.editionLabel = editionLabel
        self.editionGroupId = editionGroupId
        self.formats = formats?.map { $0.uppercased() }.filter { !$0.isEmpty }
        self.editionCount = editionCount
        self.preferredComicId = preferredComicId
        self.fileLocation = fileLocation
        self.editions = editions
        self.tags = tags
        self.categories = categories
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        author = try container.decodeIfPresent(String.self, forKey: .author)
        publisher = try container.decodeIfPresent(String.self, forKey: .publisher)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        genre = try container.decodeIfPresent(String.self, forKey: .genre)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        year = try container.decodeIfPresent(Int.self, forKey: .year)
        pageCount = max(0, try container.decodeIfPresent(Int.self, forKey: .pageCount) ?? 0)
        fileSize = try container.decodeIfPresent(Int64.self, forKey: .fileSize)
        lastReadPage = max(0, try container.decodeIfPresent(Int.self, forKey: .lastReadPage) ?? 0)
        if let ratio = try container.decodeIfPresent(Double.self, forKey: .lastReadPositionRatio) {
            lastReadPositionRatio = min(max(ratio, 0.0), 1.0)
        } else {
            lastReadPositionRatio = nil
        }
        totalReadTime = try container.decodeIfPresent(Int.self, forKey: .totalReadTime)
        readingStatus = try container.decodeIfPresent(String.self, forKey: .readingStatus)
        lastReadAt = try container.decodeIfPresent(String.self, forKey: .lastReadAt)
        metadataSource = try container.decodeIfPresent(String.self, forKey: .metadataSource)
        coverUrl = try container.decodeIfPresent(String.self, forKey: .coverUrl)
        coverAspectRatio = try container.decodeIfPresent(Double.self, forKey: .coverAspectRatio)
        rating = try container.decodeIfPresent(Double.self, forKey: .rating)
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        type = try container.decodeIfPresent(String.self, forKey: .type)
        filename = try container.decodeIfPresent(String.self, forKey: .filename)
        titleSortKey = try container.decodeIfPresent(String.self, forKey: .titleSortKey)
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder)
        libraryId = try container.decodeIfPresent(String.self, forKey: .libraryId)
        canManage = try container.decodeIfPresent(Bool.self, forKey: .canManage)
        canDownload = try container.decodeIfPresent(Bool.self, forKey: .canDownload)
        comicCount = try container.decodeIfPresent(Int.self, forKey: .comicCount)
        relativePath = try container.decodeIfPresent(String.self, forKey: .relativePath)
        format = try container.decodeIfPresent(String.self, forKey: .format)?.uppercased()
        editionLabel = try container.decodeIfPresent(String.self, forKey: .editionLabel)
        editionGroupId = try container.decodeIfPresent(String.self, forKey: .editionGroupId)
        formats = try container.decodeIfPresent([String].self, forKey: .formats)?
            .map { $0.uppercased() }
            .filter { !$0.isEmpty }
        editionCount = try container.decodeIfPresent(Int.self, forKey: .editionCount)
        preferredComicId = try container.decodeIfPresent(String.self, forKey: .preferredComicId)
        fileLocation = try container.decodeIfPresent(ComicFileLocation.self, forKey: .fileLocation)
        editions = try container.decodeIfPresent([ComicEditionInfo].self, forKey: .editions)
        tags = try container.decodeIfPresent([TagItem].self, forKey: .tags)
        categories = try container.decodeIfPresent([CategoryItem].self, forKey: .categories)
    }

    static func extractFormat(from filename: String?) -> String {
        guard let filename else { return "" }
        let cleaned = filename
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "" }
        if cleaned.hasSuffix("/") { return "FOLDER" }
        guard let dotIndex = cleaned.lastIndex(of: ".") else { return "" }
        let nextIndex = cleaned.index(after: dotIndex)
        guard nextIndex < cleaned.endIndex else { return "" }
        return String(cleaned[nextIndex...]).uppercased()
    }

    var formatBadge: String {
        if isSeriesShelfItem { return "" }
        let normalizedFormats = (formats ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty }
        let explicitFormat = (format ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let primary = !explicitFormat.isEmpty
            ? explicitFormat
            : Self.extractFormat(from: filename ?? fileLocation?.filename)

        if normalizedFormats.count > 1 {
            return "\(normalizedFormats[0]) +\(normalizedFormats.count - 1)"
        }
        let resolvedCount = max(editionCount ?? 0, editions?.count ?? 0)
        if resolvedCount > 1 {
            let lead = normalizedFormats.first ?? primary
            return lead.isEmpty ? "\(resolvedCount)版" : "\(lead) · \(resolvedCount)版"
        }
        return normalizedFormats.first ?? primary
    }

    var isSeriesShelfItem: Bool {
        id.hasPrefix(Self.seriesShelfPrefix) && (filename == nil || filename == "__series__.cbz")
    }

    var seriesId: String? { Self.seriesId(from: id) }

    var seriesItemCount: Int {
        if let comicCount, comicCount > 0 { return comicCount }
        return max(pageCount, 0)
    }

    var hasReadingProgress: Bool {
        (lastReadAt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            || lastReadPage > 0
            || readingStatus == "reading"
            || readingStatus == "finished"
    }

    var displayPage: Int {
        let current = max(lastReadPage + 1, 0)
        if pageCount > 0 {
            return min(current, pageCount)
        }
        return current
    }

    var isFinished: Bool {
        if isSeriesShelfItem {
            let total = seriesItemCount
            return readingStatus == "finished" || (total > 0 && lastReadPage >= total)
        }
        return readingStatus == "finished"
            || (hasReadingProgress && pageCount > 0 && lastReadPage >= pageCount - 1)
    }

    var progress: Int {
        if isSeriesShelfItem {
            if isFinished { return 100 }
            let total = seriesItemCount
            guard total > 0, lastReadPage > 0 else { return 0 }
            let percent = Int((Double(lastReadPage) / Double(total) * 100).rounded())
            return min(100, max(0, percent))
        }
        guard pageCount > 0, hasReadingProgress else { return 0 }
        if readingStatus == "finished" { return 100 }
        let percent = Int((Double(displayPage) / Double(pageCount) * 100).rounded())
        return min(100, max(1, percent))
    }

    var seriesProgress: Int { progress }

    var isPdf: Bool {
        format?.uppercased() == "PDF"
            || filename?.lowercased().hasSuffix(".pdf") == true
            || fileLocation?.filename.lowercased().hasSuffix(".pdf") == true
    }

    var isNovel: Bool {
        type?.lowercased() == "novel" && !isPdf
    }

    var isImageFolder: Bool {
        format?.uppercased() == "FOLDER"
            || filename?.hasSuffix("/") == true
            || fileLocation?.isImageFolder == true
    }

    var canDownloadOriginalFile: Bool {
        (canDownload == true || fileLocation?.canDownload == true)
            && !isImageFolder
            && !isSeriesShelfItem
    }

    var resolvedEditions: [ComicEditionInfo] {
        if let editions, !editions.isEmpty {
            return editions
        }
        guard fileLocation != nil || !formatBadge.isEmpty || canDownload == true else {
            return []
        }
        return [
            ComicEditionInfo(
                comicId: id,
                title: title,
                format: format ?? Self.extractFormat(from: filename ?? fileLocation?.filename),
                editionLabel: editionLabel,
                isCurrent: true,
                isPreferred: true,
                fileSize: fileSize ?? 0,
                pageCount: pageCount,
                lastReadPage: lastReadPage,
                lastReadAt: lastReadAt,
                readingStatus: readingStatus,
                totalReadTime: totalReadTime ?? 0,
                downloadUrl: canDownloadOriginalFile ? "/api/comics/\(id)/download" : nil,
                fileLocation: fileLocation
            )
        ]
    }

    var sortTitle: String {
        guard let titleSortKey, !titleSortKey.isEmpty else { return title }
        return titleSortKey
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
        case year, pageCount, fileSize, lastReadPage, lastReadPositionRatio, totalReadTime
        case readingStatus, lastReadAt, metadataSource, coverUrl
        case coverAspectRatio, rating, isFavorite, type, filename
        case titleSortKey, sortOrder
        case libraryId, canManage, canDownload, comicCount, relativePath
        case format, editionLabel, editionGroupId, formats, editionCount
        case preferredComicId, fileLocation, editions
        case tags, categories
    }

    static let seriesShelfPrefix = "series-"

    static func seriesId(from shelfId: String) -> String? {
        guard shelfId.hasPrefix(seriesShelfPrefix) else { return nil }
        return String(shelfId.dropFirst(seriesShelfPrefix.count))
    }
}

struct TagItem: Codable, Hashable, Sendable {
    let id: Int?
    let name: String
    let color: String?
}

struct CategoryItem: Codable, Hashable, Sendable {
    let id: Int
    let name: String
    let slug: String?
}

// MARK: - 列表响应

struct ComicListResponse: Codable, Sendable {
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

struct PageList: Codable, Sendable {
    let comicId: String?
    let title: String?
    let totalPages: Int
    let isNovel: Bool?
    let isPdf: Bool?
    let pages: [PageEntry]?
}

struct PageEntry: Codable, Identifiable, Hashable, Sendable {
    let index: Int
    let name: String?
    let url: String?
    let title: String?
    let level: Int?
    let parentIndex: Int?
    let hasChildren: Bool?

    var id: Int { index }
}

// MARK: - 章节内容

struct ChapterContent: Codable, Sendable {
    let title: String?
    let content: String?
    let chapterIndex: Int?
    let totalChapters: Int?
    let mimeType: String?
}
