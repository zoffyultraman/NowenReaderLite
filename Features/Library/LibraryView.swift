import SwiftUI
import SwiftData

// MARK: - 阅读状态

enum ReadingStatus {
    static func label(for status: String) -> String {
        switch status {
        case "want": return "想看"
        case "reading": return "在读"
        case "finished": return "已读"
        case "shelved": return "搁置"
        default: return status
        }
    }

    static func color(for status: String) -> Color {
        switch status {
        case "want": return .orange
        case "reading": return .green
        case "finished": return .blue
        case "shelved": return .gray
        default: return .gray
        }
    }
}

// MARK: - 漫画卡片

struct ComicCardView: View {
    let id: String
    let title: String
    let isFavorite: Bool
    let isNovel: Bool
    let progress: Int
    let serverURL: String
    let readingStatus: String?
    let rating: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 封面 3:4 比例
            ZStack(alignment: .topTrailing) {
                AuthenticatedImage(serverURL: serverURL, comicId: id, thumbnail: true)
                    .aspectRatio(3/4, contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(.gray.opacity(0.12), lineWidth: 0.5)
                    )

                // 收藏标记
                if isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .padding(6)
                        .background(.ultraThinMaterial, in: Circle())
                        .padding(6)
                }

                // 小说标记
                if isNovel {
                    Text("小说")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }

                // 底部叠加层：阅读状态标记 + 进度条
                VStack(spacing: 2) {
                    // 阅读状态标记
                    if let status = readingStatus, !status.isEmpty {
                        HStack {
                            HStack(spacing: 3) {
                                Circle()
                                    .fill(ReadingStatus.color(for: status))
                                    .frame(width: 6, height: 6)
                                Text(ReadingStatus.label(for: status))
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.6))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .padding(.leading, 6)
                            Spacer()
                        }
                    }

                    // 进度条
                    if progress > 0 {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Rectangle()
                                    .fill(.black.opacity(0.2))
                                Rectangle()
                                    .fill(Color.accentColor)
                                    .frame(width: geo.size.width * CGFloat(progress) / 100)
                            }
                        }
                        .frame(height: 3)
                        .clipShape(RoundedRectangle(cornerRadius: 1.5))
                    }
                }
            }

            // 标题
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .padding(.top, 8)

            // 评分
            if let rating, rating > 0 {
                HStack(spacing: 1) {
                    ForEach(1...5, id: \.self) { i in
                        Image(systemName: i <= Int(rating) ? "star.fill" : "star")
                            .font(.system(size: 8))
                            .foregroundStyle(.yellow)
                    }
                }
                .padding(.top, 2)
            }
        }
        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
    }
}

// MARK: - 列表行

struct ComicListRowView: View {
    let id: String
    let title: String
    let author: String?
    let pageCount: Int
    let fileSize: Int64?
    let progress: Int
    let isFavorite: Bool
    let serverURL: String
    let readingStatus: String?
    let rating: Double?

