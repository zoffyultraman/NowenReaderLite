import Foundation
import SwiftData

@MainActor
@Observable
final class ComicReaderViewModel {
    var totalPages = 0
    var currentPage = 0
    var isLoading = true
    var currentComicId: String
    var groupContext: ReadingGroupContext?

    /// 供 Slider 使用的 Double 绑定（KeyPath binding 代替闭包 binding）
    var sliderValue: Double {
        get { Double(currentPage) }
        set { onSliderChanged(Int(newValue)) }
    }

    private var activityTracker: ReadingActivityTracker?
    private let api = APIClient.shared
    private var modelContext: ModelContext?

    init() {
        self.currentComicId = ""
    }

    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }

    func load(comicId: String, initialPage: Int, groupContext: ReadingGroupContext? = nil) async {
        self.currentComicId = comicId
        self.groupContext = groupContext
        self.currentPage = initialPage
        do {
            let pages = try await api.fetchPages(comicId: comicId)
            totalPages = pages.totalPages
            isLoading = false
            startActivity()
        } catch {
            AppLogger.log("fetchPages 失败: \(error.localizedDescription)")
            // 离线 fallback：从本地元数据读取页数
            if let meta = OfflineFileManager.shared.loadMeta(comicId: comicId), meta.pageCount > 0 {
                totalPages = meta.pageCount
                AppLogger.log("离线 fallback 成功: \(comicId), \(meta.pageCount) 页")
                startActivity()
            } else {
                AppLogger.log("离线 fallback 失败: 无本地 meta, comicId=\(comicId)")
            }
            isLoading = false
        }
    }

    func loadVolume(comicId: String, initialPage: Int) async {
        await saveProgressAndWait()
        await endSessionAndWait()
        isLoading = true

        // Update group context index
        if let ctx = groupContext,
           let newIdx = ctx.volumeIds.firstIndex(of: comicId) {
            groupContext = ReadingGroupContext(
                groupId: ctx.groupId,
                volumeIds: ctx.volumeIds,
                currentIndex: newIdx
            )
        }

        currentComicId = comicId
        currentPage = initialPage

        do {
            let pages = try await api.fetchPages(comicId: comicId)
            totalPages = pages.totalPages
            isLoading = false
            startActivity()
        } catch {
            AppLogger.error("加载下一卷失败: \(error)")
            // 离线 fallback：从本地元数据读取页数
            if let meta = OfflineFileManager.shared.loadMeta(comicId: comicId), meta.pageCount > 0 {
                totalPages = meta.pageCount
                AppLogger.log("离线模式：使用本地元数据，共 \(meta.pageCount) 页")
                startActivity()
            }
            isLoading = false
        }
    }

    func onPageChanged(_ page: Int) {
        currentPage = page
        saveProgress()
    }

    func onSliderChanged(_ page: Int) {
        currentPage = page
    }

    func saveProgress() {
        let page = currentPage
        let comicId = currentComicId
        let resolvedTotalPages = totalPages
        activityTracker?.updatePage(page: page, totalPages: resolvedTotalPages)
        updateCachedProgress(comicId: comicId, page: page)
    }

    private func updateCachedProgress(comicId: String, page: Int) {
        guard let context = modelContext else { return }
        let id = comicId
        let descriptor = FetchDescriptor<CachedComic>(predicate: #Predicate { $0.id == id })
        let cached = context.fetchOrLog(descriptor, label: "更新阅读进度")
        if let first = cached.first {
            first.lastReadPage = page
            if first.pageCount > 0 {
                first.progress = min(100, Int(Double(page + 1) / Double(first.pageCount) * 100))
            }
            first.lastReadAt = Date()
        } else {
            // 缓存中不存在，创建新记录
            let comic = CachedComic()
            comic.id = comicId
            comic.title = comicId
            comic.pageCount = totalPages
            comic.lastReadPage = page
            comic.cachedAt = Date()
            comic.progress = totalPages > 0 ? min(100, Int(Double(page + 1) / Double(totalPages) * 100)) : 0
            comic.lastReadAt = Date()
            context.insert(comic)
        }
        context.saveOrLog()
    }

    /// 等待完成版本，退出时调用
    func saveProgressAndWait() async {
        activityTracker?.updatePage(page: currentPage, totalPages: totalPages)
        updateCachedProgress(comicId: currentComicId, page: currentPage)
        await flushActivity(totalPages: totalPages, finalize: false)
    }

    func endSessionAndWait() async {
        activityTracker?.updatePage(page: currentPage, totalPages: totalPages)
        updateCachedProgress(comicId: currentComicId, page: currentPage)
        await flushActivity(totalPages: totalPages, finalize: true)
        activityTracker = nil
    }

    func pauseActivity() {
        activityTracker?.setActive(false)
    }

    func resumeActivity() {
        activityTracker?.setActive(true)
    }

    private func startActivity() {
        guard totalPages > 0, !currentComicId.isEmpty else { return }
        activityTracker = ReadingActivityTracker(comicId: currentComicId)
        activityTracker?.start(page: currentPage, totalPages: totalPages)
    }

    private func flushActivity(totalPages: Int, finalize: Bool) async {
        guard totalPages > 0 else { return }
        do {
            try await activityTracker?.flush(finalize: finalize)
        } catch {
            AppLogger.log("阅读活动上报失败，已暂存待补传: \(error.localizedDescription)")
        }
    }
}

