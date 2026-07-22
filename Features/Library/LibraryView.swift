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
    var isLoading = false
    var hasMore = true
    var errorMessage: String?

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

    /// 加载书库作品。合集已独立展示，不混入书库列表。
    func loadAll(refresh: Bool = false) async {
        // 离线 + 已有数据 + 非手动刷新 → 跳过（避免切 tab 时清空再重载）
        if api.isOfflineMode && !comics.isEmpty && !refresh {
            return
        }
        loadVersion += 1
        let version = loadVersion
        // 离线 + 有数据时不要显示加载动画
        if !(api.isOfflineMode && !comics.isEmpty) {
            isLoading = true
        }
        await loadComics(refresh: refresh)
        // 如果已被更新的 loadAll 取代，不覆盖状态
        guard version == loadVersion else { return }
        isLoading = false
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
                comics = cached.filter { downloadedIds.contains($0.id) && matchesContentType($0) }
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
                excludeGrouped: nil,
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
                comics = cached.filter { downloadedIds.contains($0.id) && matchesContentType($0) }
            }
        }
    }

    private func matchesContentType(_ comic: Comic) -> Bool {
        guard let contentType else { return true }
        guard let type = comic.type, !type.isEmpty else { return contentType == "comic" }
        return type == contentType
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

    func loadMore() async {
        guard hasMore, !isLoading else { return }
        isLoading = true
        currentPage += 1
        await loadComics()
        isLoading = false
    }

    func updateSort(by: String, order: String) {
        sortBy = by
        sortOrder = order
        Task {
            await loadComics(refresh: true)
        }
    }

    func setContentType(_ type: String?) {
        contentType = type
        Task { await loadAll(refresh: true) }
    }
}

@MainActor
@Observable
final class CollectionViewModel {
    var groups: [ComicGroup] = []
    var isLoading = false
    var errorMessage: String?

    private var sortBy = "defaultOrder"
    private var sortOrder = "asc"
    private var contentType: String?
    private let api = APIClient.shared
    private var modelContext: ModelContext?
    private var loadVersion = 0

    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }

    func load(refresh: Bool = false) async {
        if api.isOfflineMode && !groups.isEmpty && !refresh {
            return
        }
        loadVersion += 1
        let version = loadVersion
        if !(api.isOfflineMode && !groups.isEmpty) {
            isLoading = true
        }

        let loaded: [ComicGroup]
        if api.isOfflineMode || !api.isNetworkReachable {
            loaded = loadOfflineGroups()
        } else {
            loaded = await loadRemoteGroups()
        }

        guard version == loadVersion else { return }
        groups = sortedGroups(loaded)
        isLoading = false
    }

    private func loadRemoteGroups() async -> [ComicGroup] {
        do {
            errorMessage = nil
            if contentType == nil {
                async let comicGroups = api.fetchGroups(contentType: "comic")
                async let novelGroups = api.fetchGroups(contentType: "novel")
                let allGroups = try await comicGroups + novelGroups
                var seen = Set<Int>()
                return allGroups.filter { seen.insert($0.id).inserted }
            }
            return try await api.fetchGroups(contentType: contentType)
        } catch {
            AppLogger.error("加载合集失败: \(error)")
            errorMessage = error.localizedDescription
            return []
        }
    }

    private func loadOfflineGroups() -> [ComicGroup] {
        let local = OfflineFileManager.shared.loadGroups()
        let downloadedIds = Set(OfflineFileManager.shared.downloadedComicIds)
        let cachedMap = cachedComicsById()

        return local.compactMap { group in
            let matchingIds = group.comicIds.filter { comicId in
                downloadedIds.contains(comicId) && matchesContentType(cachedMap[comicId])
            }
            guard !matchingIds.isEmpty else { return nil }
            return ComicGroup(
                id: group.id,
                name: group.name,
                coverUrl: group.coverUrl,
                author: group.author,
                description: group.description,
                comicCount: contentType == nil ? group.comicCount : matchingIds.count,
                sortOrder: group.sortOrder,
                firstComicId: matchingIds.first,
                contentType: contentType
            )
        }
    }

    private func cachedComicsById() -> [String: CachedComic] {
        guard let modelContext else { return [:] }
        let cached = modelContext.fetchOrLog(FetchDescriptor<CachedComic>(), label: "离线加载合集缓存")
        var map: [String: CachedComic] = [:]
        for comic in cached {
            map[comic.id] = comic
        }
        return map
    }

    private func matchesContentType(_ cached: CachedComic?) -> Bool {
        guard let contentType else { return true }
        guard let type = cached?.type, !type.isEmpty else { return contentType == "comic" }
        return type == contentType
    }

    private func sortedGroups(_ groups: [ComicGroup]) -> [ComicGroup] {
        switch sortBy {
        case "title":
            return groups.sorted {
                let result = $0.name.localizedStandardCompare($1.name)
                if result == .orderedSame {
                    return ($0.sortOrder ?? Int.max) < ($1.sortOrder ?? Int.max)
                }
                return sortOrder == "asc" ? result == .orderedAscending : result == .orderedDescending
            }
        default:
            return groups.sorted {
                let left = $0.sortOrder ?? Int.max
                let right = $1.sortOrder ?? Int.max
                if left == right {
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                return left < right
            }
        }
    }

    func updateSort(by sortBy: String, order: String) {
        self.sortBy = sortBy
        self.sortOrder = order
        groups = sortedGroups(groups)
    }

    func setContentType(_ type: String?) {
        contentType = type
        Task { await load(refresh: true) }
    }
}
