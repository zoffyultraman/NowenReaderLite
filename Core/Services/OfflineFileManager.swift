import Foundation

/// 离线漫画文件管理器
/// 存储结构: Documents/OfflineComics/{comicId}/page_{000}.jpg
/// 职责: 纯文件 I/O，不涉及网络和图片解码
final class OfflineFileManager {
    static let shared = OfflineFileManager()

    private let baseDir: URL
    private let fileManager = FileManager.default
    /// 缓存的已下载漫画 ID 列表，避免重复扫描磁盘
    private var cachedDownloadedComicIds: [String]?

    private init() {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        baseDir = documents.appendingPathComponent("OfflineComics", isDirectory: true)
        try? fileManager.createDirectory(at: baseDir, withIntermediateDirectories: true)
    }

    /// 清除 downloadedComicIds 缓存（文件变更时调用）
    private func invalidateDownloadedIdsCache() {
        cachedDownloadedComicIds = nil
    }

    // MARK: - 漫画目录

    /// 某本漫画的本地存储目录
    func comicDir(for comicId: String) -> URL {
        baseDir.appendingPathComponent(comicId, isDirectory: true)
    }

    /// 某页的本地文件路径
    func pageURL(comicId: String, page: Int) -> URL {
        comicDir(for: comicId).appendingPathComponent("page_\(String(format: "%05d", page)).jpg")
    }

    /// 某本漫画的元数据文件
    func metaURL(comicId: String) -> URL {
        comicDir(for: comicId).appendingPathComponent("meta.json")
    }

    // MARK: - 判断

    /// 某页是否已下载到本地
    func isPageDownloaded(comicId: String, page: Int) -> Bool {
        fileManager.fileExists(atPath: pageURL(comicId: comicId, page: page).path)
    }

    /// 某本漫画是否已下载（meta.json 存在 + 至少有 1 个页面文件）
    func isComicDownloaded(comicId: String, pageCount: Int) -> Bool {
        // 先用缓存的 downloadedComicIds 快速判断 meta.json 是否存在
        guard downloadedComicIds.contains(comicId) else { return false }
        // 再检查是否有页面文件
        let contents = try? fileManager.contentsOfDirectory(atPath: comicDir(for: comicId).path)
        return contents?.contains(where: { $0.hasPrefix("page_") }) == true
    }

    // MARK: - 读取

    /// 读取某页的原始 Data（供 ImageCache 或直接使用）
    func loadPageData(comicId: String, page: Int) -> Data? {
        let url = pageURL(comicId: comicId, page: page)
        return try? Data(contentsOf: url)
    }

    // MARK: - 写入

    /// 保存某页的原始 JPEG Data
    func savePageData(_ data: Data, comicId: String, page: Int) throws {
        let dir = comicDir(for: comicId)
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let url = pageURL(comicId: comicId, page: page)
        try data.write(to: url)
    }

    // MARK: - 元数据

    /// 保存漫画下载元数据
    func saveMeta(_ meta: OfflineComicMeta, comicId: String) throws {
        let dir = comicDir(for: comicId)
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let data = try JSONEncoder().encode(meta)
        try data.write(to: metaURL(comicId: comicId))
        invalidateDownloadedIdsCache()
    }

    /// 读取漫画下载元数据
    func loadMeta(comicId: String) -> OfflineComicMeta? {
        guard let data = try? Data(contentsOf: metaURL(comicId: comicId)) else { return nil }
        return try? JSONDecoder().decode(OfflineComicMeta.self, from: data)
    }

    // MARK: - 删除

    /// 删除某本漫画的全部本地文件
    func deleteComic(comicId: String) {
        let dir = comicDir(for: comicId)
        try? fileManager.removeItem(at: dir)
        invalidateDownloadedIdsCache()
    }

    /// 删除所有已下载漫画
    func deleteAll() {
        try? fileManager.removeItem(at: baseDir)
        try? fileManager.createDirectory(at: baseDir, withIntermediateDirectories: true)
        invalidateDownloadedIdsCache()
    }

    // MARK: - 统计

    /// 某本漫画的本地存储大小（字节）
    func comicDiskSize(comicId: String) -> Int64 {
        let dir = comicDir(for: comicId)
        guard let items = try? fileManager.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return items.reduce(0) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return total + Int64(size)
        }
    }

    /// 所有已下载漫画的总存储大小（字节）
    var totalDiskSize: Int64 {
        guard let items = try? fileManager.contentsOfDirectory(
            at: baseDir, includingPropertiesForKeys: [.fileSizeKey],
            options: .skipsSubdirectoryDescendants
        ) else { return 0 }
        var total: Int64 = 0
        for item in items {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue else { continue }
            total += comicDiskSize(comicId: item.lastPathComponent)
        }
        return total
    }

    /// 已下载漫画 ID 列表（必须有 meta.json 文件），带缓存避免重复扫描磁盘
    var downloadedComicIds: [String] {
        if let cached = cachedDownloadedComicIds { return cached }
        guard let items = try? fileManager.contentsOfDirectory(
            at: baseDir, includingPropertiesForKeys: nil,
            options: .skipsSubdirectoryDescendants
        ) else { return [] }
        let ids = items.filter { url in
            fileManager.fileExists(atPath: metaURL(comicId: url.lastPathComponent).path)
        }.map { $0.lastPathComponent }
        cachedDownloadedComicIds = ids
        return ids
    }

    // MARK: - 合集存储

    private var groupsFileURL: URL {
        baseDir.appendingPathComponent("groups.json")
    }

    /// 加载所有已保存的合集
    func loadGroups() -> [OfflineGroupMeta] {
        guard let data = try? Data(contentsOf: groupsFileURL) else { return [] }
        return (try? JSONDecoder().decode([OfflineGroupMeta].self, from: data)) ?? []
    }

    /// 保存单个合集（合并已有数据，按 id 去重）
    func saveGroup(_ group: OfflineGroupMeta) {
        var groups = loadGroups()
        if let index = groups.firstIndex(where: { $0.id == group.id }) {
            groups[index] = group
        } else {
            groups.append(group)
        }
        saveGroups(groups)
    }

    /// 批量保存合集
    func saveGroups(_ groups: [OfflineGroupMeta]) {
        guard let data = try? JSONEncoder().encode(groups) else { return }
        try? data.write(to: groupsFileURL)
    }

    /// 删除单个合集记录
    func deleteGroup(groupId: Int) {
        var groups = loadGroups()
        groups.removeAll { $0.id == groupId }
        saveGroups(groups)
    }

    /// 查找单个合集
    func loadGroupDetail(groupId: Int) -> OfflineGroupMeta? {
        loadGroups().first { $0.id == groupId }
    }
}

// MARK: - 下载元数据

struct OfflineComicMeta: Codable {
    let comicId: String
    let title: String
    let pageCount: Int
    let downloadedAt: Date
    let fileSize: Int64?       // 漫画原始 fileSize
}

// MARK: - 合集离线元数据

struct OfflineGroupMeta: Codable, Identifiable {
    let id: Int
    let name: String
    let coverUrl: String?
    let author: String?
    let description: String?
    let comicCount: Int?
    let sortOrder: Int?
    var comicIds: [String]     // 合集内的漫画 ID 列表
}