@MainActor
final class ReadingActivityTracker {
    let comicId: String

    private let api = APIClient.shared
    private let clientSessionId: String
    private var page = 0
    private var totalPages = 0
    private var activeSeconds = 0
    private var sequence = 0
    private var trackProgress = true
    private var isActive = true
    private var isStarted = false
    private var isFinalized = false
    private var activeTimer: Task<Void, Never>?
    private var heartbeatTimer: Task<Void, Never>?
    private var pageFlushTask: Task<Void, Never>?
    private var isFlushing = false
    private var pendingFlushRequested = false
    private var pendingFinalizeRequested = false

    init(comicId: String) {
        self.comicId = comicId
        self.clientSessionId = "ios-\(UUID().uuidString)"
    }

    func start(page: Int, totalPages: Int, trackProgress: Bool = true) {
        guard !isStarted, totalPages > 0 else { return }
        isStarted = true
        self.page = page
        self.totalPages = totalPages
        self.trackProgress = trackProgress

        activeTimer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !self.isFinalized else { return }
                if self.isActive { self.activeSeconds += 1 }
            }
        }

        heartbeatTimer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, !self.isFinalized else { return }
                try? await self.flush(finalize: false)
            }
        }

        Task { try? await flush(finalize: false) }
    }

    func updatePage(page: Int, totalPages: Int, trackProgress: Bool = true) {
        guard isStarted, !isFinalized else { return }
        self.page = page
        if totalPages > 0 { self.totalPages = totalPages }
        self.trackProgress = trackProgress

        pageFlushTask?.cancel()
        pageFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let self, !Task.isCancelled else { return }
            try? await self.flush(finalize: false)
        }
    }

    func setActive(_ active: Bool) {
        guard isStarted, !isFinalized else { return }
        isActive = active
        if !active {
            Task { try? await flush(finalize: false) }
        }
    }

    func flush(finalize: Bool) async throws {
        guard isStarted, !isFinalized, totalPages > 0 else { return }
        guard finalize || activeSeconds > 0 else { return }

        if isFlushing {
            pendingFlushRequested = true
            pendingFinalizeRequested = pendingFinalizeRequested || finalize
            while isFlushing {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if finalize, !isFinalized {
                try await flush(finalize: true)
            }
            return
        }

        isFlushing = true
        defer { isFlushing = false }

        try await performFlush(finalize: finalize)

        while pendingFlushRequested, !isFinalized {
            let nextFinalize = pendingFinalizeRequested
            pendingFlushRequested = false
            pendingFinalizeRequested = false
            if nextFinalize || activeSeconds > 0 {
                try await performFlush(finalize: nextFinalize)
            }
        }
    }

    private func performFlush(finalize: Bool) async throws {
        guard isStarted, !isFinalized, totalPages > 0 else { return }
        guard finalize || activeSeconds > 0 else { return }
        sequence += 1
        let activity = PendingReadingActivityManager.PendingActivity(
            comicId: comicId,
            clientSessionId: clientSessionId,
            page: page,
            totalPages: totalPages,
            activeSeconds: activeSeconds,
            sequence: sequence,
            finalize: finalize,
            trackProgress: trackProgress,
            updatedAt: Date()
        )
        guard api.isNetworkReachable, !api.isOfflineMode else {
            PendingReadingActivityManager.shared.save(activity)
            if finalize {
                finish()
            }
            throw APIError.networkError
        }
        do {
            try await api.recordReadingActivity(
                comicId: activity.comicId,
                clientSessionId: activity.clientSessionId,
                page: activity.page,
                totalPages: activity.totalPages,
                activeSeconds: activity.activeSeconds,
                sequence: activity.sequence,
                finalize: activity.finalize,
                trackProgress: activity.trackProgress
            )
            PendingReadingActivityManager.shared.removeIfSynced(
                clientSessionId: activity.clientSessionId,
                sequence: activity.sequence
            )
            AppLogger.log("阅读活动已上报: \(activity.comicId) seq=\(activity.sequence) seconds=\(activity.activeSeconds) finalize=\(activity.finalize)")
        } catch {
            PendingReadingActivityManager.shared.save(activity)
            if finalize {
                finish()
            }
            throw error
        }
        if finalize {
            finish()
        }
    }

    private func finish() {
        isFinalized = true
        cancelTimers()
    }

    private func cancelTimers() {
        activeTimer?.cancel()
        heartbeatTimer?.cancel()
        pageFlushTask?.cancel()
        activeTimer = nil
        heartbeatTimer = nil
        pageFlushTask = nil
    }
}
