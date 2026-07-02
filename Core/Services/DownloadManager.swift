import Foundation
import SwiftUI
import SwiftData

/// 漫画下载任务管理器
/// 可插拔设计：独立于 APIClient，仅通过 URL + Cookie 认证下载
@MainActor
@Observable
final class DownloadManager {
    static let shared = DownloadManager()

    /// 当前所有下载任务（key = comicId）
    private(set) var tasks: [String: DownloadTask] = [:]
    /// 当前正在下载的任务数（用于 Tab 徽标）
    private(set) var activeDownloadCount: Int = 0
    /// 全局下载进度（所有活跃任务的加权平均）
    private(set) var globalProgress: Double = 0

    private let fileManager = OfflineFileManager.shared
    private var downloadQueue: [String] = []   // 等待中的 comicId
    private var activeCount: Int { tasks.values.filter { $0.state == .downloading }.count }

    /// 最大并发下载任务数（对于 background session，OS 会自行调度，但这控制着“同时处在 downloading 状态的整书任务数”）
    private let maxConcurrent = 3
    private let pageTimeout: TimeInterval = 30

    // MARK: - 存储上限

    var storageLimitBytes: Int64 {
        let mb = UserDefaults.standard.integer(forKey: "offlineStorageLimitMB")
        return mb > 0 ? Int64(mb) * 1024 * 1024 : 0
    }

    var usedStorageBytes: Int64 {
        fileManager.totalDiskSize
    }

    var hasStorageSpace: Bool {
        let limit = storageLimitBytes
        guard limit > 0 else { return true }
        return usedStorageBytes < limit
    }

    func wouldExceedLimit(pageCount: Int) -> Bool {
        let limit = storageLimitBytes
        guard limit > 0 else { return false }
        let estimated = Int64(pageCount) * 300 * 1024
        return usedStorageBytes + estimated > limit
    }

    // MARK: - 后台会话

    @ObservationIgnored var backgroundCompletionHandler: (() -> Void)?

    @ObservationIgnored private lazy var sessionDelegate = SessionDelegate(manager: self)

