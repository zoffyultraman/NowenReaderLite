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
    var formatBadge: String = ""

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

            HStack(spacing: 4) {
                Text(isNovel ? "小说" : "漫画")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(isNovel ? Color.blue.opacity(0.9) : Color.green.opacity(0.9))
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                if !formatBadge.isEmpty {
                    Text(formatBadge)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.72))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .lineLimit(1)
                }
            }
            .padding(.top, 6)
            .padding(.leading, 6)
            .padding(.trailing, isFavorite ? 32 : 6)
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
                .stroke(Color(uiColor: .separator).opacity(0.35), lineWidth: 0.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .bookCoverSource(id: "comic-\(id)")
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
    var formatBadge: String = ""

    var body: some View {
        HStack(spacing: 12) {
            AuthenticatedImage(serverURL: serverURL, comicId: id, thumbnail: true)
                .aspectRatio(contentMode: .fill)
                .frame(width: 56, height: 75)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .bookCoverSource(id: "comic-\(id)")

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if !formatBadge.isEmpty {
                        Text(formatBadge)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .fixedSize()
                    }
                }

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

// MARK: - 物理目录分类导航

struct LibraryDirectoryNavigationView: View {
    let currentPath: String
    let response: LibraryDirectoryListResponse?
    let isLoading: Bool
    let currentPage: Int
    let serverURL: String
    let onNavigate: (String) -> Void
    let onPageChange: (Int) -> Void

    private var breadcrumbs: [LibraryDirectoryBreadcrumb] {
        guard !currentPath.isEmpty else { return [] }
        if let response, response.parent == currentPath, !response.breadcrumbs.isEmpty {
            return response.breadcrumbs
        }
        let parts = currentPath.split(separator: "/").map(String.init)
        var result: [LibraryDirectoryBreadcrumb] = []
        for index in parts.indices {
            let path = parts[0...index].joined(separator: "/")
            result.append(LibraryDirectoryBreadcrumb(name: parts[index], path: path))
        }
        return result
    }

    private var nodes: [LibraryDirectoryNode] {
        response?.directories ?? []
    }

    private var totalPages: Int {
        max(response?.totalPages ?? 1, currentPage)
    }

    private var shouldShowContainer: Bool {
        !nodes.isEmpty || !currentPath.isEmpty || isLoading || currentPage > 1
    }

    var body: some View {
        if shouldShowContainer {
            VStack(alignment: .leading, spacing: 10) {
                LibraryDirectoryBreadcrumbBar(
                    currentPath: currentPath,
                    breadcrumbs: breadcrumbs,
                    onNavigate: onNavigate
                )

                if isLoading && nodes.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在加载目录分类…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                } else if !nodes.isEmpty {
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 8) {
                            ForEach(nodes) { node in
                                LibraryDirectoryNodeCard(
                                    node: node,
                                    serverURL: serverURL,
                                    onTap: { onNavigate(node.path) }
                                )
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }

                if totalPages > 1 || currentPage > 1 {
                    HStack(spacing: 12) {
                        Spacer()
                        Button("上一页") {
                            onPageChange(max(1, currentPage - 1))
                        }
                        .font(.caption.weight(.medium))
                        .disabled(isLoading || currentPage <= 1)

                        Text("\(currentPage) / \(totalPages)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)

                        Button("下一页") {
                            onPageChange(currentPage + 1)
                        }
                        .font(.caption.weight(.medium))
                        .disabled(isLoading || response == nil || currentPage >= totalPages)
                    }
                }
            }
            .padding(12)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(uiColor: .separator).opacity(0.35), lineWidth: 0.5)
            }
            .padding(.horizontal, 16)
        }
    }
}

private struct LibraryDirectoryBreadcrumbBar: View {
    let currentPath: String
    let breadcrumbs: [LibraryDirectoryBreadcrumb]
    let onNavigate: (String) -> Void

    private var parentPath: String {
        breadcrumbs.count > 1 ? breadcrumbs[breadcrumbs.count - 2].path : ""
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                Label("目录分类", systemImage: "folder.badge.gearshape")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                Button {
                    onNavigate("")
                } label: {
                    Text("全部作品")
                        .font(.caption.weight(currentPath.isEmpty ? .semibold : .medium))
                        .foregroundStyle(currentPath.isEmpty ? .white : .secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(currentPath.isEmpty ? Color.accentColor : Color(uiColor: .tertiarySystemFill))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)

                ForEach(breadcrumbs) { crumb in
                    let isLast = crumb.path == breadcrumbs.last?.path
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    Button {
                        onNavigate(crumb.path)
                    } label: {
                        Text(crumb.name)
                            .font(.caption.weight(isLast ? .bold : .medium))
                            .foregroundStyle(isLast ? Color.accentColor : .secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(isLast ? Color.accentColor.opacity(0.14) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }

                if !currentPath.isEmpty {
                    Button {
                        onNavigate(parentPath)
                    } label: {
                        Label("返回上级", systemImage: "arrow.up")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color(uiColor: .tertiarySystemFill))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 4)
                }
            }
        }
        .scrollIndicators(.hidden)
    }
}

private struct LibraryDirectoryNodeCard: View {
    let node: LibraryDirectoryNode
    let serverURL: String
    let onTap: () -> Void

    private var resolvedCoverURL: URL? {
        let raw = node.coverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            return URL(string: raw)
        }
        let cleanServer = serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
        let suffix = raw.hasPrefix("/") ? raw : "/\(raw)"
        return URL(string: "\(cleanServer)\(suffix)")
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Group {
                    if let url = resolvedCoverURL {
                        AuthenticatedImage(url: url)
                    } else {
                        Color(uiColor: .tertiarySystemFill)
                            .overlay {
                                Image(systemName: "folder.fill")
                                    .font(.caption)
                                    .foregroundStyle(Color.accentColor)
                            }
                    }
                }
                .aspectRatio(contentMode: .fill)
                .frame(width: 34, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    Text(node.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text("\(node.workCount) 部作品")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if node.hasChildren {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(7)
            .frame(width: 158, height: 58, alignment: .leading)
            .background(Color(uiColor: .systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(uiColor: .separator).opacity(0.35), lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
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
    var directoryResponse: LibraryDirectoryListResponse?
    var isLoadingDirectories = false
    var directoryPage = 1

    private var currentPage = 1
    private var sortBy = "addedAt"
    private var sortOrder = "desc"
    private var contentType: String?
    private var tag: String?
    private(set) var libraryId: String?
    private(set) var directoryPath: String = ""
    private let api = APIClient.shared
    private var modelContext: ModelContext?
    /// 当前加载任务版本号，旧任务完成时忽略（避免离线切换时旧请求挂起覆盖状态）
    private var loadVersion: Int = 0
    private var directoryLoadVersion: Int = 0
    @ObservationIgnored private var loadMoreTask: Task<Void, Never>?

    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }

    /// 加载普通书架作品；合集条目由 CollectionViewModel 合并展示。
    func loadAll(refresh: Bool = false) async {
        // 离线 + 已有数据 + 非手动刷新 → 跳过（避免切 tab 时清空再重载）
        if api.isOfflineMode && !comics.isEmpty && !refresh {
            return
        }
        if refresh {
            loadMoreTask?.cancel()
            loadMoreTask = nil
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

    func loadDirectories(library: Library?, page: Int? = nil) async {
        guard let library,
              library.supportsDirectoryCategories,
              !api.isOfflineMode,
              api.isNetworkReachable else {
            directoryLoadVersion += 1
            directoryResponse = nil
            isLoadingDirectories = false
            directoryPage = 1
            return
        }

        directoryLoadVersion += 1
        let version = directoryLoadVersion
        let targetPage = max(1, page ?? directoryPage)
        directoryPage = targetPage
        isLoadingDirectories = true

        do {
            let response = try await api.fetchLibraryDirectories(
                libraryId: library.id,
                parent: directoryPath,
                page: targetPage
            )
            guard !Task.isCancelled, version == directoryLoadVersion else { return }
            directoryResponse = response
            directoryPage = response.page
        } catch {
            guard !isCancellation(error), version == directoryLoadVersion else { return }
            AppLogger.error("加载书库目录分类失败: \(error)")
            directoryResponse = LibraryDirectoryListResponse(
                libraryId: library.id,
                seriesDepth: library.seriesDepth,
                parent: directoryPath,
                page: targetPage
            )
        }

        if version == directoryLoadVersion {
            isLoadingDirectories = false
        }
    }

    private func loadComics(refresh: Bool = false, version: Int) async -> Bool {
        guard version == loadVersion else { return false }
        if refresh { currentPage = 1 }
        let useSeriesView = contentType != "novel"
        if useSeriesView { currentPage = 1 }

        // 离线模式或网络不可达：直接从缓存加载已下载漫画与目录作品（不等 API 超时）
        if APIClient.shared.isOfflineMode || !APIClient.shared.isNetworkReachable {
            await applyOfflineShelfFromCache(version: version)
            hasMore = false
            return true
        }

        do {
            let trimmedDir = directoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
            let resp = try await api.fetchComics(
                page: currentPage,
                pageSize: useSeriesView ? 0 : 20,
                sortBy: sortBy,
                sortOrder: sortOrder,
                contentType: contentType,
                tag: tag,
                excludeGrouped: trimmedDir.isEmpty ? true : nil,
                libraryId: libraryId,
                directoryPath: trimmedDir.isEmpty ? nil : trimmedDir,
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
                await applyOfflineShelfFromCache(version: version)
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

    func requestLoadMore() {
        guard hasMore, !isLoading, loadMoreTask == nil else { return }
        loadMoreTask = Task { @MainActor [weak self] in
            defer { self?.loadMoreTask = nil }
            await self?.loadMore()
        }
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

    func configure(
        contentType: String?,
        sortBy: String,
        sortOrder: String,
        library: Library? = nil,
        directoryPath: String = "",
        tag: String? = nil
    ) async {
        self.contentType = contentType
        self.sortBy = sortBy
        self.sortOrder = sortOrder
        self.tag = tag?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? tag?.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        let nextLibraryId = library?.id ?? api.selectedLibraryId
        let libraryChanged = self.libraryId != nextLibraryId
        let pathChanged = self.directoryPath != directoryPath
        self.libraryId = nextLibraryId
        self.directoryPath = directoryPath
        if libraryChanged || pathChanged {
            self.directoryPage = 1
        }
        async let comicsTask: Void = loadAll(refresh: true)
        async let directoriesTask: Void = loadDirectories(library: library, page: self.directoryPage)
        _ = await (comicsTask, directoriesTask)
    }

    private func isCancellation(_ error: Error) -> Bool {
        Task.isCancelled || (error as? URLError)?.code == .cancelled
    }

    private func applyOfflineShelfFromCache(version: Int) async {
        let snapshot = await offlineShelfSnapshot()
        guard !Task.isCancelled, version == loadVersion, let context = modelContext else { return }

        let cached = loadFromCache(context: context)
        var cachedById: [String: Comic] = [:]
        for comic in cached { cachedById[comic.id] = comic }

        var coveredBySeriesIds = Set<String>()
        var seriesShelfComics: [Comic] = []

        for seriesDetail in snapshot.seriesList {
            let summary = seriesDetail.series
            let allItems = seriesDetail.unsectioned + seriesDetail.sections.flatMap(\.items)
            let memberComicIds: [String] = allItems.flatMap { item in
                [item.comic.id] + item.resolvedEditions.map(\.comicId)
            }
            let downloadedMemberIds = memberComicIds.filter { snapshot.visibleIds.contains($0) }
            guard !downloadedMemberIds.isEmpty else { continue }
            coveredBySeriesIds.formUnion(downloadedMemberIds)

            let downloadedUnitsCount = allItems.filter { item in
                let candidateIds = [item.comic.id] + item.resolvedEditions.map(\.comicId)
                return candidateIds.contains(where: { snapshot.visibleIds.contains($0) })
            }.count
            let isFav = downloadedMemberIds.contains { cachedById[$0]?.isFavorite == true } || summary.isFavorite
            let seriesItem = Comic(
                id: Comic.seriesShelfPrefix + summary.id,
                title: summary.title,
                author: summary.author,
                publisher: summary.publisher,
                description: summary.description,
                genre: summary.genre,
                language: summary.language,
                year: summary.year,
                pageCount: max(1, downloadedUnitsCount),
                fileSize: summary.fileSize,
                lastReadPage: summary.completedItemCount,
                lastReadAt: summary.lastReadAt,
                coverUrl: summary.coverUrl,
                isFavorite: isFav,
                type: summary.contentType ?? "comic",
                filename: "__series__.cbz",
                titleSortKey: summary.sortTitle,
                libraryId: summary.libraryId,
                comicCount: max(1, downloadedUnitsCount)
            )
            if matchesContentType(seriesItem) {
                seriesShelfComics.append(seriesItem)
            }
        }

        let standaloneComics = cached.filter { comic in
            snapshot.visibleIds.contains(comic.id)
                && !coveredBySeriesIds.contains(comic.id)
                && matchesContentType(comic)
        }
        comics = seriesShelfComics + standaloneComics
    }

    private func offlineShelfSnapshot() async -> OfflineShelfSnapshot {
        await Task.detached(priority: .utility) {
            let downloadedIds = Set(
                OfflineFileManager.shared.completedDownloads().keys
            )
            let groupedIds = Set(
                OfflineFileManager.shared.loadGroups().flatMap(\.comicIds)
            )
            let seriesList = OfflineFileManager.shared.loadAllSeries()
            return OfflineShelfSnapshot(
                visibleIds: downloadedIds.subtracting(groupedIds),
                seriesList: seriesList
            )
        }.value
    }
}

private struct OfflineShelfSnapshot: Sendable {
    let visibleIds: Set<String>
    let seriesList: [SeriesDetailResponse]
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
    private var tag: String?
    private let api = APIClient.shared
    private var modelContext: ModelContext?
    private var loadVersion = 0
    @ObservationIgnored private var currentMutationRevision = 0
    @ObservationIgnored private var currentNetworkRecovered = false
    @ObservationIgnored private var lastRemoteCacheKey: CollectionRemoteCacheKey?
    @ObservationIgnored private var lastRemoteSnapshot: RemoteGroupsSnapshot?

    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }

    func load(refresh: Bool = false) async {
        if api.isOfflineMode && !groups.isEmpty && !refresh {
            return
        }
        let cacheKey = CollectionRemoteCacheKey(
            contentType: contentType,
            tag: tag,
            mutationRevision: currentMutationRevision,
            networkRecovered: currentNetworkRecovered
        )
        if !refresh,
           !api.isOfflineMode,
           api.isNetworkReachable,
           lastRemoteCacheKey == cacheKey,
           let cached = lastRemoteSnapshot {
            groups = sortedGroups(cached.groups)
            groupedComicIds = cached.membership.comicIds
            groupedSeriesIds = cached.membership.seriesIds
            isLoading = false
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
            lastRemoteCacheKey = cacheKey
            lastRemoteSnapshot = remote
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
            let tagFilter = tag.map { [$0] } ?? []
            if contentType == nil {
                async let comicGroups = api.fetchGroups(contentType: "comic", tags: tagFilter)
                async let novelGroups = api.fetchGroups(contentType: "novel", tags: tagFilter)
                let allGroups = try await comicGroups + novelGroups
                var seen = Set<Int>()
                loadedGroups = allGroups.filter { seen.insert($0.id).inserted }
            } else {
                loadedGroups = try await api.fetchGroups(contentType: contentType, tags: tagFilter)
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
        guard !groups.isEmpty else { return .empty }
        let selectedContentType = contentType
        let maxConcurrent = 4
        return await withTaskGroup(of: GroupMembershipSnapshot.self) { taskGroup in
            var nextIndex = 0
            let initialCount = min(maxConcurrent, groups.count)
            while nextIndex < initialCount {
                let group = groups[nextIndex]
                nextIndex += 1
                taskGroup.addTask { [api] in
                    await Self.fetchMembershipSnapshot(
                        api: api,
                        groupId: group.id,
                        contentType: selectedContentType
                    )
                }
            }

            var result = GroupMembershipSnapshot.empty
            for await membership in taskGroup {
                result.comicIds.formUnion(membership.comicIds)
                result.seriesIds.formUnion(membership.seriesIds)
                if nextIndex < groups.count && !Task.isCancelled {
                    let group = groups[nextIndex]
                    nextIndex += 1
                    taskGroup.addTask { [api] in
                        await Self.fetchMembershipSnapshot(
                            api: api,
                            groupId: group.id,
                            contentType: selectedContentType
                        )
                    }
                }
            }
            return result
        }
    }

    private static func fetchMembershipSnapshot(
        api: APIClient,
        groupId: Int,
        contentType: String?
    ) async -> GroupMembershipSnapshot {
        do {
            let detail = try await api.fetchGroupDetail(
                id: groupId,
                contentType: contentType
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

    func configure(
        contentType: String?,
        sortBy: String,
        sortOrder: String,
        tag: String? = nil,
        contentMutationRevision: Int = 0,
        networkRecovered: Bool = false,
        refresh: Bool = true
    ) async {
        self.contentType = contentType
        self.sortBy = sortBy
        self.sortOrder = sortOrder
        self.currentMutationRevision = contentMutationRevision
        self.currentNetworkRecovered = networkRecovered
        self.tag = tag?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? tag?.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        await load(refresh: refresh)
    }
}

private struct CollectionRemoteCacheKey: Equatable {
    let contentType: String?
    let tag: String?
    let mutationRevision: Int
    let networkRecovered: Bool
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
