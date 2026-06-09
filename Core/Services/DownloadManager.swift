import Foundation
import SwiftUI
import SwiftData
import Combine

/// 漫画下载任务管理器
/// 可插拔设计：独立于 APIClient，仅通过 URL + Cookie 认证下载
@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    /// 当前所有下载任务（key = comicId）
    @Published private(set) var tasks: [String: DownloadTask] = [:]
    /// 当前正在下载的任务数（用于 Tab 徽标）
    @Published private(set) var activeDownloadCount: Int = 0
    /// 全局下载进度（所有活跃任务的加权平均）
    @Published private(set) var globalProgress: Double = 0
    /// 下载状态变更版本号（每次任务状态/进度变化时递增，驱动 SwiftUI 刷新）
    @Published private(set) var downloadVersion: Int = 0

    /// 最大并发下载数
    private let maxConcurrent = 3
    /// 单页下载超时
    private let pageTimeout: TimeInterval = 30
    /// 每批并发下载页数
    private let batchSize = 5

    private let fileManager = OfflineFileManager.shared
    private var downloadQueue: [String] = []   // 等待中的 comicId
    private var taskCancellables: [String: AnyCancellable] = [:]
    private var activeCount: Int { tasks.values.filter { $0.state == .downloading }.count }

    // MARK: - 存储上限

    /// 存储上限（字节），0 = 无限制
    var storageLimitBytes: Int64 {
        let mb = UserDefaults.standard.integer(forKey: "offlineStorageLimitMB")
        return mb > 0 ? Int64(mb) * 1024 * 1024 : 0
    }

    /// 当前已用离线存储（字节）
    var usedStorageBytes: Int64 {
        fileManager.totalDiskSize
    }

    /// 是否还有剩余空间可下载
    var hasStorageSpace: Bool {
        let limit = storageLimitBytes
        guard limit > 0 else { return true }
        return usedStorageBytes < limit
    }

    /// 估算某本漫画下载后是否会超限（按每页 ~300KB 估算）
    func wouldExceedLimit(pageCount: Int) -> Bool {
        let limit = storageLimitBytes
        guard limit > 0 else { return false }
        let estimated = Int64(pageCount) * 300 * 1024
        return usedStorageBytes + estimated > limit
    }

    private init() {}

    /// 刷新全局下载统计（在任务状态变更时调用）
    private func refreshStats() {
        let active = tasks.values.filter { $0.state == .downloading || $0.state == .waiting }
        activeDownloadCount = active.count
        if active.isEmpty {
            globalProgress = 0
        } else {
            let totalPages = active.reduce(0) { $0 + $1.totalPages }
            let completedPages = active.reduce(0) { $0 + $1.completedPages }
            globalProgress = totalPages > 0 ? Double(completedPages) / Double(totalPages) : 0
        }
        downloadVersion += 1
    }

    /// 监听任务属性变化，转发给自身 objectWillChange（驱动 SwiftUI 刷新）
    private func observeTask(_ task: DownloadTask) {
        taskCancellables[task.comicId] = task.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }

    // MARK: - Public API

    /// 开始下载一本漫画
    @discardableResult
    func download(comicId: String, title: String, pageCount: Int, fileSize: Int64?) -> Bool {
        // 已完成或正在下载，跳过
        if let task = tasks[comicId], (task.state == .downloading || task.state == .completed) { return false }
        if fileManager.isComicDownloaded(comicId: comicId, pageCount: pageCount) {
            // 文件已存在但没有 task，同步状态
            let task = DownloadTask(
                comicId: comicId, title: title,
                totalPages: pageCount, completedPages: pageCount,
                state: .completed
            )
            tasks[comicId] = task
            observeTask(task)
            return false
        }

        // 存储上限检查
        if wouldExceedLimit(pageCount: pageCount) {
            AppLogger.error("存储空间不足，跳过下载: \(title)")
            return false
        }

        let task = DownloadTask(
            comicId: comicId, title: title,
            totalPages: pageCount, completedPages: 0,
            state: .waiting
        )
        tasks[comicId] = task
        observeTask(task)
        downloadQueue.append(comicId)
        refreshStats()
        processQueue()
        // 异步保存合集信息（不阻塞下载）
        Task { await saveGroupInfoIfNeeded(comicId: comicId) }
        return true
    }

    /// 检查漫画是否属于某个合集，如果是则保存合集信息到本地
    private func saveGroupInfoIfNeeded(comicId: String) async {
        // 已有本地合集数据中包含此漫画，跳过网络请求
        let localGroups = OfflineFileManager.shared.loadGroups()
        if localGroups.contains(where: { $0.comicIds.contains(comicId) }) { return }
        // 从服务器查询合集归属
        guard let map = try? await APIClient.shared.fetchComicGroupMapFull(),
              let groupIds = map[comicId], !groupIds.isEmpty else { return }
        for groupId in groupIds {
            guard let detail = try? await APIClient.shared.fetchGroupDetail(id: groupId) else { continue }
            let meta = OfflineGroupMeta(
                id: detail.id, name: detail.name, coverUrl: detail.coverUrl,
                author: detail.author, description: detail.description,
                comicCount: detail.comics.count, sortOrder: nil,
                comicIds: detail.comics.map { $0.id }
            )
            OfflineFileManager.shared.saveGroup(meta)
        }
    }

    /// 批量下载合集中的所有卷
    /// - Parameters:
    ///   - comics: 合集中的漫画列表
    ///   - groupDetail: 合集详情（用于保存合集离线信息）
    /// - Returns: (成功入队数, 跳过数)
    func downloadAll(comics: [GroupComicItem], groupDetail: GroupDetailResponse? = nil) -> (queued: Int, skipped: Int) {
        // 保存合集离线信息
        if let group = groupDetail {
            let meta = OfflineGroupMeta(
                id: group.id,
                name: group.name,
                coverUrl: group.coverUrl,
                author: group.author,
                description: group.description,
                comicCount: group.comics.count,
                sortOrder: nil,
                comicIds: group.comics.map { $0.id }
            )
            OfflineFileManager.shared.saveGroup(meta)
        }
        var queued = 0
        var skipped = 0
        for comic in comics {
            let success = download(
                comicId: comic.id,
                title: comic.title,
                pageCount: comic.pageCount,
                fileSize: comic.fileSize
            )
            if success { queued += 1 } else { skipped += 1 }
        }
        return (queued, skipped)
    }

    /// 暂停下载
    func pause(comicId: String) {
        guard let task = tasks[comicId], task.state == .downloading else { return }
        task.state = .paused
        task.downloadTask?.cancel()
        task.downloadTask = nil
        downloadQueue.removeAll { $0 == comicId }
        refreshStats()
    }

    /// 恢复下载
    func resume(comicId: String) {
        guard let task = tasks[comicId], task.state == .paused else { return }
        task.state = .waiting
        downloadQueue.append(comicId)
        refreshStats()
        processQueue()
    }

    /// 取消下载（删除已下载的文件）
    func cancel(comicId: String) {
        tasks[comicId]?.downloadTask?.cancel()
        tasks.removeValue(forKey: comicId)
        downloadQueue.removeAll { $0 == comicId }
        fileManager.deleteComic(comicId: comicId)
        syncDeleteFromStore(comicId: comicId)
        refreshStats()
    }

    /// 获取某本漫画的下载任务
    func task(for comicId: String) -> DownloadTask? {
        tasks[comicId]
    }

    /// 某本漫画是否已下载完成
    func isDownloaded(comicId: String) -> Bool {
        if let task = tasks[comicId], task.state == .completed { return true }
        // 没有 task 时，用缓存的 downloadedComicIds 快速判断（避免重复磁盘扫描）
        guard fileManager.downloadedComicIds.contains(comicId) else { return false }
        // 确认有页面文件存在
        let contents = try? FileManager.default.contentsOfDirectory(
            atPath: fileManager.comicDir(for: comicId).path
        )
        return contents?.contains(where: { $0.hasPrefix("page_") }) == true
    }

    /// 删除已下载漫画
    func deleteDownload(comicId: String) {
        tasks.removeValue(forKey: comicId)
        taskCancellables.removeValue(forKey: comicId)
        fileManager.deleteComic(comicId: comicId)
        syncDeleteFromStore(comicId: comicId)
        refreshStats()
    }

    /// 从 SwiftData 恢复任务状态（App 启动时调用）
    func restoreFromStore(context: ModelContext) {
        // 1. 一次性获取磁盘上已下载漫画 ID 集合（带缓存，避免重复扫描）
        let downloadedIds = Set(fileManager.downloadedComicIds)

        // 2. 从 SwiftData 恢复
        let descriptor = FetchDescriptor<DownloadedComicRecord>(
            predicate: #Predicate { $0.state == "completed" }
        )
        let records = context.fetchOrLog(descriptor, label: "恢复下载记录")
        for record in records {
            if downloadedIds.contains(record.comicId) {
                // meta.json 存在，直接恢复任务
                if tasks[record.comicId] == nil {
                    let task = DownloadTask(
                        comicId: record.comicId,
                        title: record.title,
                        totalPages: record.pageCount,
                        completedPages: record.pageCount,
                        state: .completed
                    )
                    tasks[record.comicId] = task
                    observeTask(task)
                }
            } else {
                // meta.json 丢失，检查是否有页面文件可恢复
                let dir = fileManager.comicDir(for: record.comicId)
                let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
                let hasPages = contents?.contains(where: { $0.hasPrefix("page_") }) == true
                if hasPages {
                    let meta = OfflineComicMeta(
                        comicId: record.comicId,
                        title: record.title,
                        pageCount: record.pageCount,
                        downloadedAt: Date(),
                        fileSize: nil
                    )
                    try? fileManager.saveMeta(meta, comicId: record.comicId)
                    if tasks[record.comicId] == nil {
                        let task = DownloadTask(
                            comicId: record.comicId,
                            title: record.title,
                            totalPages: record.pageCount,
                            completedPages: record.pageCount,
                            state: .completed
                        )
                        tasks[record.comicId] = task
                        observeTask(task)
                    }
                } else {
                    context.delete(record)
                }
            }
        }
        context.saveOrLog()

        // 3. 兜底：磁盘上有但 SwiftData 中无记录的漫画
        for comicId in downloadedIds {
            guard tasks[comicId] == nil else { continue }
            if let meta = fileManager.loadMeta(comicId: comicId) {
                let task = DownloadTask(
                    comicId: comicId,
                    title: meta.title,
                    totalPages: meta.pageCount,
                    completedPages: meta.pageCount,
                    state: .completed
                )
                tasks[comicId] = task
                observeTask(task)
                syncToStore(task: task)
            }
        }

        refreshStats()
    }

    // MARK: - Queue Processing

    private func processQueue() {
        while activeCount < maxConcurrent, !downloadQueue.isEmpty {
            let comicId = downloadQueue.removeFirst()
            guard let task = tasks[comicId], task.state == .waiting else { continue }
            startDownload(task: task)
        }
    }

    private func startDownload(task: DownloadTask) {
        task.state = .downloading
        refreshStats()
        task.downloadTask = Task { [weak self] in
            guard let self else { return }
            await self.downloadPages(for: task)
        }
    }

    private func downloadPages(for task: DownloadTask) async {
        let comicId = task.comicId
        let totalPages = task.totalPages

        // 立即保存元数据（确保断网时能读取页数）
        let meta = OfflineComicMeta(
            comicId: comicId,
            title: task.title,
            pageCount: totalPages,
            downloadedAt: Date(),
            fileSize: nil
        )
        try? fileManager.saveMeta(meta, comicId: comicId)

        // 同步写入 SwiftData 缓存（确保离线模式能显示漫画名称）
        syncComicToCache(comicId: comicId, title: task.title, pageCount: totalPages)

        // 从断点续传：找到第一个未下载的页
        var startPage = 0
        for page in 0..<totalPages {
            if !fileManager.isPageDownloaded(comicId: comicId, page: page) {
                startPage = page
                break
            }
        }
        task.completedPages = startPage

        var page = startPage
        while page < totalPages {
            // 检查暂停/取消
            guard task.state == .downloading else { return }
            if Task.isCancelled { return }

            // 存储上限实时检查
            if !hasStorageSpace {
                AppLogger.error("存储空间已满，暂停下载: \(task.title)")
                task.state = .paused
                refreshStats()
                return
            }

            // 跳过已下载的页（断点续传）
            if fileManager.isPageDownloaded(comicId: comicId, page: page) {
                page += 1
                continue
            }

            // 分批并发下载
            let batchEnd = min(page + batchSize, totalPages)
            let batchPages = Array(page..<batchEnd)

            await withTaskGroup(of: (Int, Data?).self) { group in
                for p in batchPages {
                    if fileManager.isPageDownloaded(comicId: comicId, page: p) {
                        continue
                    }
                    group.addTask { [weak self] in
                        guard let self else { return (p, nil) }
                        let data = await self.downloadPage(comicId: comicId, page: p)
                        return (p, data)
                    }
                }

                for await (pageIndex, data) in group {
                    guard task.state == .downloading else { return }
                    if let data {
                        do {
                            try fileManager.savePageData(data, comicId: comicId, page: pageIndex)
                            task.completedPages += 1
                        } catch {
                            AppLogger.error("保存页面失败 \(comicId)/\(pageIndex): \(error)")
                        }
                    }
                }
            }

            refreshStats()
            page = batchEnd
        }

        // 全部完成
        guard task.state == .downloading else { return }
        task.state = .completed
        refreshStats()

        // 同步到 SwiftData
        syncToStore(task: task)

        AppLogger.log("漫画下载完成: \(task.title) (\(totalPages)页)")
    }

    private func downloadPage(comicId: String, page: Int) async -> Data? {
        guard let url = APIClient.shared.pageImageURL(comicId: comicId, page: page) else { return nil }
        let request = APIClient.shared.authenticatedRequest(url: url, timeout: pageTimeout)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return data
        } catch {
            return nil
        }
    }

    // MARK: - SwiftData 同步

    private var modelContext: ModelContext?

    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }

    /// 将漫画基本信息写入 SwiftData 缓存（确保离线模式能显示名称和封面）
    private func syncComicToCache(comicId: String, title: String, pageCount: Int) {
        guard let context = modelContext else { return }
        let id = comicId
        let existing = context.fetchOrLog(
            FetchDescriptor<CachedComic>(predicate: #Predicate { $0.id == id }),
            label: "查询缓存漫画"
        )
        if let cached = existing.first {
            cached.title = title
            cached.pageCount = pageCount
            cached.cachedAt = Date()
        } else {
            let cached = CachedComic()
            cached.id = comicId
            cached.title = title
            cached.pageCount = pageCount
            cached.cachedAt = Date()
            context.insert(cached)
        }
        context.saveOrLog()
    }

    private func syncToStore(task: DownloadTask) {
        guard let context = modelContext else { return }
        let id = task.comicId
        let existing = context.fetchOrLog(
            FetchDescriptor<DownloadedComicRecord>(predicate: #Predicate { $0.comicId == id }),
            label: "查询下载记录"
        )
        if let record = existing.first {
            record.state = task.state.rawValue
            record.downloadedAt = Date()
        } else {
            let record = DownloadedComicRecord(
                comicId: task.comicId,
                title: task.title,
                pageCount: task.totalPages,
                state: task.state.rawValue
            )
            context.insert(record)
        }
        context.saveOrLog()
    }

    private func syncDeleteFromStore(comicId: String) {
        guard let context = modelContext else { return }
        let id = comicId
        let records = context.fetchOrLog(
            FetchDescriptor<DownloadedComicRecord>(predicate: #Predicate { $0.comicId == id }),
            label: "删除下载记录"
        )
        for record in records { context.delete(record) }
        context.saveOrLog()
    }
}

// MARK: - DownloadTask

@MainActor
final class DownloadTask: ObservableObject, Identifiable {
    let id: String  // comicId
    let comicId: String
    let title: String
    let totalPages: Int
    @Published var completedPages: Int
    @Published var state: DownloadState

    var downloadTask: Task<Void, Never>?

    var progress: Double {
        guard totalPages > 0 else { return 0 }
        return Double(completedPages) / Double(totalPages)
    }

    init(comicId: String, title: String, totalPages: Int, completedPages: Int, state: DownloadState) {
        self.id = comicId
        self.comicId = comicId
        self.title = title
        self.totalPages = totalPages
        self.completedPages = completedPages
        self.state = state
    }
}

enum DownloadState: String, Codable {
    case waiting
    case downloading
    case paused
    case completed
    case failed
}
