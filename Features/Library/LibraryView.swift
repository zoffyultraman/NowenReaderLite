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

    static func effectiveStatus(explicit status: String?, progress: Int) -> String? {
        if let status, !status.isEmpty {
            return status
        }
        if progress >= 100 {
            return "finished"
        }
        return progress > 0 ? "reading" : nil
    }

    static func progressLabel(progress: Int, status: String?) -> String {
        let effective = effectiveStatus(explicit: status, progress: progress)
        if effective == "finished" {
            return "\(progress)% · 已读"
        }
        if progress > 0 {
            return "\(progress)% · 在读"
        }
        return "未读"
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

    private var displayStatus: String? {
        ReadingStatus.effectiveStatus(explicit: readingStatus, progress: progress)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            AuthenticatedImage(serverURL: serverURL, comicId: id, thumbnail: true)
                .aspectRatio(3/4, contentMode: .fill)

            VStack(alignment: .leading, spacing: 4) {
                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 4) {
                        if let status = displayStatus {
                            Circle()
                                .fill(ReadingStatus.color(for: status))
                                .frame(width: 6, height: 6)
                            Text(ReadingStatus.label(for: status))
                        } else {
                            Text("未读")
                        }

                        Spacer(minLength: 2)

                        if progress > 0 {
                            Text("\(progress)%")
                                .monospacedDigit()
                        }
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))

                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.2))
                            Capsule()
                                .fill(Color.accentColor)
                                .frame(
                                    width: geometry.size.width
                                        * CGFloat(min(max(progress, 0), 100))
                                        / 100
                                )
                        }
                    }
                    .frame(height: 3)
                    .opacity(progress > 0 ? 1 : 0)
                }
                .padding(8)
                .background(.black.opacity(0.68))
            }

            Text(isNovel ? "小说" : "漫画")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(isNovel ? Color.blue.opacity(0.9) : Color.green.opacity(0.9))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if isFavorite {
                Image(systemName: "heart.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(6)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .aspectRatio(3/4, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(.separator).opacity(0.35), lineWidth: 0.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(
            ReadingStatus.progressLabel(progress: progress, status: readingStatus)
        )
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

                if let status = ReadingStatus.effectiveStatus(
                    explicit: readingStatus,
                    progress: progress
                ) {
                    Text(ReadingStatus.label(for: status))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(ReadingStatus.color(for: status))
                }

                if pageCount > 0 {
                    let sizeText = fileSize.map { formatFileSize($0) } ?? ""
                    Text(
                        "\(pageCount) 页 · \(ReadingStatus.progressLabel(progress: progress, status: readingStatus))"
                            + (sizeText.isEmpty ? "" : " · \(sizeText)")
                    )
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

    /// 加载普通书架作品；合集条目由 CollectionViewModel 合并展示。
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
        _ = await loadComics(refresh: refresh, version: version)
        // 如果已被更新的 loadAll 取代，不覆盖状态
        guard version == loadVersion else { return }
        isLoading = false
    }

    private func loadComics(refresh: Bool = false, version: Int) async -> Bool {
        guard version == loadVersion else { return false }
        if refresh { currentPage = 1 }
        let useSeriesView = contentType != "novel"
        if useSeriesView { currentPage = 1 }

        // 离线模式或网络不可达：直接从缓存加载已下载漫画（不等 API 超时）
        if APIClient.shared.isOfflineMode || !APIClient.shared.isNetworkReachable {
            let downloadedIds = await visibleOfflineShelfIds()
            guard !Task.isCancelled, version == loadVersion else { return false }
            if let context = modelContext {
                let cached = loadFromCache(context: context)
                comics = cached.filter { downloadedIds.contains($0.id) && matchesContentType($0) }
            }
            hasMore = false
            return true
        }

        do {
            let resp = try await api.fetchComics(
                page: currentPage,
                pageSize: useSeriesView ? 0 : 20,
                sortBy: sortBy,
                sortOrder: sortOrder,
                contentType: contentType,
                excludeGrouped: true,
                seriesView: useSeriesView
            )
            guard !Task.isCancelled, version == loadVersion else { return false }
            if refresh || currentPage == 1 {
                comics = resp.comics
            } else {
                comics.append(contentsOf: resp.comics)
            }
            hasMore = useSeriesView ? false : currentPage < resp.totalPages

            // 更新缓存
            if let context = modelContext {
                saveToCache(resp.comics, context: context)
            }
            return true
        } catch {
            guard !isCancellation(error), version == loadVersion else {
                return false
            }
            if currentPage == 1 {
                AppLogger.log("网络不可用，从本地缓存加载书架")
                let downloadedIds = await visibleOfflineShelfIds()
                guard !Task.isCancelled, version == loadVersion else {
                    return false
                }
                if let context = modelContext {
                    let cached = loadFromCache(context: context)
                    comics = cached.filter {
                        downloadedIds.contains($0.id) && matchesContentType($0)
                    }
                }
            } else {
                AppLogger.error("加载书架第 \(currentPage) 页失败: \(error)")
            }
            return false
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
        let existingComics = context.fetchOrLog(
            FetchDescriptor<CachedComic>(),
            label: "批量查询缓存漫画"
        )
        var existingById: [String: CachedComic] = [:]
        for cached in existingComics {
            existingById[cached.id] = cached
        }

        for comic in comics where !comic.isSeriesShelfItem {
            if let first = existingById[comic.id] {
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
                let cached = CachedComic.from(comic)
                context.insert(cached)
                existingById[comic.id] = cached
            }
        }
        context.saveOrLog()
    }

    func loadMore() async {
        guard hasMore, !isLoading else { return }
        loadVersion += 1
        let version = loadVersion
        isLoading = true
        let previousPage = currentPage
        currentPage += 1
        let succeeded = await loadComics(version: version)
        guard version == loadVersion else { return }
        if !succeeded {
            currentPage = previousPage
        }
        isLoading = false
    }

    func configure(contentType: String?, sortBy: String, sortOrder: String) async {
        self.contentType = contentType
        self.sortBy = sortBy
        self.sortOrder = sortOrder
        await loadAll(refresh: true)
    }

    private func isCancellation(_ error: Error) -> Bool {
        Task.isCancelled || (error as? URLError)?.code == .cancelled
    }

    private func visibleOfflineShelfIds() async -> Set<String> {
        await Task.detached(priority: .utility) {
            let downloadedIds = Set(
                OfflineFileManager.shared.completedDownloads().keys
            )
            let groupedIds = Set(
                OfflineFileManager.shared.loadGroups().flatMap(\.comicIds)
            )
            return downloadedIds.subtracting(groupedIds)
        }.value
    }
}

@MainActor
@Observable
final class CollectionViewModel {
    var groups: [ComicGroup] = []
    var groupedComicIds: Set<String> = []
    var groupedSeriesIds: Set<String> = []
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
        let membership: GroupMembershipSnapshot
        if api.isOfflineMode || !api.isNetworkReachable {
            let cachedTypes = cachedComicTypesById()
            loaded = await loadOfflineGroups(cachedTypes: cachedTypes)
            membership = .empty
        } else {
            guard let remote = await loadRemoteGroups() else {
                if version == loadVersion {
                    isLoading = false
                }
                return
            }
            loaded = remote.groups
            membership = remote.membership
        }

        guard !Task.isCancelled, version == loadVersion else { return }
        groups = sortedGroups(loaded)
        groupedComicIds = membership.comicIds
        groupedSeriesIds = membership.seriesIds
        isLoading = false
    }

    private func loadRemoteGroups() async -> RemoteGroupsSnapshot? {
        do {
            errorMessage = nil
            let loadedGroups: [ComicGroup]
            if contentType == nil {
                async let comicGroups = api.fetchGroups(contentType: "comic")
                async let novelGroups = api.fetchGroups(contentType: "novel")
                let allGroups = try await comicGroups + novelGroups
                var seen = Set<Int>()
                loadedGroups = allGroups.filter { seen.insert($0.id).inserted }
            } else {
                loadedGroups = try await api.fetchGroups(contentType: contentType)
            }
            let membership = await loadGroupMembership(for: loadedGroups)
            return RemoteGroupsSnapshot(groups: loadedGroups, membership: membership)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                return nil
            }
            AppLogger.error("加载合集失败: \(error)")
            errorMessage = error.localizedDescription
            return RemoteGroupsSnapshot(groups: [], membership: .empty)
        }
    }

    private func loadGroupMembership(for groups: [ComicGroup]) async -> GroupMembershipSnapshot {
        let selectedContentType = contentType
        return await withTaskGroup(of: GroupMembershipSnapshot.self) { taskGroup in
            for group in groups {
                taskGroup.addTask { [api] in
                    do {
                        let detail = try await api.fetchGroupDetail(
                            id: group.id,
                            contentType: selectedContentType
                        )
                        return GroupMembershipSnapshot(
                            comicIds: Set(
                                detail.comics.map(\.id)
                                    + detail.seriesList.flatMap { $0.comics.map(\.id) }
                            ),
                            seriesIds: Set(detail.seriesList.map(\.id))
                        )
                    } catch {
                        if !Task.isCancelled {
                            AppLogger.error("加载合集目录关系失败: \(error)")
                        }
                        return .empty
                    }
                }
            }

            var result = GroupMembershipSnapshot.empty
            for await membership in taskGroup {
                result.comicIds.formUnion(membership.comicIds)
                result.seriesIds.formUnion(membership.seriesIds)
            }
            return result
        }
    }

    private func loadOfflineGroups(
        cachedTypes: [String: String?]
    ) async -> [ComicGroup] {
        let snapshot = await Task.detached(priority: .utility) {
            OfflineGroupsLoadSnapshot(
                groups: OfflineFileManager.shared.loadGroups(),
                downloadedIds: Set(
                    OfflineFileManager.shared.completedDownloads().keys
                )
            )
        }.value

        return snapshot.groups.compactMap { group in
            let matchingIds = group.comicIds.filter { comicId in
                snapshot.downloadedIds.contains(comicId)
                    && matchesContentType(cachedTypes[comicId] ?? nil)
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

    private func cachedComicTypesById() -> [String: String?] {
        guard let modelContext else { return [:] }
        let cached = modelContext.fetchOrLog(FetchDescriptor<CachedComic>(), label: "离线加载合集缓存")
        var map: [String: String?] = [:]
        for comic in cached {
            map[comic.id] = comic.type
        }
        return map
    }

    private func matchesContentType(_ type: String?) -> Bool {
        guard let contentType else { return true }
        guard let type, !type.isEmpty else { return contentType == "comic" }
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

    func configure(contentType: String?, sortBy: String, sortOrder: String) async {
        self.contentType = contentType
        self.sortBy = sortBy
        self.sortOrder = sortOrder
        await load(refresh: true)
    }
}

private struct OfflineGroupsLoadSnapshot: Sendable {
    let groups: [OfflineGroupMeta]
    let downloadedIds: Set<String>
}

private struct RemoteGroupsSnapshot: Sendable {
    let groups: [ComicGroup]
    let membership: GroupMembershipSnapshot
}

private struct GroupMembershipSnapshot: Sendable {
    var comicIds: Set<String>
    var seriesIds: Set<String>

    static let empty = GroupMembershipSnapshot(comicIds: [], seriesIds: [])
}
