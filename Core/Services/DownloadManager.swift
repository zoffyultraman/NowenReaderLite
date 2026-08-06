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
    /// 已按标题排序的活跃任务，避免视图 body 在进度刷新时反复排序。
    private(set) var activeTasks: [DownloadTask] = []
    /// 已按标题排序的完成任务，避免视图 body 在进度刷新时反复排序。
    private(set) var completedTasks: [DownloadTask] = []
    /// 当前正在下载的任务数（用于 Tab 徽标）
    private(set) var activeDownloadCount: Int = 0
    /// 全局下载进度（所有活跃任务的加权平均）
    private(set) var globalProgress: Double = 0
    /// 缓存的离线文件总大小，避免视图求值时同步遍历磁盘。
    private(set) var usedStorageBytes: Int64 = 0
    /// 容量统计完成前不允许启动受限下载，避免初始值 0 绕过上限。
    private(set) var isStorageUsageLoaded = false
    /// 已完整下载的漫画 ID，由恢复、完成和删除事件维护。
    private(set) var downloadedComicIds: Set<String> = []

    private let fileManager = OfflineFileManager.shared
    private var downloadQueue: [String] = []   // 等待中的 comicId
    private var storageReservations: [String: Int64] = [:]
    private var localStorageBytesByComic: [String: Int64] = [:]
    private var deletingComicIds = Set<String>()
    private var downloadStateVersion = 0
    private var storageRefreshVersion = 0
    private var isRestoring = false
    private var didRestore = false
    private var activeCount: Int { tasks.values.filter { $0.state == .downloading }.count }

    /// 最大并发下载任务数（对于 background session，OS 会自行调度，但这控制着“同时处在 downloading 状态的整书任务数”）
    private let maxConcurrent = 3
    private let pageTimeout: TimeInterval = 30
    private let novelChapterTimeout: TimeInterval = 120

    // MARK: - 存储上限

    var storageLimitBytes: Int64 {
        let mb = UserDefaults.standard.integer(forKey: "offlineStorageLimitMB")
        return mb > 0 ? Int64(mb) * 1024 * 1024 : 0
    }

    var hasStorageSpace: Bool {
        let limit = storageLimitBytes
        guard limit > 0 else { return true }
        guard isStorageUsageLoaded else { return false }
        return usedStorageBytes + storageReservations.values.reduce(0, +) < limit
    }

    func wouldExceedLimit(
        comicId: String? = nil,
        pageCount: Int,
        fileSize: Int64? = nil
    ) -> Bool {
        let limit = storageLimitBytes
        guard limit > 0 else { return false }
        guard isStorageUsageLoaded else { return true }
        let completedPages = comicId.flatMap { tasks[$0]?.completedPages } ?? 0
        let estimated = estimatedRemainingStorageBytes(
            comicId: comicId,
            pageCount: pageCount,
            completedPages: completedPages,
            fileSize: fileSize
        )
        return usedStorageBytes + storageReservations.values.reduce(0, +) + estimated > limit
    }

    // MARK: - 后台会话

    @ObservationIgnored var backgroundCompletionHandler: (() -> Void)?

    @ObservationIgnored private lazy var sessionDelegate = SessionDelegate(manager: self)

    @ObservationIgnored private lazy var sessionDelegateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.nowen.readerlite.download-delegate"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()

    @ObservationIgnored private lazy var backgroundSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.nowen.readerlite.background")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        return URLSession(
            configuration: config,
            delegate: sessionDelegate,
            delegateQueue: sessionDelegateQueue
        )
    }()

    private init() {
        // 提前访问一下，确保配置在 App 启动时绑定 delegate
        _ = backgroundSession
        Task { await refreshStorageUsage() }
    }

    func refreshStorageUsage() async {
        storageRefreshVersion += 1
        let version = storageRefreshVersion
        let manager = fileManager
        let snapshot = await Task.detached(priority: .utility) {
            manager.diskUsageSnapshot()
        }.value
        guard version == storageRefreshVersion else { return }
        usedStorageBytes = snapshot.totalBytes
        localStorageBytesByComic = snapshot.bytesByComicId
        isStorageUsageLoaded = true
    }

    private func estimatedRemainingStorageBytes(
        comicId: String?,
        pageCount: Int,
        completedPages: Int,
        fileSize: Int64?
    ) -> Int64 {
        let missingPages = max(pageCount - completedPages, 0)
        guard missingPages > 0 else { return 0 }
        if let comicId,
           let fileSize,
           fileSize > 0,
           let existingBytes = localStorageBytesByComic[comicId] {
            let declaredRemaining = max(fileSize - existingBytes, 0)
            guard completedPages > 0 else { return declaredRemaining }
            let observedRemaining = Int64(
                ceil(
                    Double(existingBytes)
                        / Double(completedPages)
                        * Double(missingPages)
                )
            )
            return max(declaredRemaining, observedRemaining)
        }
        if let fileSize, fileSize > 0, pageCount > 0 {
            return Int64(
                ceil(Double(fileSize) * Double(missingPages) / Double(pageCount))
            )
        }
        return Int64(missingPages) * 300 * 1024
    }

    private func reconcileStorageReservation(for comicId: String) async {
        await refreshStorageUsage()
        storageReservations.removeValue(forKey: comicId)
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

    private func refreshTaskLists() {
        activeTasks = tasks.values
            .filter { $0.state != .completed }
            .sorted { $0.title < $1.title }
        completedTasks = tasks.values
            .filter { $0.state == .completed }
            .sorted { $0.title < $1.title }
    }

    // MARK: - Public API

    @discardableResult
    func download(comicId: String, title: String, pageCount: Int, fileSize: Int64?, isNovel: Bool = false) -> Bool {
        guard !deletingComicIds.contains(comicId) else { return false }
        let previousTask = tasks[comicId]
        if let previousTask, previousTask.state != .failed { return false }
        if downloadedComicIds.contains(comicId) { return false }

        if storageLimitBytes > 0, !isStorageUsageLoaded {
            Task { await refreshStorageUsage() }
            return false
        }

        if wouldExceedLimit(comicId: comicId, pageCount: pageCount, fileSize: fileSize) {
            AppLogger.error("存储空间不足，跳过下载: \(title)")
            return false
        }

        let completedPages = previousTask?.completedPages ?? 0
        let task = DownloadTask(
            comicId: comicId, title: title,
            totalPages: pageCount, completedPages: completedPages,
            state: .waiting, isNovel: isNovel, fileSize: fileSize
        )
        tasks[comicId] = task
        storageReservations[comicId] = estimatedRemainingStorageBytes(
            comicId: comicId,
            pageCount: pageCount,
            completedPages: completedPages,
            fileSize: fileSize
        )
        downloadQueue.append(comicId)
        syncToStore(task: task)
        refreshTaskLists()
        refreshStats()
        processQueue()
        Task { await saveGroupInfoIfNeeded(comicId: comicId) }
        return true
    }

    private func saveGroupInfoIfNeeded(comicId: String) async {
        let localGroups = await Task.detached(priority: .utility) {
            OfflineFileManager.shared.loadGroups()
        }.value
        if localGroups.contains(where: { $0.comicIds.contains(comicId) }) { return }
        guard let map = try? await APIClient.shared.fetchComicGroupMapFull(),
              let groupIds = map[comicId], !groupIds.isEmpty else { return }
        for groupId in groupIds {
            guard let detail = try? await APIClient.shared.fetchGroupDetail(id: groupId) else { continue }
            let meta = OfflineGroupMeta(
                id: detail.id, name: detail.name, coverUrl: detail.coverUrl,
                author: detail.author, description: detail.description,
                comicCount: detail.readingUnits.count, sortOrder: nil,
                comicIds: detail.readingUnits.map { $0.id }
            )
            await Task.detached(priority: .utility) {
                OfflineFileManager.shared.saveGroup(meta)
            }.value
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
                comicCount: group.readingUnits.count,
                sortOrder: nil,
                comicIds: group.readingUnits.map { $0.id }
            )
            Task.detached(priority: .utility) {
                OfflineFileManager.shared.saveGroup(meta)
            }
        }
        var queued = 0
        var skipped = 0
        for comic in comics {
            let success = download(
                comicId: comic.id,
                title: comic.title,
                pageCount: comic.pageCount,
                fileSize: comic.fileSize,
                isNovel: comic.type == "novel"
            )
            if success { queued += 1 } else { skipped += 1 }
        }
        return (queued, skipped)
    }

    func pause(comicId: String) {
        guard let task = tasks[comicId],
              task.state == .downloading || task.state == .waiting else {
            return
        }
        let hadActiveTransfers = task.state == .downloading
        task.state = .paused
        syncToStore(task: task)
        if hadActiveTransfers {
            backgroundSession.getAllTasks { sessionTasks in
                for sessionTask in sessionTasks {
                    guard BackgroundDownloadDescriptor(
                        taskDescription: sessionTask.taskDescription
                    )?.comicId == comicId else {
                        continue
                    }
                    sessionTask.cancel()
                }
            }
        }
        downloadQueue.removeAll { $0 == comicId }
        refreshTaskLists()
        refreshStats()
        processQueue()
    }

    func resume(comicId: String) {
        guard let task = tasks[comicId], task.state == .paused else { return }
        task.state = .waiting
        downloadQueue.append(comicId)
        syncToStore(task: task)
        refreshTaskLists()
        refreshStats()
        processQueue()
    }

    func cancel(comicId: String) {
        pause(comicId: comicId)
        downloadStateVersion += 1
        deletingComicIds.insert(comicId)
        markDeletingInStore(comicIds: [comicId])
        tasks.removeValue(forKey: comicId)
        downloadQueue.removeAll { $0 == comicId }
        downloadedComicIds.remove(comicId)
        storageReservations.removeValue(forKey: comicId)
        refreshTaskLists()
        refreshStats()
        let manager = fileManager
        Task {
            let deleted = await Task.detached(priority: .utility) {
                manager.deleteComic(comicId: comicId)
            }.value
            if deleted {
                syncDeleteFromStore(comicIds: [comicId])
                deletingComicIds.remove(comicId)
            }
            await refreshStorageUsage()
        }
    }

    func task(for comicId: String) -> DownloadTask? {
        tasks[comicId]
    }

    func isDownloaded(comicId: String) -> Bool {
        if let task = tasks[comicId], task.state == .completed { return true }
        return downloadedComicIds.contains(comicId)
    }

    func deleteDownload(comicId: String) {
        downloadStateVersion += 1
        deletingComicIds.insert(comicId)
        markDeletingInStore(comicIds: [comicId])
        tasks.removeValue(forKey: comicId)
        downloadedComicIds.remove(comicId)
        storageReservations.removeValue(forKey: comicId)
        refreshTaskLists()
        refreshStats()
        let manager = fileManager
        Task {
            let deleted = await Task.detached(priority: .utility) {
                manager.deleteComic(comicId: comicId)
            }.value
            if deleted {
                syncDeleteFromStore(comicIds: [comicId])
                deletingComicIds.remove(comicId)
            }
            await refreshStorageUsage()
        }
    }

    func deleteDownloads(comicIds: [String]) {
        let ids = Set(comicIds)
        guard !ids.isEmpty else { return }
        downloadStateVersion += 1
        deletingComicIds.formUnion(ids)
        markDeletingInStore(comicIds: ids)
        for comicId in ids {
            tasks.removeValue(forKey: comicId)
            downloadedComicIds.remove(comicId)
            storageReservations.removeValue(forKey: comicId)
        }
        refreshTaskLists()
        refreshStats()

        let manager = fileManager
        Task {
            let deletedIds = await Task.detached(priority: .utility) {
                var deletedIds = Set<String>()
                for comicId in ids {
                    if manager.deleteComic(comicId: comicId) {
                        deletedIds.insert(comicId)
                    }
                }
                return deletedIds
            }.value
            syncDeleteFromStore(comicIds: deletedIds)
            deletingComicIds.subtract(deletedIds)
            await refreshStorageUsage()
        }
    }

    func restoreFromStore(context: ModelContext) async {
        guard !isRestoring, !didRestore else { return }
        isRestoring = true
        defer { isRestoring = false }

        let records = context.fetchOrLog(
            FetchDescriptor<DownloadedComicRecord>(),
            label: "恢复下载记录"
        )
        let deletingRecordIds = Set(
            records.lazy
                .filter { $0.state == DownloadState.deleting.rawValue }
                .map(\.comicId)
        )
        let activeRecords = records.filter {
            !deletingRecordIds.contains($0.comicId)
        }
        if !deletingRecordIds.isEmpty {
            downloadStateVersion += 1
        }
        deletingComicIds.formUnion(deletingRecordIds)
        let backgroundTasks = await allBackgroundTasks()
        for sessionTask in backgroundTasks {
            guard let descriptor = BackgroundDownloadDescriptor(
                taskDescription: sessionTask.taskDescription
            ), deletingRecordIds.contains(descriptor.comicId) else {
                continue
            }
            sessionTask.cancel()
        }

        let manager = fileManager
        let deletedTombstones = await Task.detached(priority: .utility) {
            var deletedIds = Set<String>()
            for comicId in deletingRecordIds {
                if manager.deleteComic(comicId: comicId) {
                    deletedIds.insert(comicId)
                }
            }
            return deletedIds
        }.value
        for record in records where deletedTombstones.contains(record.comicId) {
            context.delete(record)
        }
        if !deletedTombstones.isEmpty {
            context.saveOrLog()
            deletingComicIds.subtract(deletedTombstones)
        }

        let recordValues = activeRecords.map {
            DownloadRecordSnapshot(
                comicId: $0.comicId,
                title: $0.title,
                pageCount: $0.pageCount,
                state: DownloadState(rawValue: $0.state) ?? .failed,
                fileSize: $0.fileSize,
                isNovel: $0.isNovel,
                generation: $0.generation
            )
        }
        let backgroundDescriptors: [BackgroundDownloadDescriptor] =
            backgroundTasks.compactMap { sessionTask -> BackgroundDownloadDescriptor? in
            guard let descriptor = BackgroundDownloadDescriptor(
                taskDescription: sessionTask.taskDescription
            ), !deletingRecordIds.contains(descriptor.comicId) else {
                return nil
            }
            return descriptor
        }
        let descriptorsByComic = Dictionary(
            grouping: backgroundDescriptors,
            by: \.comicId
        )
        let diskSnapshot = await Task.detached(priority: .utility) {
            var snapshot = manager.downloadStateSnapshot()
            for record in recordValues
            where snapshot.hasAllRequiredPages(
                comicId: record.comicId,
                pageCount: record.pageCount
            )
                && snapshot.metas[record.comicId] == nil {
                let repairedMeta = OfflineComicMeta(
                    comicId: record.comicId,
                    title: record.title,
                    pageCount: record.pageCount,
                    downloadedAt: Date(),
                    fileSize: record.fileSize,
                    isNovel: record.isNovel
                )
                try? manager.saveMeta(repairedMeta, comicId: record.comicId)
            }
            snapshot = manager.downloadStateSnapshot()
            return snapshot
        }.value
        await refreshStorageUsage()

        downloadedComicIds = diskSnapshot.completedIds
            .subtracting(deletingRecordIds)
        let recordsById = Dictionary(uniqueKeysWithValues: recordValues.map { ($0.comicId, $0) })
        let allIds = Set(recordsById.keys)
            .union(diskSnapshot.metas.keys)
            .union(descriptorsByComic.keys)
            .subtracting(deletingRecordIds)
        var restoredTasks: [String: DownloadTask] = [:]
        var restoredQueue: [String] = []
        var restoredReservations: [String: Int64] = [:]

        for comicId in allIds {
            let record = recordsById[comicId]
            let meta = diskSnapshot.metas[comicId]
            let descriptors = descriptorsByComic[comicId] ?? []
            let pageCount = record?.pageCount ?? meta?.pageCount ?? 0
            guard pageCount > 0 else { continue }
            let completedPages = diskSnapshot.completedPageCount(
                comicId: comicId,
                pageCount: pageCount
            )
            let isComplete = diskSnapshot.completedIds.contains(comicId)
            let generation = descriptors.first?.generation
                ?? record?.generation
                ?? UUID().uuidString
            let isNovel: Bool
            if let descriptor = descriptors.first {
                isNovel = descriptor.isNovel
            } else if let record {
                isNovel = record.isNovel
            } else {
                isNovel = meta?.isNovel ?? false
            }
            let state: DownloadState
            if isComplete {
                state = .completed
            } else if record?.state == .paused {
                state = .paused
            } else if !descriptors.isEmpty {
                state = .downloading
            } else if record?.state == .waiting || record?.state == .downloading {
                state = .waiting
            } else {
                state = .failed
            }

            let task = DownloadTask(
                comicId: comicId,
                title: record?.title ?? meta?.title ?? comicId,
                totalPages: pageCount,
                completedPages: completedPages,
                state: state,
                isNovel: isNovel,
                fileSize: record?.fileSize ?? meta?.fileSize,
                generation: generation
            )
            restoredTasks[comicId] = task

            if state == .waiting || state == .downloading || state == .paused {
                manager.prepareComicDownload(
                    comicId: comicId,
                    generation: generation
                )
                restoredReservations[comicId] = estimatedRemainingStorageBytes(
                    comicId: comicId,
                    pageCount: pageCount,
                    completedPages: completedPages,
                    fileSize: task.fileSize
                )
            }
            if state == .waiting {
                restoredQueue.append(comicId)
            } else if state == .paused, !descriptors.isEmpty {
                for sessionTask in backgroundTasks {
                    guard BackgroundDownloadDescriptor(
                        taskDescription: sessionTask.taskDescription
                    )?.comicId == comicId else {
                        continue
                    }
                    sessionTask.cancel()
                }
            }
        }

        tasks = restoredTasks
        downloadQueue = restoredQueue
        storageReservations = restoredReservations
        var persistentRecordsById = Dictionary(
            uniqueKeysWithValues: activeRecords.map { ($0.comicId, $0) }
        )
        for task in restoredTasks.values {
            if let record = persistentRecordsById[task.comicId] {
                updateRecord(record, from: task)
            } else {
                let record = makeRecord(from: task)
                context.insert(record)
                persistentRecordsById[task.comicId] = record
            }
        }
        for record in activeRecords where restoredTasks[record.comicId] == nil {
            context.delete(record)
        }
        context.saveOrLog()
        refreshTaskLists()
        refreshStats()
        didRestore = true
        processQueue()
    }

    private func allBackgroundTasks() async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in
            backgroundSession.getAllTasks { tasks in
                continuation.resume(returning: tasks)
            }
        }
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
        syncToStore(task: task)
        refreshStats()

        let comicId = task.comicId
        let total = task.totalPages
        let generation = task.generation
        let meta = OfflineComicMeta(
            comicId: comicId,
            title: task.title,
            pageCount: total,
            downloadedAt: Date(),
            fileSize: task.fileSize,
            isNovel: task.isNovel
        )
        syncComicToCache(
            comicId: comicId,
            title: task.title,
            pageCount: total,
            isNovel: task.isNovel
        )
        fileManager.prepareComicDownload(
            comicId: comicId,
            generation: generation
        )

        Task {
            let manager = fileManager
            let novelPageList: PageList?
            if task.isNovel {
                novelPageList = try? await APIClient.shared.fetchPages(
                    comicId: comicId
                )
            } else {
                novelPageList = nil
            }
            let downloadedIndices = await Task.detached(priority: .utility) {
                try? manager.saveMeta(
                    meta,
                    comicId: comicId,
                    generation: generation
                )
                if let novelPageList {
                    try? manager.saveNovelPageList(
                        novelPageList,
                        comicId: comicId,
                        generation: generation
                    )
                }
                return manager.downloadedPageIndices(comicId: comicId)
            }.value

            guard tasks[comicId] === task, task.state == .downloading else { return }
            task.completedPages = downloadedIndices.lazy
                .filter { (0..<total).contains($0) }
                .count
            let missingIndices = (0..<total).filter { !downloadedIndices.contains($0) }

            if missingIndices.isEmpty {
                task.state = .completed
                downloadedComicIds.insert(comicId)
                syncToStore(task: task)
                refreshTaskLists()
                refreshStats()
                await reconcileStorageReservation(for: comicId)
                processQueue()
                return
            }

            var startedTaskCount = 0
            for index in missingIndices {
                let url: URL?
                if task.isNovel {
                    url = URL(string: "\(APIClient.shared.serverURL)/api/comics/\(comicId)/chapter/\(index)")
                } else {
                    url = APIClient.shared.pageImageURL(comicId: comicId, page: index)
                }
                guard let validURL = url else { continue }

                let timeout = task.isNovel ? novelChapterTimeout : pageTimeout
                let request = APIClient.shared.authenticatedRequest(
                    url: validURL,
                    timeout: timeout
                )
                let downloadTask = backgroundSession.downloadTask(with: request)
                downloadTask.taskDescription = [
                    comicId,
                    String(index),
                    task.isNovel ? "novel" : "comic",
                    generation,
                ].joined(separator: "|")
                downloadTask.resume()
                startedTaskCount += 1
            }

            if startedTaskCount == 0 {
                task.state = .failed
                refreshTaskLists()
                refreshStats()
                syncToStore(task: task)
                await reconcileStorageReservation(for: comicId)
                processQueue()
            }
        }
    }

    // MARK: - URLSessionDownloadDelegate

    func handleDownloadedPage(comicId: String, index: Int, generation: String) {
        guard let task = tasks[comicId],
              task.state == .downloading,
              task.generation == generation else {
            return
        }
        task.completedPages = min(task.completedPages + 1, task.totalPages)
        refreshStats()
    }

    func handleTaskCompleted(task: URLSessionTask, error: Error?) {
        guard let descriptor = BackgroundDownloadDescriptor(
            taskDescription: task.taskDescription
        ) else {
            return
        }
        let comicId = descriptor.comicId
        guard let download = tasks[comicId],
              download.generation == descriptor.generation else {
            return
        }

        if let error {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain,
               nsError.code == NSURLErrorCancelled,
               download.state == .paused {
                return
            }
            AppLogger.error("下载页面失败 \(task.taskDescription ?? ""): \(error)")
        }

        checkTaskCompletion(for: comicId)
    }

    private func checkTaskCompletion(for comicId: String) {
        guard let task = tasks[comicId], task.state == .downloading else { return }
        let generation = task.generation

        backgroundSession.getAllTasks { [weak self] sessionTasks in
            guard let self = self else { return }
            
            // 挂起或正在取消的子任务仍未结束，不能提前核算为失败。
            let activeSubTasks = sessionTasks.filter { t in
                guard let descriptor = BackgroundDownloadDescriptor(
                    taskDescription: t.taskDescription
                ) else {
                    return false
                }
                return descriptor.comicId == comicId
                    && descriptor.generation == generation
                    && t.state != .completed
            }
            
            Task { @MainActor in
                // 如果还有正在下载的页面，则继续等待
                if !activeSubTasks.isEmpty { return }

                let manager = self.fileManager
                let finalDownloadedIndices = await Task.detached(priority: .utility) {
                    manager.downloadedPageIndices(comicId: comicId)
                }.value
                guard task.state == .downloading,
                      task.generation == generation else {
                    return
                }
                task.completedPages = finalDownloadedIndices.lazy
                    .filter { (0..<task.totalPages).contains($0) }
                    .count
                
                if (0..<task.totalPages).allSatisfy(finalDownloadedIndices.contains) {
                    task.state = .completed
                    self.downloadedComicIds.insert(comicId)
                    AppLogger.log("下载完成: \(task.title) (\(task.totalPages))")
                } else {
                    task.state = .failed
                    AppLogger.error("下载失败，部分页面未成功下载: \(task.title)")
                }

                self.refreshTaskLists()
                self.refreshStats()
                self.syncToStore(task: task)
                await self.reconcileStorageReservation(for: comicId)
                self.processQueue()
            }
        }
    }

    func handleBackgroundEventsFinished() {
        let completion = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        Task {
            await reconcileTasksAfterBackgroundEvents()
            completion?()
        }
    }

    private func reconcileTasksAfterBackgroundEvents() async {
        let stateVersion = downloadStateVersion
        let manager = fileManager
        let snapshot = await Task.detached(priority: .utility) {
            manager.downloadStateSnapshot()
        }.value
        guard stateVersion == downloadStateVersion else { return }
        let completedIds = snapshot.completedIds
            .subtracting(deletingComicIds)
        downloadedComicIds = completedIds
        var changedTasks: [DownloadTask] = []

        for comicId in completedIds {
            guard let meta = snapshot.metas[comicId] else { continue }
            if let task = tasks[comicId] {
                if task.completedPages != task.totalPages || task.state != .completed {
                    task.completedPages = task.totalPages
                    task.state = .completed
                    changedTasks.append(task)
                }
            } else {
                let task = DownloadTask(
                    comicId: comicId,
                    title: meta.title,
                    totalPages: meta.pageCount,
                    completedPages: meta.pageCount,
                    state: .completed,
                    isNovel: meta.isNovel == true,
                    fileSize: meta.fileSize
                )
                tasks[comicId] = task
                changedTasks.append(task)
            }
            storageReservations.removeValue(forKey: comicId)
        }
        syncTasksToStore(changedTasks)

        refreshTaskLists()
        refreshStats()
        await refreshStorageUsage()
        processQueue()
    }

    // MARK: - SwiftData 同步

    private var modelContext: ModelContext?

    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }

    private func syncComicToCache(
        comicId: String,
        title: String,
        pageCount: Int,
        isNovel: Bool
    ) {
        guard let context = modelContext else { return }
        let id = comicId
        let existing = context.fetchOrLog(
            FetchDescriptor<CachedComic>(predicate: #Predicate { $0.id == id }),
            label: "查询缓存漫画"
        )
        if let cached = existing.first {
            cached.title = title
            cached.pageCount = pageCount
            cached.type = isNovel ? "novel" : "comic"
            cached.cachedAt = Date()
        } else {
            let cached = CachedComic()
            cached.id = comicId
            cached.title = title
            cached.pageCount = pageCount
            cached.type = isNovel ? "novel" : "comic"
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
            updateRecord(record, from: task)
        } else {
            context.insert(makeRecord(from: task))
        }
        context.saveOrLog()
    }

    private func syncTasksToStore(_ tasks: [DownloadTask]) {
        guard !tasks.isEmpty, let context = modelContext else { return }
        let records = context.fetchOrLog(
            FetchDescriptor<DownloadedComicRecord>(),
            label: "批量查询下载记录"
        )
        var recordsById = Dictionary(
            uniqueKeysWithValues: records.map { ($0.comicId, $0) }
        )
        for task in tasks {
            if let record = recordsById[task.comicId] {
                updateRecord(record, from: task)
            } else {
                let record = makeRecord(from: task)
                context.insert(record)
                recordsById[task.comicId] = record
            }
        }
        context.saveOrLog()
    }

    private func updateRecord(
        _ record: DownloadedComicRecord,
        from task: DownloadTask
    ) {
        record.title = task.title
        record.pageCount = task.totalPages
        record.state = task.state.rawValue
        record.downloadedAt = Date()
        record.fileSize = task.fileSize
        record.isNovel = task.isNovel
        record.generation = task.generation
    }

    private func makeRecord(from task: DownloadTask) -> DownloadedComicRecord {
        DownloadedComicRecord(
            comicId: task.comicId,
            title: task.title,
            pageCount: task.totalPages,
            state: task.state.rawValue,
            fileSize: task.fileSize,
            isNovel: task.isNovel,
            generation: task.generation
        )
    }

    private func markDeletingInStore(comicIds: Set<String>) {
        guard !comicIds.isEmpty, let context = modelContext else { return }
        let records = context.fetchOrLog(
            FetchDescriptor<DownloadedComicRecord>(),
            label: "标记待删除下载记录"
        )
        for record in records where comicIds.contains(record.comicId) {
            record.state = DownloadState.deleting.rawValue
        }
        context.saveOrLog()
    }

    private func syncDeleteFromStore(comicIds: Set<String>) {
        guard !comicIds.isEmpty, let context = modelContext else { return }
        let records = context.fetchOrLog(
            FetchDescriptor<DownloadedComicRecord>(),
            label: "批量删除下载记录"
        )
        for record in records where comicIds.contains(record.comicId) {
            context.delete(record)
        }
        context.saveOrLog()
    }
}

