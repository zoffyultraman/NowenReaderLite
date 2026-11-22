import Foundation
import SwiftData

enum ComicPreferenceScope: String, CaseIterable, Identifiable, Sendable {
    case global
    case series
    case comic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .global: return "全局默认"
        case .series: return "当前系列"
        case .comic: return "仅当前作品"
        }
    }
}

@MainActor
@Observable
final class ComicReaderViewModel {
    var totalPages = 0
    var currentPage = 0
    var isLoading = true
    var currentComicId: String
    var groupContext: ReadingGroupContext?
    var volumeTransitionBanner: String?

    // MARK: - 云端同步状态（Phase 2）
    var bookmarks: [UserBookmark] = []
    var scopedPreferences: ScopedReaderPreferences?
    var preferenceScope: ComicPreferenceScope = .global
    var seriesId: String?
    var isBookmarkBusy = false
    var isPreferenceBusy = false
    var cloudResolvedIsRTL: Bool?
    var cloudResolvedFitMode: ComicPageDisplayMode?
    var cloudResolvedUpscaleMode: UpscaleMode?
    var cloudPreferenceRevision = 0

    private var activityTracker: ReadingActivityTracker?
    private var isReaderActive = true
    private var isSwitchingVolume = false
    private let api = APIClient.shared
    private var modelContext: ModelContext?
    @ObservationIgnored private var prefSaveTask: Task<Void, Never>?
    @ObservationIgnored private var cloudLoadTask: Task<Void, Never>?
    @ObservationIgnored private var bannerTask: Task<Void, Never>?

    init() {
        self.currentComicId = ""
    }

    var isCurrentPageBookmarked: Bool {
        bookmark(at: currentPage) != nil
    }

    var canUseSeriesScope: Bool {
        guard let seriesId else { return false }
        return !seriesId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func bookmark(at pageIndex: Int) -> UserBookmark? {
        bookmarks.first { $0.pageIndex == pageIndex }
    }

    func pagePositionRatio(for page: Int) -> Double {
        guard totalPages > 1 else { return 0 }
        let clamped = min(max(page, 0), totalPages - 1)
        return Double(clamped) / Double(totalPages - 1)
    }

    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }

    func load(comicId: String, initialPage: Int, groupContext: ReadingGroupContext? = nil) async {
        self.currentComicId = comicId
        self.groupContext = groupContext
        self.currentPage = initialPage
        self.bookmarks = []
        self.seriesId = nil

        cloudLoadTask?.cancel()
        cloudLoadTask = Task { [weak self] in
            await self?.loadCloudSyncData(for: comicId)
        }

        do {
            let pages = try await api.fetchPages(comicId: comicId)
            guard !Task.isCancelled else { return }
            totalPages = pages.totalPages
            currentPage = min(max(initialPage, 0), max(totalPages - 1, 0))
            isLoading = false
            startActivity()
        } catch {
            guard !Task.isCancelled else { return }
            AppLogger.log("fetchPages 失败: \(error.localizedDescription)")
            // 离线 fallback：从本地元数据读取页数
            if let meta = OfflineFileManager.shared.loadMeta(comicId: comicId), meta.pageCount > 0 {
                totalPages = meta.pageCount
                currentPage = min(max(initialPage, 0), totalPages - 1)
                AppLogger.log("离线 fallback 成功: \(comicId), \(meta.pageCount) 页")
                startActivity()
                if groupContext == nil {
                    Task { [weak self] in
                        guard let self, self.currentComicId == comicId, self.groupContext == nil else { return }
                        if let resolved = await self.api.resolveReadingGroupContext(
                            for: comicId,
                            libraryId: nil,
                            relativePath: nil
                        ),
                        self.currentComicId == comicId,
                        self.groupContext == nil {
                            self.groupContext = resolved.context
                            if self.seriesId == nil, let sid = resolved.seriesId {
                                self.seriesId = sid
                            }
                        }
                    }
                }
            } else {
                AppLogger.log("离线 fallback 失败: 无本地 meta, comicId=\(comicId)")
            }
            isLoading = false
        }
    }