    @ObservationIgnored private lazy var backgroundSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.nowen.readerlite.background")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: sessionDelegate, delegateQueue: .main)
    }()

    private init() {
        // 提前访问一下，确保配置在 App 启动时绑定 delegate
        _ = backgroundSession
    }

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
    }

    // MARK: - Public API

    @discardableResult
    func download(comicId: String, title: String, pageCount: Int, fileSize: Int64?, isNovel: Bool = false) -> Bool {
        if let task = tasks[comicId], (task.state == .downloading || task.state == .completed) { return false }
        if fileManager.isComicDownloaded(comicId: comicId, pageCount: pageCount) {
            let task = DownloadTask(
                comicId: comicId, title: title,
                totalPages: pageCount, completedPages: pageCount,
                state: .completed, isNovel: isNovel
            )
            tasks[comicId] = task
            return false
        }

        if wouldExceedLimit(pageCount: pageCount) {
            AppLogger.error("存储空间不足，跳过下载: \\(title)")
            return false
        }

        let task = DownloadTask(
            comicId: comicId, title: title,
            totalPages: pageCount, completedPages: 0,
            state: .waiting, isNovel: isNovel
        )
        tasks[comicId] = task
        downloadQueue.append(comicId)
        refreshStats()
        processQueue()
        Task { await saveGroupInfoIfNeeded(comicId: comicId) }
        return true
    }

    private func saveGroupInfoIfNeeded(comicId: String) async {
        let localGroups = OfflineFileManager.shared.loadGroups()
        if localGroups.contains(where: { $0.comicIds.contains(comicId) }) { return }
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

    func downloadAll(comics: [GroupComicItem], groupDetail: GroupDetailResponse? = nil) -> (queued: Int, skipped: Int) {
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
            let success = download(comicId: comic.id, title: comic.title, pageCount: comic.pageCount, fileSize: comic.fileSize)
            if success { queued += 1 } else { skipped += 1 }
        }
        return (queued, skipped)
    }

    func pause(comicId: String) {
        guard let task = tasks[comicId], task.state == .downloading else { return }
        task.state = .paused
        backgroundSession.getAllTasks { sessionTasks in
            for t in sessionTasks {
                guard let desc = t.taskDescription, desc.hasPrefix("\(comicId)|") else { continue }
                t.cancel()
            }
        }
        downloadQueue.removeAll { $0 == comicId }
        refreshStats()
    }

    func resume(comicId: String) {
        guard let task = tasks[comicId], task.state == .paused else { return }
        task.state = .waiting
        downloadQueue.append(comicId)
        refreshStats()
        processQueue()
    }

    func cancel(comicId: String) {
        pause(comicId: comicId)
        tasks.removeValue(forKey: comicId)
        downloadQueue.removeAll { $0 == comicId }
        fileManager.deleteComic(comicId: comicId)
        syncDeleteFromStore(comicId: comicId)
        refreshStats()
    }

    func task(for comicId: String) -> DownloadTask? {
        tasks[comicId]
    }

    func isDownloaded(comicId: String) -> Bool {
        if let task = tasks[comicId], task.state == .completed { return true }
        guard fileManager.downloadedComicIds.contains(comicId) else { return false }
        let contents = try? FileManager.default.contentsOfDirectory(atPath: fileManager.comicDir(for: comicId).path)
        return contents?.contains(where: { $0.hasPrefix("page_") }) == true
    }

    func deleteDownload(comicId: String) {
        tasks.removeValue(forKey: comicId)
        fileManager.deleteComic(comicId: comicId)
        syncDeleteFromStore(comicId: comicId)
        refreshStats()
    }

    func restoreFromStore(context: ModelContext) {
        let downloadedIds = Set(fileManager.downloadedComicIds)
        let descriptor = FetchDescriptor<DownloadedComicRecord>(predicate: #Predicate { $0.state == "completed" })
        let records = context.fetchOrLog(descriptor, label: "恢复下载记录")
        for record in records {
            if downloadedIds.contains(record.comicId) {
                if tasks[record.comicId] == nil {
                    let task = DownloadTask(
                        comicId: record.comicId, title: record.title,
                        totalPages: record.pageCount, completedPages: record.pageCount,
                        state: .completed
                    )
                    tasks[record.comicId] = task
                }
            } else {
                let dir = fileManager.comicDir(for: record.comicId)
                let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
                let hasPages = contents?.contains(where: { $0.hasPrefix("page_") }) == true
                if hasPages {
                    let meta = OfflineComicMeta(
                        comicId: record.comicId, title: record.title,
                        pageCount: record.pageCount, downloadedAt: Date(), fileSize: nil
                    )
                    try? fileManager.saveMeta(meta, comicId: record.comicId)
                    if tasks[record.comicId] == nil {
                        let task = DownloadTask(
                            comicId: record.comicId, title: record.title,
                            totalPages: record.pageCount, completedPages: record.pageCount,
                            state: .completed
                        )
                        tasks[record.comicId] = task
                    }
                } else {
                    context.delete(record)
                }
            }
        }
        context.saveOrLog()

        for comicId in downloadedIds {
            guard tasks[comicId] == nil else { continue }
            if let meta = fileManager.loadMeta(comicId: comicId) {
                let task = DownloadTask(
                    comicId: comicId, title: meta.title,
                    totalPages: meta.pageCount, completedPages: meta.pageCount,
                    state: .completed
                )
                tasks[comicId] = task
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
        
        let comicId = task.comicId
        let total = task.totalPages
        let isNovel = task.isNovel
        
        // 立即保存元数据（确保断网时能读取页数）
        let meta = OfflineComicMeta(
            comicId: comicId,
            title: task.title,
            pageCount: total,
            downloadedAt: Date(),
            fileSize: nil
        )
        try? fileManager.saveMeta(meta, comicId: comicId)
        syncComicToCache(comicId: comicId, title: task.title, pageCount: total)
        
        // 统计已下载数并找出缺失的页面
        var downloadedCount = 0
        var missingIndices: [Int] = []
        for i in 0..<total {
            if fileManager.isPageDownloaded(comicId: comicId, page: i) {
                downloadedCount += 1
            } else {
                missingIndices.append(i)
            }
        }
        task.completedPages = downloadedCount
        
        if missingIndices.isEmpty {
            task.state = .completed
            syncToStore(task: task)
            refreshStats()
            processQueue()
            return
        }
        
        // 为缺失的每一页发起 Background Download Task
        for index in missingIndices {
            let url: URL?
            if isNovel {
                url = URL(string: "\(APIClient.shared.serverURL)/api/comics/\(comicId)/chapter/\(index)")
            } else {
                url = APIClient.shared.pageImageURL(comicId: comicId, page: index)
            }
            guard let validURL = url else { continue }
            
            let request = APIClient.shared.authenticatedRequest(url: validURL, timeout: pageTimeout)
            let dt = backgroundSession.downloadTask(with: request)
            dt.taskDescription = "\(comicId)|\(index)|\(isNovel ? "novel" : "comic")"
            dt.resume()
        }
    }

    // MARK: - URLSessionDownloadDelegate

    func handleDownloadFinished(downloadTask: URLSessionDownloadTask, location: URL) {
        guard let desc = downloadTask.taskDescription else { return }
        let parts = desc.split(separator: "|")
        guard parts.count == 3 else { return }
        let comicId = String(parts[0])
        let index = Int(parts[1]) ?? 0
        let type = String(parts[2])
        
        do {
                let data = try Data(contentsOf: location)
                if type == "novel" {
                    if let response = try? JSONDecoder().decode(ChapterContent.self, from: data),
                       let text = response.content,
                       let textData = text.data(using: .utf8) {
                        try self.fileManager.savePageData(textData, comicId: comicId, page: index)
                    } else {
                        AppLogger.error("解析小说章节 JSON 失败: \(comicId)/\(index)")
                    }
                } else {
                    try self.fileManager.savePageData(data, comicId: comicId, page: index)
                }
                
                if let task = self.tasks[comicId] {
                    task.completedPages += 1
                    self.refreshStats()
                }
            } catch {
                AppLogger.error("处理下载文件失败 \(comicId)/\(index): \(error)")
            }
    }

    func handleTaskCompleted(task: URLSessionTask, error: Error?) {
        guard let desc = task.taskDescription else { return }
        let parts = desc.split(separator: "|")
        guard parts.count == 3 else { return }
        let comicId = String(parts[0])
        
        guard self.tasks[comicId] != nil else { return }
            
            if let error = error {
                let nsError = error as NSError
                // 忽略主动取消导致的错误
                if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                    return
                }
                AppLogger.error("下载页面失败 \(desc): \(error)")
                // 如果出错，最终检查时 completedPages 将不达标，任务会被标记为 failed
            }
            
            // 检查该任务是否已完成（所有的 subtasks 都结束了）
            // 在 Background Session 中，我们可以通过挂起数量判断
            // 或者更简单：每次任务结束，我们就重新核算本地文件数，如果全下完了就标记完成
            self.checkTaskCompletion(for: comicId)
    }

    private func checkTaskCompletion(for comicId: String) {
        guard let task = tasks[comicId], task.state == .downloading else { return }
        
        backgroundSession.getAllTasks { [weak self] sessionTasks in
            guard let self = self else { return }
            
            // 找出属于该 comicId 且还在运行的底层网络任务
            let activeSubTasks = sessionTasks.filter { t in
                guard let desc = t.taskDescription else { return false }
                return desc.hasPrefix("\(comicId)|") && t.state == .running
            }
            
            Task { @MainActor in
                // 如果还有正在下载的页面，则继续等待
                if !activeSubTasks.isEmpty { return }
                
                // 本书所有请求已结束，进行最终核算
                var finalDownloadedCount = 0
                for p in 0..<task.totalPages {
                    if self.fileManager.isPageDownloaded(comicId: comicId, page: p) {
                        finalDownloadedCount += 1
                    }
                }
                task.completedPages = finalDownloadedCount
                
                if task.completedPages >= task.totalPages {
                    task.state = .completed
                    AppLogger.log("下载完成: \(task.title) (\(task.totalPages))")
                } else {
                    task.state = .failed
                    AppLogger.error("下载失败，部分页面未成功下载: \(task.title)")
                }
                
                self.refreshStats()
                self.syncToStore(task: task)
                self.processQueue()
            }
        }
    }

    func handleBackgroundEventsFinished() {
        self.backgroundCompletionHandler?()
        self.backgroundCompletionHandler = nil
    }

    // MARK: - SwiftData 同步

    private var modelContext: ModelContext?

    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }

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
@Observable
final class DownloadTask: Identifiable {
    let id: String  // comicId
    let comicId: String
    let title: String
    let totalPages: Int
    let isNovel: Bool
    var completedPages: Int
    var state: DownloadState

    var progress: Double {
        guard totalPages > 0 else { return 0 }
        return Double(completedPages) / Double(totalPages)
    }

    init(comicId: String, title: String, totalPages: Int, completedPages: Int, state: DownloadState, isNovel: Bool = false) {
        self.id = comicId
        self.comicId = comicId
        self.title = title
        self.totalPages = totalPages
        self.completedPages = completedPages
        self.state = state
        self.isNovel = isNovel
    }
}

enum DownloadState: String, Codable {
    case waiting
    case downloading
    case paused
    case completed
    case failed
}


// MARK: - SessionDelegate

final class SessionDelegate: NSObject, URLSessionDownloadDelegate {
    private weak var manager: DownloadManager?
    
    init(manager: DownloadManager) {
        self.manager = manager
        super.init()
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Must bounce to MainActor if we want to call MainActor methods safely.
        // Or we can just let handleDownloadFinished run on MainActor.
        Task { @MainActor in
            manager?.handleDownloadFinished(downloadTask: downloadTask, location: location)
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Task { @MainActor in
            manager?.handleTaskCompleted(task: task, error: error)
        }
    }
    
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            manager?.handleBackgroundEventsFinished()
        }
    }
}
