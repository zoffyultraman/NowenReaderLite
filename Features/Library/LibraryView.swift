import SwiftUI
import SwiftData

// MARK: - 漫画卡片

struct ComicCardView: View {
    let id: String
    let title: String
    let isFavorite: Bool
    let isNovel: Bool
    let progress: Int
    let serverURL: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 封面
            ZStack(alignment: .topTrailing) {
                AuthenticatedImage(serverURL: serverURL, comicId: id, thumbnail: true)
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(.gray.opacity(0.15), lineWidth: 0.5)
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

                // 进度条
                if progress > 0 {
                    VStack {
                        Spacer()
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Rectangle()
                                    .fill(.black.opacity(0.3))
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
        }
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

    var body: some View {
        HStack(spacing: 12) {
            AuthenticatedImage(serverURL: serverURL, comicId: id, thumbnail: true)
                .aspectRatio(contentMode: .fill)
                .frame(width: 56, height: 80)
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
    var groupedComicIds: Set<String> = []
    var isLoading = false
    var hasMore = true
    var errorMessage: String?
    var displayItems: [LibraryItem] = []

    private var currentPage = 1
    private var sortBy = "addedAt"
    private var sortOrder = "desc"
    private var contentType: String?
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
            group.addTask { await self.loadComics(refresh: refresh) }
            group.addTask { await self.loadGroupMap() }
        }
        // 如果已被更新的 loadAll 取代，不覆盖状态
        guard version == loadVersion else { return }
        isLoading = false
        updateDisplayItems()
    }

    func updateDisplayItems() {
        if contentType == "comic" {
            // 合集和散本统一混合排序
            var allItems: [LibraryItem] = []
            allItems.append(contentsOf: groups.map { .group($0) })
            let ungrouped = comics.filter { !groupedComicIds.contains($0.id) }
            allItems.append(contentsOf: ungrouped.map { .comic($0) })

            // 统一排序
            allItems.sort { lhs, rhs in
                compareLibraryItems(lhs, rhs, sortBy: sortBy, sortOrder: sortOrder)
            }
            displayItems = allItems
        } else {
            displayItems = comics.map { .comic($0) }
        }
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
        case .comic(let c): return c.title
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
                sortBy: sortBy,
                sortOrder: sortOrder,
                contentType: contentType
            )
            if refresh || currentPage == 1 {
                comics = resp.comics
            } else {
                comics.append(contentsOf: resp.comics)
            }
            hasMore = currentPage < resp.totalPages

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
        for comic in comics {
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
        guard contentType == "comic" else { groups = []; return }
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
            groups = try await api.fetchGroups(contentType: contentType)
        } catch {
            AppLogger.error("加载合集失败: \(error)")
            groups = []
        }
    }

    func loadGroupMap() async {
        guard contentType == "comic" else { groupedComicIds = []; return }
        guard !api.isOfflineMode, api.isNetworkReachable else {
            // 离线：从本地合集数据重建 groupedComicIds
            let local = OfflineFileManager.shared.loadGroups()
            let downloadedIds = Set(OfflineFileManager.shared.downloadedComicIds)
            var ids = Set<String>()
            for g in local {
                for comicId in g.comicIds where downloadedIds.contains(comicId) {
                    ids.insert(comicId)
                }
            }
            groupedComicIds = ids
            return
        }
        do {
            groupedComicIds = try await api.fetchComicGroupMap()
        } catch {
            AppLogger.error("加载分组映射失败: \(error)")
            groupedComicIds = []
        }
    }

    func loadMore() async {
        guard hasMore, !isLoading else { return }
        currentPage += 1
        await loadComics()
        updateDisplayItems()
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

