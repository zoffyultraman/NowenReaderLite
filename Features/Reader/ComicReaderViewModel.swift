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

    private var sessionId: Int?
    private var sessionStart: Date?
    private var hasEnded = false
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
            startSession()
        } catch {
            AppLogger.log("fetchPages 失败: \(error.localizedDescription)")
            // 离线 fallback：从本地元数据读取页数
            if let meta = OfflineFileManager.shared.loadMeta(comicId: comicId), meta.pageCount > 0 {
                totalPages = meta.pageCount
                AppLogger.log("离线 fallback 成功: \(comicId), \(meta.pageCount) 页")
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
            startSession()
        } catch {
            AppLogger.error("加载下一卷失败: \(error)")
            // 离线 fallback：从本地元数据读取页数
            if let meta = OfflineFileManager.shared.loadMeta(comicId: comicId), meta.pageCount > 0 {
                totalPages = meta.pageCount
                AppLogger.log("离线模式：使用本地元数据，共 \(meta.pageCount) 页")
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

    private var saveTask: Task<Void, Never>?

    func saveProgress() {
        saveTask?.cancel()
        let page = currentPage
        let comicId = currentComicId
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            do {
                try await api.updateProgress(comicId: comicId, page: page)
                // 服务器保存成功后才更新本地缓存
                self.updateCachedProgress(comicId: comicId, page: page)
            } catch {
                AppLogger.log("保存进度失败（离线暂存）: \(error.localizedDescription)")
                PendingProgressManager.shared.save(comicId: comicId, page: page)
                self.updateCachedProgress(comicId: comicId, page: page)
            }
        }
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
        saveTask?.cancel()
        do {
            try await api.updateProgress(comicId: currentComicId, page: currentPage)
            updateCachedProgress(comicId: currentComicId, page: currentPage)
        } catch {
            PendingProgressManager.shared.save(comicId: currentComicId, page: currentPage)
            updateCachedProgress(comicId: currentComicId, page: currentPage)
        }
    }

    func endSessionAndWait() async {
        guard let sessionId, let sessionStart, !hasEnded else { return }
        hasEnded = true
        let duration = Int(Date().timeIntervalSince(sessionStart))
        try? await api.endSession(sessionId: sessionId, endPage: currentPage, duration: duration)
    }

    private func startSession() {
        hasEnded = false
        Task {
            sessionId = try? await api.startSession(comicId: currentComicId, startPage: currentPage)
            sessionStart = Date()
        }
    }
}