private struct DownloadRecordSnapshot: Sendable {
    let comicId: String
    let title: String
    let pageCount: Int
    let state: DownloadState
    let fileSize: Int64?
    let isNovel: Bool
    let generation: String?
}

private struct BackgroundDownloadDescriptor: Sendable {
    let comicId: String
    let pageIndex: Int
    let isNovel: Bool
    let generation: String

    init?(taskDescription: String?) {
        guard let taskDescription else { return nil }
        let parts = taskDescription.split(
            separator: "|",
            omittingEmptySubsequences: false
        )
        guard parts.count >= 3, let pageIndex = Int(parts[1]) else { return nil }
        comicId = String(parts[0])
        self.pageIndex = pageIndex
        isNovel = parts[2] == "novel"
        generation = parts.count >= 4
            ? String(parts[3])
            : "legacy-\(comicId)"
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
    let fileSize: Int64?
    let generation: String
    var completedPages: Int
    var state: DownloadState

    var progress: Double {
        guard totalPages > 0 else { return 0 }
        return Double(completedPages) / Double(totalPages)
    }

    init(
        comicId: String,
        title: String,
        totalPages: Int,
        completedPages: Int,
        state: DownloadState,
        isNovel: Bool = false,
        fileSize: Int64? = nil,
        generation: String = UUID().uuidString
    ) {
        self.id = comicId
        self.comicId = comicId
        self.title = title
        self.totalPages = totalPages
        self.completedPages = completedPages
        self.state = state
        self.isNovel = isNovel
        self.fileSize = fileSize
        self.generation = generation
    }
}

enum DownloadState: String, Codable, Equatable {
    case waiting
    case downloading
    case paused
    case completed
    case failed
    case deleting
}


// MARK: - SessionDelegate

final class SessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private weak var manager: DownloadManager?
    