    func loadVolume(
        comicId: String,
        initialPage: Int,
        markCurrentVolumeFinished: Bool = false
    ) async {
        guard !isSwitchingVolume else { return }
        isSwitchingVolume = true
        defer { isSwitchingVolume = false }

        let previousIndex = groupContext?.currentIndex
        if markCurrentVolumeFinished && totalPages > 0 {
            currentPage = totalPages - 1
        }

        await saveProgressAndWait()
        await endSessionAndWait()
        isLoading = true
        bannerTask?.cancel()
        volumeTransitionBanner = nil

        var transitionText: String?
        if let ctx = groupContext,
           let newIdx = ctx.volumeIds.firstIndex(of: comicId) {
            groupContext = ReadingGroupContext(
                groupId: ctx.groupId,
                volumeIds: ctx.volumeIds,
                currentIndex: newIdx
            )
            if let previousIndex {
                if newIdx > previousIndex {
                    transitionText = "已进入下一卷（卷 \(newIdx + 1)/\(ctx.volumeIds.count)）"
                } else if newIdx < previousIndex {
                    transitionText = "已返回上一卷（卷 \(newIdx + 1)/\(ctx.volumeIds.count)）"
                }
            }
        }

        currentComicId = comicId
        currentPage = initialPage
        totalPages = 0
        bookmarks = []
        seriesId = nil

        cloudLoadTask?.cancel()
        cloudLoadTask = Task { [weak self] in
            await self?.loadCloudSyncData(for: comicId)
        }

        do {
            let pages = try await api.fetchPages(comicId: comicId)
            guard !Task.isCancelled else { return }
            totalPages = pages.totalPages
            currentPage = min(max(initialPage, 0), max(totalPages - 1, 0))
            isLoading = false
            startActivity()
            saveProgress()
        } catch {
            AppLogger.error("加载卷失败: \(error)")
            // 离线 fallback：从本地元数据读取页数
            if let meta = OfflineFileManager.shared.loadMeta(comicId: comicId), meta.pageCount > 0 {
                totalPages = meta.pageCount
                currentPage = min(max(initialPage, 0), max(totalPages - 1, 0))
                AppLogger.log("离线模式：使用本地元数据，共 \(meta.pageCount) 页")
                startActivity()
                saveProgress()
            }
            isLoading = false
        }

        if let transitionText, totalPages > 0 {
            showVolumeTransitionBanner(transitionText)
        }
    }

