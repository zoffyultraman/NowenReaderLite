import Foundation

// MARK: - 书库模型

struct Library: Codable, Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let name: String
    let type: String           // "comic" | "novel" | "mixed"
    let seriesDepth: Int
    let editionMergeScope: String?
    let enabled: Bool
    let defaultAccess: String  // "public" | "private"
    let comicCount: Int?
    let shelfCount: Int?
    let canManage: Bool

    var logicalCount: Int {
        shelfCount ?? comicCount ?? 0
    }

    var supportsDirectoryCategories: Bool {
        type == "comic" && seriesDepth > 1
    }

    init(
        id: String,
        name: String,
        type: String = "comic",
        seriesDepth: Int = 1,
        editionMergeScope: String? = nil,
        enabled: Bool = true,
        defaultAccess: String = "private",
        comicCount: Int? = nil,
        shelfCount: Int? = nil,
        canManage: Bool = false
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.seriesDepth = Self.normalizedDepth(seriesDepth)
        self.editionMergeScope = editionMergeScope
        self.enabled = enabled
        self.defaultAccess = defaultAccess
        self.comicCount = comicCount
        self.shelfCount = shelfCount
        self.canManage = canManage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? "comic"
        let rawDepth = try container.decodeIfPresent(Int.self, forKey: .seriesDepth) ?? 1
        seriesDepth = Self.normalizedDepth(rawDepth)
        editionMergeScope = try container.decodeIfPresent(String.self, forKey: .editionMergeScope)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        defaultAccess = try container.decodeIfPresent(String.self, forKey: .defaultAccess) ?? "private"
        comicCount = try container.decodeIfPresent(Int.self, forKey: .comicCount)
        shelfCount = try container.decodeIfPresent(Int.self, forKey: .shelfCount)
        canManage = try container.decodeIfPresent(Bool.self, forKey: .canManage) ?? false
    }

    private static func normalizedDepth(_ value: Int) -> Int {
        min(max(value, 1), 8)
    }
}

struct LibraryListResponse: Codable, Sendable {
    let libraries: [Library]
}

// MARK: - 书库物理目录导航模型

/// 目录分类面包屑节点
struct LibraryDirectoryBreadcrumb: Codable, Identifiable, Equatable, Hashable, Sendable {
    let name: String
    let path: String

    var id: String { path }

    init(name: String, path: String) {
        self.name = name
        self.path = path
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
    }
}

/// 书库目录分类节点（由物理目录前缀派生，独立于人工 Category）
struct LibraryDirectoryNode: Codable, Identifiable, Equatable, Hashable, Sendable {
    let name: String
    let path: String
    let depth: Int
    let workCount: Int
    let hasChildren: Bool
    let coverUrl: String

    var id: String { path }

    init(
        name: String,
        path: String,
        depth: Int = 1,
        workCount: Int = 0,
        hasChildren: Bool = false,
        coverUrl: String = ""
    ) {
        self.name = name
        self.path = path
        self.depth = depth
        self.workCount = workCount
        self.hasChildren = hasChildren
        self.coverUrl = coverUrl
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        depth = try container.decodeIfPresent(Int.self, forKey: .depth) ?? 1
        workCount = try container.decodeIfPresent(Int.self, forKey: .workCount) ?? 0
        hasChildren = try container.decodeIfPresent(Bool.self, forKey: .hasChildren) ?? false
        coverUrl = try container.decodeIfPresent(String.self, forKey: .coverUrl) ?? ""
    }
}

/// 书库目录分类查询响应
struct LibraryDirectoryListResponse: Codable, Equatable, Sendable {
    let libraryId: String
    let seriesDepth: Int
    let maxDirectoryDepth: Int
    let parent: String
    let breadcrumbs: [LibraryDirectoryBreadcrumb]
    let directories: [LibraryDirectoryNode]
    let total: Int
    let page: Int
    let pageSize: Int
    let totalPages: Int

    init(
        libraryId: String,
        seriesDepth: Int = 1,
        maxDirectoryDepth: Int? = nil,
        parent: String = "",
        breadcrumbs: [LibraryDirectoryBreadcrumb] = [],
        directories: [LibraryDirectoryNode] = [],
        total: Int = 0,
        page: Int = 1,
        pageSize: Int = 50,
        totalPages: Int = 1
    ) {
        let normalizedDepth = min(max(seriesDepth, 1), 8)
        self.libraryId = libraryId
        self.seriesDepth = normalizedDepth
        self.maxDirectoryDepth = maxDirectoryDepth ?? (normalizedDepth > 1 ? normalizedDepth - 1 : 0)
        self.parent = parent
        self.breadcrumbs = breadcrumbs
        self.directories = directories
        self.total = total
        self.page = max(1, page)
        self.pageSize = max(1, pageSize)
        self.totalPages = max(1, totalPages)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        libraryId = try container.decodeIfPresent(String.self, forKey: .libraryId) ?? ""
        let rawDepth = try container.decodeIfPresent(Int.self, forKey: .seriesDepth) ?? 1
        let normalizedDepth = min(max(rawDepth, 1), 8)
        seriesDepth = normalizedDepth
        maxDirectoryDepth = try container.decodeIfPresent(Int.self, forKey: .maxDirectoryDepth)
            ?? (normalizedDepth > 1 ? normalizedDepth - 1 : 0)
        parent = try container.decodeIfPresent(String.self, forKey: .parent) ?? ""
        breadcrumbs = try container.decodeIfPresent([LibraryDirectoryBreadcrumb].self, forKey: .breadcrumbs) ?? []
        directories = try container.decodeIfPresent([LibraryDirectoryNode].self, forKey: .directories) ?? []
        total = max(0, try container.decodeIfPresent(Int.self, forKey: .total) ?? 0)
        page = max(1, try container.decodeIfPresent(Int.self, forKey: .page) ?? 1)
        pageSize = max(1, try container.decodeIfPresent(Int.self, forKey: .pageSize) ?? 50)
        totalPages = max(1, try container.decodeIfPresent(Int.self, forKey: .totalPages) ?? 1)
    }
}
