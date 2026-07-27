import Foundation

/// 离线漫画文件管理器
/// 存储结构: Documents/OfflineComics/{comicId}/page_{000}.jpg
/// 职责: 纯文件 I/O，不涉及网络和图片解码
final class OfflineFileManager {
    static let shared = OfflineFileManager()

    private let baseDir: URL
    private let fileManager = FileManager.default
    private let groupsLock = NSLock()
    private let comicFilesLock = NSLock()
    private var acceptedDownloadGenerations: [String: String] = [:]
    private var discardedComicIds = Set<String>()

    private init() {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        baseDir = documents.appendingPathComponent("OfflineComics", isDirectory: true)
        try? fileManager.createDirectory(at: baseDir, withIntermediateDirectories: true)
    }

    private func withComicFilesLock<T>(_ operation: () throws -> T) rethrows -> T {
        comicFilesLock.lock()
        defer { comicFilesLock.unlock() }
        return try operation()
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

    /// 某本漫画是否完整下载（meta.json 存在 + 页面数达到预期）
    func isComicDownloaded(comicId: String, pageCount: Int) -> Bool {
        completedDownloads()[comicId]?.pageCount == pageCount
    }

    /// 已写入本地的页面索引，一次目录枚举即可用于恢复与缺页核算。
    func downloadedPageIndices(comicId: String) -> Set<Int> {
        withComicFilesLock {
            downloadedPageIndicesUnlocked(comicId: comicId)
        }
    }

    private func downloadedPageIndicesUnlocked(comicId: String) -> Set<Int> {
        guard let contents = try? fileManager.contentsOfDirectory(
            atPath: comicDir(for: comicId).path
        ) else {
            return []
        }

        return Set(contents.compactMap { filename in
            guard filename.hasPrefix("page_"), filename.hasSuffix(".jpg") else { return nil }
            let start = filename.index(filename.startIndex, offsetBy: 5)
            let end = filename.index(filename.endIndex, offsetBy: -4)
            return Int(filename[start..<end])
        })
    }

    // MARK: - 读取

    /// 读取某页的原始 Data（供 ImageCache 或直接使用）
    func loadPageData(comicId: String, page: Int) -> Data? {
        let url = pageURL(comicId: comicId, page: page)
        return try? Data(contentsOf: url)
    }

    // MARK: - 写入

    /// 保存某页的原始 JPEG Data
    func savePageData(
        _ data: Data,
        comicId: String,
        page: Int,
        generation: String? = nil
    ) throws {
        try withComicFilesLock {
            try validateWriteUnlocked(comicId: comicId, generation: generation)
            let dir = comicDir(for: comicId)
            if !fileManager.fileExists(atPath: dir.path) {
                try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let url = pageURL(comicId: comicId, page: page)
            try data.write(to: url, options: .atomic)
        }
    }

    /// 为一次新的下载尝试登记代次，迟到的旧回调将被拒绝写入。
    func prepareComicDownload(comicId: String, generation: String) {
        withComicFilesLock {
            acceptedDownloadGenerations[comicId] = generation
            discardedComicIds.remove(comicId)
        }
    }

    private func validateWriteUnlocked(comicId: String, generation: String?) throws {
        guard !discardedComicIds.contains(comicId) else {
            throw OfflineFileError.discardedDownload
        }
        guard let generation else { return }
        if let accepted = acceptedDownloadGenerations[comicId] {
            guard accepted == generation else {
                throw OfflineFileError.staleDownloadGeneration
            }
        } else {
            acceptedDownloadGenerations[comicId] = generation
        }
    }

    // MARK: - 元数据

    /// 保存漫画下载元数据
    func saveMeta(
        _ meta: OfflineComicMeta,
        comicId: String,
        generation: String? = nil
    ) throws {
        try withComicFilesLock {
            try validateWriteUnlocked(comicId: comicId, generation: generation)
            let dir = comicDir(for: comicId)
            if !fileManager.fileExists(atPath: dir.path) {
                try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let data = try JSONEncoder().encode(meta)
            try data.write(to: metaURL(comicId: comicId), options: .atomic)
        }
    }

    /// 读取漫画下载元数据
    func loadMeta(comicId: String) -> OfflineComicMeta? {
        withComicFilesLock {
            loadMetaUnlocked(comicId: comicId)
        }
    }

    private func loadMetaUnlocked(comicId: String) -> OfflineComicMeta? {
        guard let data = try? Data(contentsOf: metaURL(comicId: comicId)) else { return nil }
        return try? JSONDecoder().decode(OfflineComicMeta.self, from: data)
    }

    // MARK: - 删除

    /// 删除某本漫画的全部本地文件
    @discardableResult
    func deleteComic(comicId: String) -> Bool {
        withComicFilesLock {
            discardedComicIds.insert(comicId)
            acceptedDownloadGenerations.removeValue(forKey: comicId)
            let directory = comicDir(for: comicId)
            guard fileManager.fileExists(atPath: directory.path) else {
                return true
            }
            do {
                try fileManager.removeItem(at: directory)
                return true
            } catch {
                AppLogger.error("删除离线文件失败 \(comicId): \(error)")
                return false
            }
        }
    }

    /// 删除所有已下载漫画
    func deleteAll() {
        withComicFilesLock {
            discardedComicIds.formUnion(acceptedDownloadGenerations.keys)
            acceptedDownloadGenerations.removeAll()
            try? fileManager.removeItem(at: baseDir)
            try? fileManager.createDirectory(at: baseDir, withIntermediateDirectories: true)
        }
    }

    // MARK: - 统计

    /// 某本漫画的本地存储大小（字节）
    func comicDiskSize(comicId: String) -> Int64 {
        withComicFilesLock {
            comicDiskSizeUnlocked(comicId: comicId)
        }
    }

    private func comicDiskSizeUnlocked(comicId: String) -> Int64 {
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
        diskUsageSnapshot().totalBytes
    }

    func diskUsageSnapshot() -> OfflineDiskUsageSnapshot {
        withComicFilesLock {
            guard let items = try? fileManager.contentsOfDirectory(
                at: baseDir, includingPropertiesForKeys: [.isDirectoryKey],
                options: .skipsHiddenFiles
            ) else {
                return OfflineDiskUsageSnapshot(totalBytes: 0, bytesByComicId: [:])
            }
            var bytesByComicId: [String: Int64] = [:]
            for item in items {
                var isDir: ObjCBool = false
                guard fileManager.fileExists(
                    atPath: item.path,
                    isDirectory: &isDir
                ), isDir.boolValue else {
                    continue
                }
                bytesByComicId[item.lastPathComponent] = comicDiskSizeUnlocked(
                    comicId: item.lastPathComponent
                )
            }
            return OfflineDiskUsageSnapshot(
                totalBytes: bytesByComicId.values.reduce(0, +),
                bytesByComicId: bytesByComicId
            )
        }
    }

    /// 返回所有带元数据的下载状态，并单独标记页面完整的作品。
    func downloadStateSnapshot() -> OfflineDownloadStateSnapshot {
        withComicFilesLock {
            guard let items = try? fileManager.contentsOfDirectory(
                at: baseDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: .skipsHiddenFiles
            ) else {
                return OfflineDownloadStateSnapshot(
                    metas: [:],
                    pageIndices: [:],
                    completedIds: []
                )
            }

            var metas: [String: OfflineComicMeta] = [:]
            var pageIndices: [String: Set<Int>] = [:]
            var completedIds = Set<String>()
            for item in items {
                let comicId = item.lastPathComponent
                let indices = downloadedPageIndicesUnlocked(comicId: comicId)
                pageIndices[comicId] = indices
                guard let meta = loadMetaUnlocked(comicId: comicId) else { continue }
                metas[comicId] = meta
                if meta.pageCount > 0,
                   (0..<meta.pageCount).allSatisfy(indices.contains) {
                    completedIds.insert(comicId)
                }
            }
            return OfflineDownloadStateSnapshot(
                metas: metas,
                pageIndices: pageIndices,
                completedIds: completedIds
            )
        }
    }

    func completedDownloads() -> [String: OfflineComicMeta] {
        let snapshot = downloadStateSnapshot()
        return snapshot.metas.filter { snapshot.completedIds.contains($0.key) }
    }

    // MARK: - 合集存储

    private var groupsFileURL: URL {
        baseDir.appendingPathComponent("groups.json")
    }

    /// 加载所有已保存的合集
    func loadGroups() -> [OfflineGroupMeta] {
        groupsLock.lock()
        defer { groupsLock.unlock() }
        return loadGroupsUnlocked()
    }

    private func loadGroupsUnlocked() -> [OfflineGroupMeta] {
        guard let data = try? Data(contentsOf: groupsFileURL) else { return [] }
        return (try? JSONDecoder().decode([OfflineGroupMeta].self, from: data)) ?? []
    }

    /// 保存单个合集（合并已有数据，按 id 去重）
    func saveGroup(_ group: OfflineGroupMeta) {
        groupsLock.lock()
        defer { groupsLock.unlock() }
        var groups = loadGroupsUnlocked()
        if let index = groups.firstIndex(where: { $0.id == group.id }) {
            groups[index] = group
        } else {
            groups.append(group)
        }
        saveGroupsUnlocked(groups)
    }

    /// 批量保存合集
    func saveGroups(_ groups: [OfflineGroupMeta]) {
        groupsLock.lock()
        defer { groupsLock.unlock() }
        saveGroupsUnlocked(groups)
    }

    private func saveGroupsUnlocked(_ groups: [OfflineGroupMeta]) {
        guard let data = try? JSONEncoder().encode(groups) else { return }
        try? data.write(to: groupsFileURL, options: .atomic)
    }

    /// 删除单个合集记录
    func deleteGroup(groupId: Int) {
        groupsLock.lock()
        defer { groupsLock.unlock() }
        var groups = loadGroupsUnlocked()
        groups.removeAll { $0.id == groupId }
        saveGroupsUnlocked(groups)
    }

    /// 查找单个合集
    func loadGroupDetail(groupId: Int) -> OfflineGroupMeta? {
        loadGroups().first { $0.id == groupId }
    }
}

extension OfflineFileManager: @unchecked Sendable {}

enum OfflineFileError: Error {
    case discardedDownload
    case staleDownloadGeneration
}

struct OfflineDiskUsageSnapshot: Sendable {
    let totalBytes: Int64
    let bytesByComicId: [String: Int64]
}

struct OfflineDownloadStateSnapshot: Sendable {
    let metas: [String: OfflineComicMeta]
    let pageIndices: [String: Set<Int>]
    let completedIds: Set<String>

    func hasAllRequiredPages(comicId: String, pageCount: Int) -> Bool {
        guard pageCount > 0, let indices = pageIndices[comicId] else {
            return false
        }
        return (0..<pageCount).allSatisfy(indices.contains)
    }

    func completedPageCount(comicId: String, pageCount: Int) -> Int {
        guard pageCount > 0, let indices = pageIndices[comicId] else {
            return 0
        }
        return indices.lazy.filter { (0..<pageCount).contains($0) }.count
    }
}

// MARK: - 下载元数据

struct OfflineComicMeta: Codable, Sendable {
    let comicId: String
    let title: String
    let pageCount: Int
    let downloadedAt: Date
    let fileSize: Int64?       // 漫画原始 fileSize
    let isNovel: Bool?

    init(
        comicId: String,
        title: String,
        pageCount: Int,
        downloadedAt: Date,
        fileSize: Int64?,
        isNovel: Bool? = nil
    ) {
        self.comicId = comicId
        self.title = title
        self.pageCount = pageCount
        self.downloadedAt = downloadedAt
        self.fileSize = fileSize
        self.isNovel = isNovel
    }
}

// MARK: - 合集离线元数据

struct OfflineGroupMeta: Codable, Identifiable, Sendable {
    let id: Int
    let name: String
    let coverUrl: String?
    let author: String?
    let description: String?
    let comicCount: Int?
    let sortOrder: Int?
    var comicIds: [String]     // 合集内的漫画 ID 列表
}