    private func showVolumeTransitionBanner(_ message: String) {
        bannerTask?.cancel()
        volumeTransitionBanner = message
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1800))
            guard !Task.isCancelled else { return }
            self?.volumeTransitionBanner = nil
        }
    }

    func onPageChanged(_ page: Int) {
        currentPage = page
        saveProgress()
    }

    func onPageLoaded(comicId: String, page: Int) {
        guard comicId == currentComicId, page == currentPage else { return }
        activityTracker?.pageDidLoad(page)
    }

    func onSliderChanged(_ page: Int) {
        guard totalPages > 0 else { return }
        let target = min(max(page, 0), totalPages - 1)
        guard target != currentPage else { return }
        currentPage = target
        saveProgress()
    }

    func saveProgress() {
        let page = currentPage
        let comicId = currentComicId
        let resolvedTotalPages = totalPages
        let ratio = pagePositionRatio(for: page)
        activityTracker?.updatePage(
            page: page,
            totalPages: resolvedTotalPages,
            positionRatio: ratio
        )
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
        activityTracker?.updatePage(
            page: currentPage,
            totalPages: totalPages,
            positionRatio: pagePositionRatio(for: currentPage)
        )
        updateCachedProgress(comicId: currentComicId, page: currentPage)
        await flushActivity(totalPages: totalPages, finalize: false)
    }

    func endSessionAndWait() async {
        activityTracker?.updatePage(
            page: currentPage,
            totalPages: totalPages,
            positionRatio: pagePositionRatio(for: currentPage)
        )
        updateCachedProgress(comicId: currentComicId, page: currentPage)
        await flushActivity(totalPages: totalPages, finalize: true)
        activityTracker = nil
    }

    func pauseActivity() {
        isReaderActive = false
        activityTracker?.setActive(false)
    }

    func resumeActivity() {
        isReaderActive = true
        activityTracker?.setActive(true)
    }

    private func startActivity() {
        guard totalPages > 0, !currentComicId.isEmpty else { return }
        activityTracker = ReadingActivityTracker(comicId: currentComicId)
        activityTracker?.start(
            page: currentPage,
            totalPages: totalPages,
            positionRatio: pagePositionRatio(for: currentPage),
            preheatPages: true,
            isActive: isReaderActive
        )
    }

    private func flushActivity(totalPages: Int, finalize: Bool) async {
        guard totalPages > 0 else { return }
        do {
            try await activityTracker?.flush(finalize: finalize)
        } catch {
            AppLogger.log("阅读活动上报失败，已暂存待补传: \(error.localizedDescription)")
        }
    }

    // MARK: - 云端书签（Phase 2）

    func loadCloudBookmarks() async {
        guard !currentComicId.isEmpty, api.isNetworkReachable, !api.isOfflineMode else { return }
        let targetId = currentComicId
        do {
            let list = try await api.fetchBookmarks(comicId: targetId)
            guard targetId == currentComicId else { return }
            bookmarks = list.sorted { $0.pageIndex < $1.pageIndex }
        } catch {
            AppLogger.log("加载漫画书签失败: \(error.localizedDescription)")
        }
    }

    func toggleCurrentPageBookmark() async {
        await toggleBookmark(at: currentPage)
    }

    func toggleBookmark(at pageIndex: Int) async {
        guard !currentComicId.isEmpty, !isBookmarkBusy,
              api.isNetworkReachable, !api.isOfflineMode else { return }
        isBookmarkBusy = true
        defer { isBookmarkBusy = false }

        if let existing = bookmark(at: pageIndex) {
            do {
                try await api.deleteBookmark(comicId: currentComicId, bookmarkId: existing.id)
                bookmarks.removeAll { $0.id == existing.id }
            } catch {
                AppLogger.error("删除书签失败: \(error.localizedDescription)")
            }
        } else {
            do {
                let ratio = pagePositionRatio(for: pageIndex)
                let created = try await api.upsertBookmark(
                    comicId: currentComicId,
                    pageIndex: pageIndex,
                    positionRatio: ratio,
                    chapterTitle: "",
                    name: "第 \(pageIndex + 1) 页",
                    note: ""
                )
                bookmarks.removeAll { $0.id == created.id || $0.pageIndex == created.pageIndex }
                bookmarks.append(created)
                bookmarks.sort { $0.pageIndex < $1.pageIndex }
            } catch {
                AppLogger.error("添加书签失败: \(error.localizedDescription)")
            }
        }
    }

    func updateBookmark(_ bookmark: UserBookmark, name: String, note: String) async {
        guard !currentComicId.isEmpty, api.isNetworkReachable, !api.isOfflineMode else { return }
        do {
            let updated = try await api.updateBookmark(
                comicId: currentComicId,
                bookmarkId: bookmark.id,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                note: note.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            if let index = bookmarks.firstIndex(where: { $0.id == updated.id }) {
                bookmarks[index] = updated
            }
        } catch {
            AppLogger.error("更新书签失败: \(error.localizedDescription)")
        }
    }

    func deleteBookmark(_ bookmark: UserBookmark) async {
        guard !currentComicId.isEmpty, api.isNetworkReachable, !api.isOfflineMode else { return }
        do {
            try await api.deleteBookmark(comicId: currentComicId, bookmarkId: bookmark.id)
            bookmarks.removeAll { $0.id == bookmark.id }
        } catch {
            AppLogger.error("删除书签失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 云端阅读偏好（Phase 2）

    private func loadCloudSyncData(for targetComicId: String) async {
        if !api.isNetworkReachable || api.isOfflineMode {
            if groupContext == nil,
               let resolved = await api.resolveReadingGroupContext(
                   for: targetComicId,
                   libraryId: nil,
                   relativePath: nil
               ),
               !Task.isCancelled,
               targetComicId == currentComicId {
                groupContext = resolved.context
                if seriesId == nil, let sid = resolved.seriesId {
                    seriesId = sid
                }
            }
            return
        }

        async let bookmarksTask: [UserBookmark]? = try? api.fetchBookmarks(comicId: targetComicId)
        async let comicTask: Comic? = try? api.fetchComic(id: targetComicId)

        let loadedBookmarks = await bookmarksTask
        let loadedComic = await comicTask
        guard !Task.isCancelled, targetComicId == currentComicId else { return }

        if let loadedBookmarks {
            bookmarks = loadedBookmarks.sorted { $0.pageIndex < $1.pageIndex }
        }

        let detectedSeriesId = loadedComic?.seriesId
        if let detectedSeriesId, !detectedSeriesId.isEmpty {
            seriesId = detectedSeriesId
        }

        if groupContext == nil,
           let resolved = await api.resolveReadingGroupContext(
               for: targetComicId,
               libraryId: loadedComic?.libraryId,
               relativePath: loadedComic?.relativePath ?? loadedComic?.fileLocation?.relativePath
           ),
           !Task.isCancelled,
           targetComicId == currentComicId {
            groupContext = resolved.context
            if seriesId == nil, let sid = resolved.seriesId {
                seriesId = sid
            }
        }

        await refreshCloudPreferences(for: targetComicId, seriesId: seriesId)
    }

    func refreshCloudPreferences(for targetComicId: String? = nil, seriesId: String? = nil) async {
        let comicId = targetComicId ?? currentComicId
        guard !comicId.isEmpty, api.isNetworkReachable, !api.isOfflineMode else { return }
        do {
            let prefs = try await api.fetchReaderPreferences(
                comicId: comicId,
                seriesId: seriesId ?? self.seriesId
            )
            guard !Task.isCancelled, comicId == currentComicId else { return }
            applyFetchedPreferences(prefs)
        } catch {
            AppLogger.log("加载云端漫画偏好失败: \(error.localizedDescription)")
        }
    }

    private func applyFetchedPreferences(_ prefs: ScopedReaderPreferences) {
        scopedPreferences = prefs
        if prefs.comicOverride != nil {
            preferenceScope = .comic
        } else if prefs.seriesOverride != nil, canUseSeriesScope {
            preferenceScope = .series
        } else {
            preferenceScope = .global
        }

        let resolved = prefs.resolvedComic.isEmpty ? prefs.globalComic : prefs.resolvedComic
        if let dir = resolved["direction"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            if dir == "rtl" {
                cloudResolvedIsRTL = true
            } else if dir == "ltr" || dir == "ttb" {
                cloudResolvedIsRTL = false
            } else {
                cloudResolvedIsRTL = resolved["isRTL"]?.boolValue
            }
        } else {
            cloudResolvedIsRTL = resolved["isRTL"]?.boolValue
        }

        let fitRaw = (resolved["fitMode"]?.stringValue ?? resolved["pageDisplayMode"]?.stringValue)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch fitRaw {
        case "fit", "contain", "width":
            cloudResolvedFitMode = .fit
        case "fill", "cover", "height":
            cloudResolvedFitMode = .fill
        case "stretch":
            cloudResolvedFitMode = .stretch
        default:
            cloudResolvedFitMode = nil
        }

        if let upscaleRaw = resolved["upscaleMode"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if let exact = UpscaleMode(rawValue: upscaleRaw) {
                cloudResolvedUpscaleMode = exact
            } else {
                switch upscaleRaw.lowercased() {
                case "off": cloudResolvedUpscaleMode = .off
                case "x4", "anime4k": cloudResolvedUpscaleMode = .x4
                case "realesrgan": cloudResolvedUpscaleMode = .realesrganAnime4x
                default: cloudResolvedUpscaleMode = nil
                }
            }
        } else {
            cloudResolvedUpscaleMode = nil
        }

        cloudPreferenceRevision += 1
    }

    func scheduleSaveCloudPreferences(
        isRTL: Bool,
        pageDisplayMode: ComicPageDisplayMode,
        upscaleMode: UpscaleMode
    ) {
        guard !currentComicId.isEmpty, api.isNetworkReachable, !api.isOfflineMode else { return }
        prefSaveTask?.cancel()
        let scopeToSave = preferenceScope
        let comicId = currentComicId
        let activeSeriesId = seriesId
        prefSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            await self.saveCloudPreferencesNow(
                scope: scopeToSave,
                comicId: comicId,
                seriesId: activeSeriesId,
                isRTL: isRTL,
                pageDisplayMode: pageDisplayMode,
                upscaleMode: upscaleMode
            )
        }
    }

    func switchPreferenceScope(
        _ newScope: ComicPreferenceScope,
        isRTL: Bool,
        pageDisplayMode: ComicPageDisplayMode,
        upscaleMode: UpscaleMode
    ) async {
        guard !currentComicId.isEmpty, newScope != preferenceScope else { return }
        prefSaveTask?.cancel()
        let previousScope = preferenceScope
        preferenceScope = newScope

        guard api.isNetworkReachable, !api.isOfflineMode else { return }
        isPreferenceBusy = true
        defer { isPreferenceBusy = false }

        if newScope == .global {
            // 切回全局默认时移除当前作品/系列覆盖，使全局配置重新生效
            if previousScope == .comic || scopedPreferences?.comicOverride != nil {
                try? await api.deleteReaderPreference(scope: "comic:\(currentComicId)")
            }
            if previousScope == .series, let seriesId, !seriesId.isEmpty {
                try? await api.deleteReaderPreference(scope: "series:\(seriesId)")
            }
            await refreshCloudPreferences(for: currentComicId, seriesId: seriesId)
            return
        }

        await saveCloudPreferencesNow(
            scope: newScope,
            comicId: currentComicId,
            seriesId: seriesId,
            isRTL: isRTL,
            pageDisplayMode: pageDisplayMode,
            upscaleMode: upscaleMode
        )
        await refreshCloudPreferences(for: currentComicId, seriesId: seriesId)
    }

    func resetCurrentComicOverride() async {
        guard !currentComicId.isEmpty, api.isNetworkReachable, !api.isOfflineMode else { return }
        isPreferenceBusy = true
        defer { isPreferenceBusy = false }
        do {
            try await api.deleteReaderPreference(scope: "comic:\(currentComicId)")
            await refreshCloudPreferences(for: currentComicId, seriesId: seriesId)
        } catch {
            AppLogger.error("清除作品偏好覆盖失败: \(error.localizedDescription)")
        }
    }

    private func saveCloudPreferencesNow(
        scope: ComicPreferenceScope,
        comicId: String,
        seriesId: String?,
        isRTL: Bool,
        pageDisplayMode: ComicPageDisplayMode,
        upscaleMode: UpscaleMode
    ) async {
        guard let scopeKey = scopeString(for: scope, comicId: comicId, seriesId: seriesId) else {
            return
        }
        var payload: [String: ReaderPreferenceValue] = scope == .global
            ? (scopedPreferences?.globalComic ?? [:])
            : [:]
        payload["direction"] = .string(isRTL ? "rtl" : "ltr")
        payload["fitMode"] = .string(pageDisplayMode.rawValue)
        if scope == .global {
            payload["isRTL"] = .bool(isRTL)
            payload["pageDisplayMode"] = .string(pageDisplayMode.rawValue)
            payload["upscaleMode"] = .string(upscaleMode.rawValue)
        }
        do {
            try await api.saveReaderPreference(scope: scopeKey, prefs: payload)
        } catch {
            AppLogger.log("保存云端阅读偏好失败 (\(scopeKey)): \(error.localizedDescription)")
        }
    }

    private func scopeString(
        for scope: ComicPreferenceScope,
        comicId: String,
        seriesId: String?
    ) -> String? {
        switch scope {
        case .global:
            return "global_comic"
        case .comic:
            return comicId.isEmpty ? nil : "comic:\(comicId)"
        case .series:
            guard let seriesId, !seriesId.isEmpty else { return nil }
            return "series:\(seriesId)"
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
    private var positionRatio: Double?
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
    private let warmupSession = ReaderWarmupSession(client: APIClient.shared)

    init(comicId: String) {
        self.comicId = comicId
        self.clientSessionId = "ios-\(UUID().uuidString)"
    }

    func start(
        page: Int,
        totalPages: Int,
        positionRatio: Double? = nil,
        trackProgress: Bool = true,
        preheatPages: Bool = false,
        isActive: Bool = true
    ) {
        guard !isStarted, totalPages > 0 else { return }
        isStarted = true
        self.page = page
        self.totalPages = totalPages
        self.positionRatio = positionRatio.map { min(max($0, 0.0), 1.0) }
        self.trackProgress = trackProgress
        self.isActive = isActive
        warmupSession.start(
            comicId: comicId,
            page: page,
            totalPages: totalPages,
            preheatPages: preheatPages,
            isActive: isActive
        )

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

    func updatePage(
        page: Int,
        totalPages: Int,
        positionRatio: Double? = nil,
        trackProgress: Bool = true
    ) {
        guard isStarted, !isFinalized else { return }
        self.page = page
        if totalPages > 0 { self.totalPages = totalPages }
        if let positionRatio {
            self.positionRatio = min(max(positionRatio, 0.0), 1.0)
        }
        self.trackProgress = trackProgress

        warmupSession.updatePage(page, totalPages: self.totalPages)

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
        warmupSession.setActive(active)
        if !active {
            Task { try? await flush(finalize: false) }
        }
    }

    func pageDidLoad(_ page: Int) {
        guard isStarted, !isFinalized else { return }
        warmupSession.pageDidLoad(page)
    }

    func flush(finalize: Bool) async throws {
        if finalize { warmupSession.stop() }
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
            positionRatio: positionRatio,
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
                positionRatio: activity.positionRatio,
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
        warmupSession.stop()
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