    var body: some View {
        HStack(spacing: 12) {
            AuthenticatedImage(serverURL: serverURL, comicId: id, thumbnail: true)
                .aspectRatio(contentMode: .fill)
                .frame(width: 56, height: 75)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let author, !author.isEmpty {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let rating, rating > 0 {
                    HStack(spacing: 1) {
                        ForEach(1...5, id: \.self) { i in
                            Image(systemName: i <= Int(rating) ? "star.fill" : "star")
                                .font(.system(size: 9))
                                .foregroundStyle(.yellow)
                        }
                    }
                }

                if let status = readingStatus, !status.isEmpty {
                    Text(ReadingStatus.label(for: status))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(ReadingStatus.color(for: status))
                }

                if pageCount > 0 {
                    let sizeText = fileSize.map { formatFileSize($0) } ?? ""
                    Text("\(pageCount) 页 · \(progress)% 已读\(sizeText.isEmpty ? "" : " · \(sizeText)")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if isFavorite {
                Image(systemName: "heart.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - ViewModel

@MainActor
@Observable
final class LibraryViewModel {
    var comics: [Comic] = []
    var groups: [ComicGroup] = []
    var isLoading = false
    var hasMore = true
    var errorMessage: String?
    var displayItems: [LibraryItem] = []

    private var currentPage = 1
    private var sortBy = "addedAt"
    private var sortOrder = "desc"
    private var contentType: String?
    private var groupedComicIds: Set<String> = []
    private let api = APIClient.shared
    private var modelContext: ModelContext?
    /// 当前加载任务版本号，旧任务完成时忽略（避免离线切换时旧请求挂起覆盖状态）
    private var loadVersion: Int = 0

    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }

    /// 同时加载合集、漫画列表和分组映射
    func loadAll(refresh: Bool = false) async {
        // 离线 + 已有数据 + 非手动刷新 → 跳过（避免切 tab 时清空 groups 再重载）
        if api.isOfflineMode && !comics.isEmpty && !refresh {
            return
        }
        loadVersion += 1
        let version = loadVersion
        // 离线 + 有数据时不要显示加载动画
        if !(api.isOfflineMode && !comics.isEmpty) {
            isLoading = true
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadGroups() }
            group.addTask { await self.loadGroupedComicMap() }
            group.addTask { await self.loadComics(refresh: refresh) }
        }
        // 如果已被更新的 loadAll 取代，不覆盖状态
        guard version == loadVersion else { return }
        isLoading = false
        updateDisplayItems()
    }

    func updateDisplayItems() {
        // 合集和散本统一混合排序；目录作品需要先由服务端折叠，再本地排除旧合集内的真实作品。
        var allItems: [LibraryItem] = []
        allItems.append(contentsOf: groups.map { .group($0) })
        let looseComics = comics.filter { comic in
            comic.isSeriesShelfItem || groupedComicIds.isEmpty || !groupedComicIds.contains(comic.id)
        }
        allItems.append(contentsOf: looseComics.map { .comic($0) })

        // 统一排序
        allItems.sort { lhs, rhs in
            compareLibraryItems(lhs, rhs, sortBy: sortBy, sortOrder: sortOrder)
        }
        displayItems = allItems
    }

    // MARK: - 统一排序比较

    /// 合集与散本统一排序比较
    private func compareLibraryItems(_ lhs: LibraryItem, _ rhs: LibraryItem, sortBy: String, sortOrder: String) -> Bool {
        let ascending = sortOrder == "asc"

        switch sortBy {
        case "title":
            let lt = itemTitle(lhs)
            let rt = itemTitle(rhs)
            if lt == rt { return sortOrderValue(lhs) < sortOrderValue(rhs) }
            return ascending ? (lt < rt) : (lt > rt)

        case "lastReadAt":
            let ld = itemLastReadDate(lhs)
            let rd = itemLastReadDate(rhs)
            // 无日期的排在最后
            switch (ld, rd) {
            case (nil, nil): return sortOrderValue(lhs) < sortOrderValue(rhs)
            case (nil, _): return false
            case (_, nil): return true
            case let (l?, r?):
                if l == r { return sortOrderValue(lhs) < sortOrderValue(rhs) }
                return ascending ? (l < r) : (l > r)
            }

        case "rating":
            let lr = itemRating(lhs)
            let rr = itemRating(rhs)
            // 无评分的排在最后
            switch (lr, rr) {
            case (nil, nil): return sortOrderValue(lhs) < sortOrderValue(rhs)
            case (nil, _): return false
            case (_, nil): return true
            case let (l?, r?):
                if l == r { return sortOrderValue(lhs) < sortOrderValue(rhs) }
                return ascending ? (l < r) : (l > r)
            }

        case "readTime":
            let lt = itemReadTime(lhs)
            let rt = itemReadTime(rhs)
            if lt == rt { return sortOrderValue(lhs) < sortOrderValue(rhs) }
            return ascending ? (lt < rt) : (lt > rt)

        default: // addedAt — 使用 sortOrder 作为排序依据
            let ls = sortOrderValue(lhs)
            let rs = sortOrderValue(rhs)
            return ascending ? (ls < rs) : (ls > rs)
        }
    }

    private func itemTitle(_ item: LibraryItem) -> String {
        switch item {
        case .comic(let c): return c.sortTitle
        case .group(let g): return g.name
        }
    }

    private func itemLastReadDate(_ item: LibraryItem) -> Date? {
        switch item {
        case .comic(let c): return c.lastReadAt.flatMap { Date.fromISO8601($0) }
        case .group: return nil
        }
    }

    private func itemRating(_ item: LibraryItem) -> Double? {
        switch item {
        case .comic(let c): return c.rating
        case .group: return nil
        }
    }

    private func itemReadTime(_ item: LibraryItem) -> Int {
        switch item {
        case .comic(let c): return c.totalReadTime ?? 0
        case .group: return 0
        }
    }

    private func sortOrderValue(_ item: LibraryItem) -> Int {
        switch item {
        case .comic(let c): return c.sortOrder ?? Int.max
        case .group(let g): return g.sortOrder ?? Int.max
        }
    }

    func loadComics(refresh: Bool = false) async {
        if refresh { currentPage = 1 }
        let useSeriesView = contentType != "novel"
        if useSeriesView { currentPage = 1 }

        // 离线模式或网络不可达：直接从缓存加载已下载漫画（不等 API 超时）
        if APIClient.shared.isOfflineMode || !APIClient.shared.isNetworkReachable {
            if let context = modelContext {
                let cached = loadFromCache(context: context)
                let downloadedIds = Set(OfflineFileManager.shared.downloadedComicIds)
                comics = cached.filter { downloadedIds.contains($0.id) }
            }
            return
        }

        // 首次加载时先显示缓存数据
        if currentPage == 1, let context = modelContext {
            let cached = loadFromCache(context: context)
            if !cached.isEmpty && comics.isEmpty {
                comics = cached
            }
        }

        do {
            let resp = try await api.fetchComics(
                page: currentPage,
                pageSize: useSeriesView ? 0 : 20,
                sortBy: sortBy,
                sortOrder: sortOrder,
                contentType: contentType,
                excludeGrouped: useSeriesView ? nil : true,
                seriesView: useSeriesView
            )
            if refresh || currentPage == 1 {
                comics = resp.comics
            } else {
                comics.append(contentsOf: resp.comics)
            }
            hasMore = useSeriesView ? false : currentPage < resp.totalPages

            // 更新缓存
            if let context = modelContext, (refresh || currentPage == 1) {
                saveToCache(resp.comics, context: context)
            }
        } catch {
            AppLogger.log("网络不可用，从本地缓存加载书架")
            // API 失败：只显示已下载的漫画
            if let context = modelContext {
                let cached = loadFromCache(context: context)
                let downloadedIds = Set(OfflineFileManager.shared.downloadedComicIds)
                comics = cached.filter { downloadedIds.contains($0.id) }
            }
        }
    }

    private func loadFromCache(context: ModelContext) -> [Comic] {
        let descriptor = FetchDescriptor<CachedComic>(
            sortBy: [SortDescriptor(\.lastReadAt, order: .reverse)]
        )
        return context.fetchOrLog(descriptor, label: "从缓存加载漫画").map { $0.toComic() }
    }

    private func saveToCache(_ comics: [Comic], context: ModelContext) {
        for comic in comics where !comic.isSeriesShelfItem {
            let id = comic.id
            let descriptor = FetchDescriptor<CachedComic>(predicate: #Predicate { $0.id == id })
            if let first = context.fetchOrLog(descriptor, label: "更新缓存漫画").first {
                // 更新已有记录
                first.title = comic.title
                first.author = comic.author
                first.coverUrl = comic.coverUrl
                first.pageCount = comic.pageCount
                first.lastReadPage = comic.lastReadPage
                first.isFavorite = comic.isFavorite
                first.rating = comic.rating
                first.type = comic.type
                first.progress = comic.progress
                first.lastReadAt = comic.lastReadAt.flatMap { Date.fromISO8601($0) }
                first.cachedAt = Date()
            } else {
                // 插入新记录
                context.insert(CachedComic.from(comic))
            }
        }
        context.saveOrLog()
    }

    func loadGroups() async {
        guard !api.isOfflineMode, api.isNetworkReachable else {
            // 离线：从本地加载已保存的合集，只显示有已下载漫画的合集
            let local = OfflineFileManager.shared.loadGroups()
            let downloadedIds = Set(OfflineFileManager.shared.downloadedComicIds)
            groups = local.compactMap { g in
                let hasDownloaded = g.comicIds.contains { downloadedIds.contains($0) }
                guard hasDownloaded else { return nil }
                return ComicGroup(
                    id: g.id, name: g.name, coverUrl: g.coverUrl,
                    author: g.author, description: g.description,
                    comicCount: g.comicCount, sortOrder: g.sortOrder,
                    firstComicId: g.comicIds.first
                )
            }
            return
        }
        do {
            if contentType == nil {
                // "全部"模式：分别加载漫画和小说合集，合并去重
                async let comicGroups = api.fetchGroups(contentType: "comic")
                async let novelGroups = api.fetchGroups(contentType: "novel")
                let allGroups = try await comicGroups + novelGroups
                var seen = Set<Int>()
                groups = allGroups.filter { seen.insert($0.id).inserted }
            } else {
                groups = try await api.fetchGroups(contentType: contentType)
            }
        } catch {
            AppLogger.error("加载合集失败: \(error)")
            groups = []
        }
    }

    func loadGroupedComicMap() async {
        guard !api.isOfflineMode, api.isNetworkReachable else {
            let local = OfflineFileManager.shared.loadGroups()
            groupedComicIds = Set(local.flatMap { $0.comicIds })
            return
        }
        do {
            groupedComicIds = try await api.fetchComicGroupMap()
        } catch {
            AppLogger.error("加载合集映射失败: \(error)")
            groupedComicIds = []
        }
    }

    func loadMore() async {
        guard hasMore, !isLoading else { return }
        isLoading = true
        currentPage += 1
        await loadComics()
        updateDisplayItems()
        isLoading = false
    }

    func updateSort(by: String, order: String) {
        sortBy = by
        sortOrder = order
        Task {
            await loadComics(refresh: true)
            updateDisplayItems()
        }
    }

    func setContentType(_ type: String?) {
        contentType = type
        Task { await loadAll(refresh: true) }
    }
}