    init(manager: DownloadManager) {
        self.manager = manager
        super.init()
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let descriptor = BackgroundDownloadDescriptor(
            taskDescription: downloadTask.taskDescription
        ) else {
            return
        }
        let comicId = descriptor.comicId
        let index = descriptor.pageIndex

        do {
            let data = try Data(contentsOf: location)
            if descriptor.isNovel {
                guard let response = try? JSONDecoder().decode(
                    ChapterContent.self,
                    from: data
                ), response.content != nil else {
                    AppLogger.error("解析小说章节 JSON 失败: \(comicId)/\(index)")
                    return
                }
                try OfflineFileManager.shared.savePageData(
                    data,
                    comicId: comicId,
                    page: index,
                    generation: descriptor.generation
                )
            } else {
                try OfflineFileManager.shared.savePageData(
                    data,
                    comicId: comicId,
                    page: index,
                    generation: descriptor.generation
                )
            }

            Task { @MainActor in
                manager?.handleDownloadedPage(
                    comicId: comicId,
                    index: index,
                    generation: descriptor.generation
                )
            }
        } catch OfflineFileError.discardedDownload,
                OfflineFileError.staleDownloadGeneration {
            return
        } catch {
            AppLogger.error("处理下载文件失败 \(comicId)/\(index): \(error)")
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
