import SwiftUI
import SwiftData

struct GroupDetailView: View {
    let groupId: Int
    let contentType: String?
    @State private var viewModel = GroupDetailViewModel()
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(APIClient.self) private var api
    @State private var showDownloadAllAlert = false
    @State private var showDownloadResult = false
    @State private var downloadQueued = 0
    @State private var downloadSkipped = 0

    init(groupId: Int, contentType: String? = nil) {
        self.groupId = groupId
        self.contentType = contentType
    }

    var body: some View {
        Group {
            if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let detail = viewModel.detail {
                ScrollView {
                    let readingUnits = detail.readingUnits
                    let seriesList = detail.sortedSeriesList
                    let directComics = detail.sortedComics

                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 16) {
                            Group {
                                if let cover = detail.coverUrl, !cover.isEmpty {
                                    let urlString = cover.hasPrefix("http") ? cover : "\(api.serverURL)\(cover)"
                                    if let url = URL(string: urlString) {
                                        AuthenticatedImage(url: url)
                                    }
                                } else if let firstId = detail.fallbackCoverComicId {
                                    AuthenticatedImage(
                                        serverURL: api.serverURL,
                                        comicId: firstId,
                                        thumbnail: true
                                    )
                                } else {
                                    Color(.systemGray6)
                                }
                            }
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 110, height: 155)
                            .clipShape(RoundedRectangle(cornerRadius: 10))

                            VStack(alignment: .leading, spacing: 10) {
                                Text(detail.name)
                                    .font(.title3.weight(.bold))
                                    .lineLimit(2)

                                if let author = detail.author, !author.isEmpty {
                                    Text(author)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                let totalPages = readingUnits.reduce(0) { $0 + $1.pageCount }
                                let totalSize = readingUnits.reduce(Int64(0)) { $0 + ($1.fileSize ?? 0) }

                                VStack(alignment: .leading, spacing: 5) {
                                    Label("\(detail.displayCount) 个阅读单元", systemImage: "books.vertical")
                                    Label("\(totalPages) 页", systemImage: "doc.text")
                                    Label(formatFileSize(totalSize), systemImage: "internaldrive")
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 12)

                        WorkMetadataSection(
                            tags: detail.tagItems,
                            categories: detail.categories,
                            onSelectTag: { tagName in
                                api.activateTagFilter(tagName)
                            }
                        )
                            .padding(.horizontal, 20)

                        WorkActionBarSection(
                            isFavorite: viewModel.isFavorite,
                            isUpdatingFavorite: viewModel.isUpdatingFavorite,
                            isOfflineMode: api.isOfflineMode,
                            unitIds: readingUnits.map(\.id),
                            hasReadingProgress: viewModel.hasReadingProgress,
                            hasContinueTarget: viewModel.continueUnit != nil,
                            onToggleFavorite: {
                                Task { await viewModel.toggleFavorite(context: modelContext) }
                            },
                            onTapCache: {
                                showDownloadAllAlert = true
                            }
                        ) {
                            if let unit = viewModel.continueUnit {
                                unit.readerView(groupContext: viewModel.readingContext(for: unit.id))
                                    .bookCoverDestination(id: "group-reader-\(groupId)")
                            }
                        }
                        .padding(.horizontal, 20)

                        WorkDescriptionSection(text: detail.description)
                    }

                    VStack(alignment: .leading, spacing: 20) {
                        Text("作品 (\(readingUnits.count))")
                            .font(.headline)
                            .padding(.horizontal, 20)

                        ForEach(seriesList) { series in
                            GroupSeriesSectionView(
                                series: series,
                                serverURL: api.serverURL,
                                contextProvider: { comic in
                                    viewModel.readingContext(for: comic.id)
                                }
                            )
                        }

                        if !directComics.isEmpty {
                            GroupComicRailView(
                                title: "其他作品",
                                subtitle: "\(directComics.count) 个阅读单元",
                                comics: directComics,
                                serverURL: api.serverURL,
                                contextProvider: { comic in
                                    viewModel.readingContext(for: comic.id)
                                }
                            )
                        }

                        if readingUnits.isEmpty {
                            ContentUnavailableView("此合集还没有作品", systemImage: "books.vertical")
                                .padding(.vertical, 40)
                        }
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 20)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title)
                        .foregroundStyle(.tertiary)
                    Text("加载失败")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                // 下载全部按钮
                if let detail = viewModel.detail, !detail.readingUnits.isEmpty {
                    Button {
                        showDownloadAllAlert = true
                    } label: {
                        Image(systemName: "arrow.down.circle")
                    }
                }
            }
        }
        .onChange(of: api.tagFilterNavigationRevision) { _, _ in
            dismiss()
        }
        .task {
            DownloadManager.shared.setModelContext(modelContext)
            await viewModel.load(groupId: groupId, contentType: contentType, context: modelContext)
        }
        .onAppear {
            guard viewModel.detail != nil else { return }
            Task {
                await viewModel.refreshSilently(
                    groupId: groupId,
                    contentType: contentType,
                    context: modelContext
                )
            }
        }
        .alert("离线缓存全部卷", isPresented: $showDownloadAllAlert) {
            Button("取消", role: .cancel) {}
            Button("开始缓存") {
                guard let detail = viewModel.detail else { return }
                let result = viewModel.downloadAllVolumes(detail: detail, context: modelContext)
                downloadQueued = result.queued
                downloadSkipped = result.skipped
                showDownloadResult = true
            }
        } message: {
            if let detail = viewModel.detail {
                let units = detail.readingUnits
                let totalPages = units.reduce(0) { $0 + $1.pageCount }
                let alreadyDownloaded = units.filter { DownloadManager.shared.isDownloaded(comicId: $0.id) }.count
                Text("共 \(units.count) 个阅读单元、\(totalPages) 页。已缓存 \(alreadyDownloaded) 个，其余将加入离线队列。")
            }
        }
        .alert("离线缓存结果", isPresented: $showDownloadResult) {
            Button("确定") {}
        } message: {
            Text("已加入 \(downloadQueued) 卷到缓存队列，跳过 \(downloadSkipped) 卷（已缓存或空间不足）。")
        }
    }

}

struct GroupSeriesSectionView: View {
    let series: GroupSeriesItem
    let serverURL: String
    let contextProvider: (GroupComicItem) -> ReadingGroupContext?

    private var coverURL: URL? {
        guard let cover = series.coverUrl, !cover.isEmpty else { return nil }
        return URL(string: cover.hasPrefix("http") ? cover : "\(serverURL)\(cover)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                NavigationLink {
                    SeriesDetailView(seriesId: series.id)
                } label: {
                    HStack(spacing: 10) {
                        Group {
                            if let coverURL {
                                AuthenticatedImage(url: coverURL)
                            } else if let coverComicId = series.coverComicId, !coverComicId.isEmpty {
                                AuthenticatedImage(serverURL: serverURL, comicId: coverComicId, thumbnail: true)
                            } else {
                                Color(.systemGray6)
                                    .overlay {
                                        Image(systemName: "books.vertical")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                            }
                        }
                        .frame(width: 34, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 5))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(series.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if let path = series.rootRelativePath, !path.isEmpty {
                                Text(path)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                Text("\(series.sortedComics.count) 个阅读单元")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)

            GroupComicRail(
                comics: series.sortedComics,
                serverURL: serverURL,
                contextProvider: contextProvider
            )
        }
    }
}

struct GroupComicRailView: View {
    let title: String
    let subtitle: String
    let comics: [GroupComicItem]
    let serverURL: String
    let contextProvider: (GroupComicItem) -> ReadingGroupContext?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)

            GroupComicRail(
                comics: comics,
                serverURL: serverURL,
                contextProvider: contextProvider
            )
        }
    }
}

struct GroupComicRail: View {
    let comics: [GroupComicItem]
    let serverURL: String
    let contextProvider: (GroupComicItem) -> ReadingGroupContext?
    private let cardWidth: CGFloat = 112
    private let cardHeight: CGFloat = 192

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(comics) { comic in
                    NavigationLink {
                        ComicDetailView(
                            comicId: comic.id,
                            groupContext: contextProvider(comic),
                            initialPreview: ComicDetailPreview(comic: comic)
                        )
                        .bookCoverDestination(id: "comic-\(comic.id)")
                    } label: {
                        VolumeCardView(comic: comic, serverURL: serverURL)
                            .frame(width: cardWidth, height: cardHeight, alignment: .top)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .frame(height: cardHeight, alignment: .top)
        }
        .scrollIndicators(.hidden)
        .frame(height: cardHeight)
    }
}

// MARK: - 卷卡片

struct VolumeCardView: View {
    let comic: GroupComicItem
    let serverURL: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                AuthenticatedImage(serverURL: serverURL, comicId: comic.id, thumbnail: true)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 112, height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .bookCoverSource(id: "comic-\(comic.id)")
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(.gray.opacity(0.15), lineWidth: 0.5)
                    )

                if comic.progress > 0 {
                    VStack {
                        Spacer()
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(.black.opacity(0.3))
                                Rectangle()
                                    .fill(Color.accentColor)
                                    .frame(width: geo.size.width * CGFloat(comic.progress) / 100)
                            }
                        }
                        .frame(height: 3)
                        .clipShape(RoundedRectangle(cornerRadius: 1.5))
                    }
                }

                if !comic.formatBadge.isEmpty {
                    Text(comic.formatBadge)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.72))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }

            Text(comic.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .padding(.top, 8)
                .frame(height: 42, alignment: .topLeading)
        }
        .frame(width: 112, height: 192, alignment: .top)
    }
}

// MARK: - 卷列表行

struct VolumeListRowView: View {
    let comic: GroupComicItem
    let serverURL: String

    var body: some View {
        HStack(spacing: 12) {
            AuthenticatedImage(serverURL: serverURL, comicId: comic.id, thumbnail: true)
                .aspectRatio(contentMode: .fill)
                .frame(width: 56, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .bookCoverSource(id: "comic-\(comic.id)")

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(comic.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if !comic.formatBadge.isEmpty {
                        Text(comic.formatBadge)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .fixedSize()
                    }
                }

                if comic.pageCount > 0 {
                    Text("\(comic.pageCount) 页 · \(comic.progress)%")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if comic.progress > 0 {
                Text("\(comic.progress)%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - ViewModel

private struct OfflineGroupDetailLoadSnapshot: Sendable {
    let group: OfflineGroupMeta?
    let completedMetas: [String: OfflineComicMeta]
}

@MainActor
@Observable
final class GroupDetailViewModel {
    var detail: GroupDetailResponse?
    var isLoading = false
    var errorMessage: String?
    var isFavorite = false
    var isUpdatingFavorite = false
    private var readingUnitIds: [String] = []
    private var readingUnitIndexById: [String: Int] = [:]

    var continueUnit: GroupComicItem? {
        let units = detail?.readingUnits ?? []
        if let inProgress = units.first(where: { hasStarted($0) && !isFinished($0) }) {
            return inProgress
        }
        return units.first(where: { !isFinished($0) }) ?? units.first
    }

    var hasReadingProgress: Bool {
        (detail?.readingUnits ?? []).contains {
            hasStarted($0) || $0.readingStatus == "finished"
        }
    }

    func load(groupId: Int, contentType: String? = nil, context: ModelContext? = nil) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil

        // 离线：从本地加载合集
        if APIClient.shared.isOfflineMode || !APIClient.shared.isNetworkReachable {
            await loadOfflineGroup(groupId: groupId, contentType: contentType, context: context)
            isLoading = false
            return
        }

        do {
            async let detailTask = APIClient.shared.fetchGroupDetail(id: groupId, contentType: contentType)
            async let favGroupsTask: [ComicGroup]? = try? APIClient.shared.fetchGroups(
                contentType: contentType,
                favoritesOnly: true
            )
            let loadedDetail = try await detailTask
            let favGroups = await favGroupsTask
            updateDetail(loadedDetail)
            if let favGroups {
                isFavorite = favGroups.contains { $0.id == groupId }
            } else if let context {
                isFavorite = hasAnyFavoritedUnitInCache(unitIds: loadedDetail.readingUnits.map(\.id), context: context)
            }
        } catch {
            if OfflineFileManager.shared.loadGroupDetail(groupId: groupId) != nil {
                await loadOfflineGroup(groupId: groupId, contentType: contentType, context: context)
            } else {
                updateDetail(nil)
                errorMessage = error.localizedDescription
            }
        }
        isLoading = false
    }

    func refreshSilently(groupId: Int, contentType: String? = nil, context: ModelContext? = nil) async {
        guard !isLoading else { return }
        if APIClient.shared.isOfflineMode || !APIClient.shared.isNetworkReachable {
            await loadOfflineGroup(groupId: groupId, contentType: contentType, context: context)
            return
        }
        do {
            async let detailTask = APIClient.shared.fetchGroupDetail(id: groupId, contentType: contentType)
            async let favGroupsTask: [ComicGroup]? = try? APIClient.shared.fetchGroups(
                contentType: contentType,
                favoritesOnly: true
            )
            let loadedDetail = try await detailTask
            let favGroups = await favGroupsTask
            updateDetail(loadedDetail)
            if let favGroups {
                isFavorite = favGroups.contains { $0.id == groupId }
            }
        } catch {
            // 静默刷新失败保持当前数据
        }
    }

    func toggleFavorite(context: ModelContext? = nil) async {
        guard !readingUnitIds.isEmpty, !isUpdatingFavorite else { return }
        let targetFavorite = !isFavorite
        isUpdatingFavorite = true
        defer { isUpdatingFavorite = false }
        do {
            try await APIClient.shared.batchSetFavorite(comicIds: readingUnitIds, isFavorite: targetFavorite)
            isFavorite = targetFavorite
            syncFavoriteToCache(unitIds: readingUnitIds, isFavorite: targetFavorite, context: context)
            APIClient.shared.contentMutationRevision += 1
        } catch {
            AppLogger.error("切换合集收藏状态失败: \(error.localizedDescription)")
        }
    }

    func downloadAllVolumes(detail: GroupDetailResponse, context: ModelContext?) -> (queued: Int, skipped: Int) {
        if let context {
            cacheGroupUnits(detail.readingUnits, context: context)
        }
        return DownloadManager.shared.downloadAll(comics: detail.readingUnits, groupDetail: detail)
    }

    private func loadOfflineGroup(groupId: Int, contentType: String?, context: ModelContext?) async {
        let offlineSnapshot = await Task.detached(priority: .utility) {
            OfflineGroupDetailLoadSnapshot(
                group: OfflineFileManager.shared.loadGroupDetail(groupId: groupId),
                completedMetas: OfflineFileManager.shared.completedDownloads()
            )
        }.value
        guard !Task.isCancelled else { return }

        if let local = offlineSnapshot.group {
            var comics: [GroupComicItem] = []
            let localComicIds = Set(local.comicIds)
            var cachedMap: [String: CachedComic] = [:]
            if let context {
                let allCached = try? context.fetch(FetchDescriptor<CachedComic>())
                if let allCached {
                    for c in allCached where localComicIds.contains(c.id) {
                        cachedMap[c.id] = c
                    }
                }
            }
            let iso8601Formatter = ISO8601DateFormatter()
            for (index, comicId) in local.comicIds.enumerated() {
                guard let meta = offlineSnapshot.completedMetas[comicId] else {
                    continue
                }
                let cached = cachedMap[comicId]
                if let contentType, let cachedType = cached?.type, cachedType != contentType {
                    continue
                }
                let resolvedType = cached?.type
                    ?? (meta.isNovel == true ? "novel" : "comic")
                comics.append(GroupComicItem(
                    id: comicId,
                    filename: nil,
                    title: cached?.title ?? meta.title,
                    pageCount: cached?.pageCount ?? meta.pageCount,
                    fileSize: meta.fileSize,
                    lastReadPage: cached?.lastReadPage ?? 0,
                    totalReadTime: nil,
                    coverUrl: cached?.coverUrl,
                    sortIndex: index,
                    readingStatus: cached?.readingStatus,
                    lastReadAt: cached?.lastReadAt.map {
                        iso8601Formatter.string(from: $0)
                    },
                    type: resolvedType
                ))
            }
            updateDetail(GroupDetailResponse(
                id: local.id,
                name: local.name,
                coverUrl: local.coverUrl,
                author: local.author,
                description: local.description,
                comicCount: comics.count,
                tagItems: local.tagItems,
                categories: local.categories,
                seriesList: [],
                comics: comics
            ))
            isFavorite = comics.contains { cachedMap[$0.id]?.isFavorite == true }
        } else {
            updateDetail(nil)
            errorMessage = "离线模式下无法加载合集"
        }
    }

    private func cacheGroupUnits(_ units: [GroupComicItem], context: ModelContext) {
        let existing = context.fetchOrLog(FetchDescriptor<CachedComic>(), label: "缓存合集分卷前查询")
        var byId: [String: CachedComic] = [:]
        for item in existing { byId[item.id] = item }
        for unit in units {
            if let existingCached = byId[unit.id] {
                existingCached.title = unit.title
                existingCached.pageCount = unit.pageCount
                existingCached.lastReadPage = max(existingCached.lastReadPage, unit.lastReadPage)
                existingCached.readingStatus = unit.readingStatus ?? existingCached.readingStatus
                existingCached.type = unit.type ?? existingCached.type
                existingCached.cachedAt = Date()
            } else {
                let c = CachedComic()
                c.id = unit.id
                c.title = unit.title
                c.coverUrl = unit.coverUrl
                c.pageCount = unit.pageCount
                c.lastReadPage = unit.lastReadPage
                c.readingStatus = unit.readingStatus
                c.type = unit.type
                c.lastReadAt = unit.lastReadAt.flatMap { Date.fromISO8601($0) }
                c.cachedAt = Date()
                context.insert(c)
                byId[unit.id] = c
            }
        }
        context.saveOrLog()
    }

    private func syncFavoriteToCache(unitIds: [String], isFavorite: Bool, context: ModelContext?) {
        guard let context else { return }
        let targetSet = Set(unitIds)
        let cached = context.fetchOrLog(FetchDescriptor<CachedComic>(), label: "同步合集收藏状态")
        var changed = false
        for item in cached where targetSet.contains(item.id) {
            item.isFavorite = isFavorite
            changed = true
        }
        if changed { context.saveOrLog() }
    }

    private func hasAnyFavoritedUnitInCache(unitIds: [String], context: ModelContext) -> Bool {
        let targetSet = Set(unitIds)
        let cached = context.fetchOrLog(FetchDescriptor<CachedComic>(), label: "检查合集缓存收藏状态")
        return cached.contains { targetSet.contains($0.id) && $0.isFavorite }
    }

    private func isFinished(_ unit: GroupComicItem) -> Bool {
        if unit.readingStatus == "finished" { return true }
        guard hasStarted(unit), unit.pageCount > 0 else { return false }
        return unit.lastReadPage >= unit.pageCount - 1
    }

    private func hasStarted(_ unit: GroupComicItem) -> Bool {
        unit.lastReadPage > 0 || unit.readingStatus == "reading"
    }

    func readingContext(for comicId: String) -> ReadingGroupContext? {
        guard let detail else { return nil }
        guard let index = readingUnitIndexById[comicId] else { return nil }
        return ReadingGroupContext(groupId: detail.id, volumeIds: readingUnitIds, currentIndex: index)
    }

    private func updateDetail(_ newDetail: GroupDetailResponse?) {
        detail = newDetail
        readingUnitIds = newDetail?.readingUnits.map { $0.id } ?? []
        readingUnitIndexById = [:]
        for (index, comicId) in readingUnitIds.enumerated()
        where readingUnitIndexById[comicId] == nil {
            readingUnitIndexById[comicId] = index
        }
    }
}

private struct BatchOfflineCacheButton: View {
    let unitIds: [String]
    let onTapCache: () -> Void
    private let downloadManager = DownloadManager.shared

    private var completedCount: Int {
        unitIds.filter { id in
            downloadManager.task(for: id)?.state == .completed || downloadManager.isDownloaded(comicId: id)
        }.count
    }

    private var isDownloadingOrQueued: Bool {
        unitIds.contains { id in
            let state = downloadManager.task(for: id)?.state
            return state == .downloading || state == .waiting
        }
    }

    private var hasPaused: Bool {
        unitIds.contains { downloadManager.task(for: $0)?.state == .paused }
    }

    private var isAllCached: Bool {
        !unitIds.isEmpty && completedCount == unitIds.count
    }

    var body: some View {
        if isAllCached {
            Button {} label: {
                Label("已缓存", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.green.opacity(0.1))
                    .foregroundStyle(.green)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .disabled(true)
        } else if isDownloadingOrQueued {
            Button(action: onTapCache) {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("\(completedCount)/\(unitIds.count)")
                        .font(.subheadline.weight(.medium).monospacedDigit())
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.orange.opacity(0.1))
                .foregroundStyle(.orange)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        } else if hasPaused || completedCount > 0 {
            Button(action: onTapCache) {
                Label("继续缓存", systemImage: "arrow.down.circle")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.orange.opacity(0.1))
                    .foregroundStyle(.orange)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        } else {
            Button(action: onTapCache) {
                Label("离线缓存", systemImage: "arrow.down.circle")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color(.systemGray6))
                    .foregroundStyle(.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .disabled(unitIds.isEmpty)
        }
    }
}

private struct WorkActionBarSection<ContinueDestination: View>: View {
    let isFavorite: Bool
    let isUpdatingFavorite: Bool
    let isOfflineMode: Bool
    let unitIds: [String]
    let hasReadingProgress: Bool
    let hasContinueTarget: Bool
    let onToggleFavorite: () -> Void
    let onTapCache: () -> Void
    @ViewBuilder let continueDestination: () -> ContinueDestination

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggleFavorite) {
                HStack(spacing: 6) {
                    if isUpdatingFavorite {
                        ProgressView().controlSize(.small)
                        Text("处理中")
                    } else {
                        Label(
                            isFavorite ? "已收藏" : "收藏",
                            systemImage: isFavorite ? "heart.fill" : "heart"
                        )
                    }
                }
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(isFavorite ? Color.red.opacity(0.1) : Color(.systemGray6))
                .foregroundStyle(isFavorite ? .red : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .disabled(isUpdatingFavorite || isOfflineMode || unitIds.isEmpty)
            .sensoryFeedback(.success, trigger: isFavorite)

            BatchOfflineCacheButton(unitIds: unitIds, onTapCache: onTapCache)

            if hasContinueTarget {
                NavigationLink {
                    continueDestination()
                } label: {
                    Label(
                        hasReadingProgress ? "继续阅读" : "开始阅读",
                        systemImage: "book.fill"
                    )
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }
}

// MARK: - 目录作品详情

struct SeriesDetailView: View {
    let seriesId: String
    @State private var viewModel = SeriesDetailViewModel()
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(APIClient.self) private var api
    @State private var isGrid = true
    @State private var deletingSeries: SeriesSummary?
    @State private var shouldDismissAfterDelete = false
    @State private var showDownloadAllAlert = false
    @State private var showDownloadResult = false
    @State private var downloadQueued = 0
    @State private var downloadSkipped = 0

    private var canManageSeries: Bool {
        viewModel.detail?.series.canManage == true && !api.isOfflineMode && api.isLoggedIn
    }

    var body: some View {
        Group {
            if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let detail = viewModel.detail {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        let continueTarget = viewModel.continueItem
                        SeriesHeaderView(
                            series: detail.series,
                            continueItem: continueTarget,
                            activeContinueEdition: continueTarget.flatMap { viewModel.activeEdition(for: $0) },
                            isFavorite: viewModel.isFavorite,
                            isUpdatingFavorite: viewModel.isUpdatingFavorite,
                            isOfflineMode: api.isOfflineMode,
                            hasReadingProgress: viewModel.hasReadingProgress,
                            downloadableUnitIds: viewModel.downloadableUnitIds,
                            serverURL: api.serverURL,
                            contextProvider: { viewModel.readingContext(for: $0) },
                            onToggleFavorite: {
                                Task { await viewModel.toggleFavorite() }
                            },
                            onTapCache: {
                                showDownloadAllAlert = true
                            },
                            onSelectTag: { tagName in
                                api.activateTagFilter(tagName)
                            }
                        )
                        .padding(.horizontal, 20)
                        .padding(.top, 12)

                        if !detail.sections.isEmpty {
                            ScrollView(.horizontal) {
                                HStack(spacing: 8) {
                                    SeriesFilterButton(
                                        title: "全部 \(viewModel.allItems.count)",
                                        isSelected: viewModel.selectedSectionId == nil
                                    ) {
                                        viewModel.selectSection(nil)
                                    }

                                    if !detail.unsectioned.isEmpty {
                                        SeriesFilterButton(
                                            title: "其他 \(detail.unsectioned.count)",
                                            isSelected: viewModel.selectedSectionId == SeriesDetailViewModel.unsectionedSectionId
                                        ) {
                                            viewModel.selectSection(SeriesDetailViewModel.unsectionedSectionId)
                                        }
                                    }

                                    ForEach(detail.sections) { section in
                                        SeriesFilterButton(
                                            title: "\(section.title) \(section.items.count)",
                                            isSelected: viewModel.selectedSectionId == section.id
                                        ) {
                                            viewModel.selectSection(section.id)
                                        }
                                    }
                                }
                                .padding(.horizontal, 20)
                            }
                            .scrollIndicators(.hidden)
                        }

                        if isGrid {
                            let cols = [GridItem(
                                .adaptive(minimum: sizeClass == .regular ? 160 : 105),
                                spacing: 12
                            )]
                            LazyVGrid(columns: cols, spacing: 16) {
                                ForEach(viewModel.visibleItems) { item in
                                    let targetComicId = viewModel.activeComicId(for: item)
                                    NavigationLink {
                                        ComicDetailView(
                                            comicId: targetComicId,
                                            groupContext: viewModel.readingContext(for: item),
                                            initialPreview: ComicDetailPreview(comic: item.comic)
                                        )
                                        .bookCoverDestination(id: "comic-\(item.comic.id)")
                                    } label: {
                                        SeriesUnitCardView(item: item, serverURL: api.serverURL)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 24)
                        } else {
                            LazyVStack(spacing: 0) {
                                ForEach(viewModel.visibleItems) { item in
                                    let targetComicId = viewModel.activeComicId(for: item)
                                    let editions = item.resolvedEditions
                                    VStack(alignment: .leading, spacing: 0) {
                                        NavigationLink {
                                            ComicDetailView(
                                                comicId: targetComicId,
                                                groupContext: viewModel.readingContext(for: item),
                                                initialPreview: ComicDetailPreview(comic: item.comic)
                                            )
                                            .bookCoverDestination(id: "comic-\(item.comic.id)")
                                        } label: {
                                            SeriesUnitListRowView(item: item, serverURL: api.serverURL)
                                                .padding(.horizontal, 20)
                                        }
                                        .buttonStyle(.plain)
                                        .contentShape(Rectangle())

                                        if editions.count > 1 {
                                            SeriesItemEditionBar(
                                                editions: editions,
                                                activeComicId: targetComicId,
                                                onSelectEdition: { editionComicId in
                                                    viewModel.switchEdition(itemId: item.id, to: editionComicId)
                                                }
                                            )
                                            .padding(.leading, 88)
                                            .padding(.trailing, 20)
                                            .padding(.bottom, 8)
                                        }

                                        Divider().padding(.leading, 80)
                                    }
                                }
                            }
                            .padding(.bottom, 24)
                        }
                    }
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title)
                        .foregroundStyle(.tertiary)
                    Text(viewModel.errorMessage ?? "加载失败")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    withAnimation { isGrid.toggle() }
                } label: {
                    Image(systemName: isGrid ? "list.bullet" : "square.grid.2x2")
                }

                if canManageSeries, let detail = viewModel.detail {
                    Menu {
                        Button(role: .destructive) {
                            deletingSeries = detail.series
                        } label: {
                            Label("删除整部作品", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("作品管理菜单")
                }
            }
        }
        .sheet(item: $deletingSeries, onDismiss: {
            if shouldDismissAfterDelete {
                dismiss()
            }
        }) { series in
            DeleteContentConfirmSheet(
                title: "删除整部作品",
                description: "即将删除《\(series.title)》（共 \(series.itemCount) 个阅读单元）。请选择移除方式。",
                showEditionOption: true,
                editionCount: 0,
                initialDeleteEditions: true,
                onConfirm: { deleteFiles, deleteEditions in
                    try await viewModel.deleteWholeSeries(
                        seriesId: series.id,
                        deleteFiles: deleteFiles,
                        deleteEditions: deleteEditions
                    )
                    shouldDismissAfterDelete = true
                }
            )
        }
        .onChange(of: api.tagFilterNavigationRevision) { _, _ in
            dismiss()
        }
        .task {
            viewModel.setModelContext(modelContext)
            DownloadManager.shared.setModelContext(modelContext)
            await viewModel.load(seriesId: seriesId)
        }
        .onAppear {
            guard viewModel.detail != nil else { return }
            Task {
                await viewModel.refreshSilently(seriesId: seriesId)
            }
        }
        .alert("离线缓存全部卷", isPresented: $showDownloadAllAlert) {
            Button("取消", role: .cancel) {}
            Button("开始缓存") {
                let result = viewModel.downloadAllVolumes()
                downloadQueued = result.queued
                downloadSkipped = result.skipped
                showDownloadResult = true
            }
        } message: {
            let units = viewModel.downloadableUnits
            let totalPages = units.reduce(0) { $0 + $1.pageCount }
            let alreadyCached = units.filter { DownloadManager.shared.isDownloaded(comicId: $0.id) }.count
            Text("共 \(units.count) 个阅读单元、\(totalPages) 页。已缓存 \(alreadyCached) 个，其余将加入离线队列。")
        }
        .alert("离线缓存结果", isPresented: $showDownloadResult) {
            Button("确定") {}
        } message: {
            Text("已加入 \(downloadQueued) 卷到缓存队列，跳过 \(downloadSkipped) 卷（已缓存或空间不足）。")
        }
    }
}

struct SeriesHeaderView: View {
    let series: SeriesSummary
    let continueItem: SeriesItem?
    let activeContinueEdition: ComicEditionInfo?
    let isFavorite: Bool
    let isUpdatingFavorite: Bool
    let isOfflineMode: Bool
    let hasReadingProgress: Bool
    let downloadableUnitIds: [String]
    let serverURL: String
    let contextProvider: (SeriesItem) -> ReadingGroupContext?
    let onToggleFavorite: () -> Void
    let onTapCache: () -> Void
    var onSelectTag: ((String) -> Void)? = nil

    private var coverImageURL: URL? {
        guard let cover = series.coverUrl, !cover.isEmpty else { return nil }
        return URL(string: cover.hasPrefix("http") ? cover : "\(serverURL)\(cover)")
    }

    private var displayPath: String? {
        let path = series.rootRelativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty,
              path.localizedCaseInsensitiveCompare(series.title) != .orderedSame else {
            return nil
        }
        return path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                Group {
                    if let url = coverImageURL {
                        AuthenticatedImage(url: url)
                    } else if let coverComicId = series.coverComicId, !coverComicId.isEmpty {
                        AuthenticatedImage(serverURL: serverURL, comicId: coverComicId, thumbnail: true)
                    } else {
                        Color(.systemGray6)
                            .overlay {
                                Image(systemName: "books.vertical")
                                    .font(.title)
                                    .foregroundStyle(.tertiary)
                            }
                    }
                }
                .aspectRatio(contentMode: .fill)
                .frame(width: 110, height: 155)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .bookCoverSource(id: "series-reader-\(series.id)")

                VStack(alignment: .leading, spacing: 10) {
                    Text(series.title)
                        .font(.title3.weight(.bold))
                        .lineLimit(2)

                    if let author = series.author?.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ), !author.isEmpty {
                        Label(author, systemImage: "person")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if let displayPath {
                        Text(displayPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Label("\(series.itemCount) 项", systemImage: "books.vertical")
                        if series.sectionCount > 0 {
                            Label("\(series.sectionCount) 季/篇", systemImage: "square.stack.3d.up")
                        }
                        if series.fileSize > 0 {
                            Label(formatFileSize(series.fileSize), systemImage: "internaldrive")
                        }
                        if series.totalReadTime > 0 {
                            Label(formatDuration(series.totalReadTime), systemImage: "clock")
                        }
                        if let year = series.year {
                            Label(
                                year.formatted(.number.grouping(.never)),
                                systemImage: "calendar"
                            )
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            WorkActionBarSection(
                isFavorite: isFavorite,
                isUpdatingFavorite: isUpdatingFavorite,
                isOfflineMode: isOfflineMode,
                unitIds: downloadableUnitIds,
                hasReadingProgress: hasReadingProgress,
                hasContinueTarget: continueItem != nil,
                onToggleFavorite: onToggleFavorite,
                onTapCache: onTapCache
            ) {
                if let continueItem {
                    if let activeContinueEdition {
                        activeContinueEdition.readerView(
                            isNovelLibrary: continueItem.comic.isNovel,
                            groupContext: contextProvider(continueItem)
                        )
                        .bookCoverDestination(id: "series-reader-\(series.id)")
                    } else {
                        continueItem.comic.readerView(groupContext: contextProvider(continueItem))
                            .bookCoverDestination(id: "series-reader-\(series.id)")
                    }
                }
            }

            if series.progress > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("整体进度")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(series.completedItemCount)/\(series.itemCount)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: Double(series.completedItemCount), total: Double(max(series.itemCount, 1)))
                }
            }

            WorkMetadataSection(
                tags: series.tags,
                categories: series.categories,
                onSelectTag: onSelectTag
            )

            WorkDescriptionSection(text: series.description, horizontalPadding: 0)
        }
    }
}

struct WorkMetadataSection: View {
    let tags: [TagItem]?
    let categories: [CategoryItem]?
    var onSelectTag: ((String) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let categories, !categories.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("分类", systemImage: "folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    FlowLayout(spacing: 8) {
                        ForEach(categories, id: \.id) { category in
                            Text(category.name)
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.accentColor.opacity(0.1), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }

            if let tags, !tags.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("标签", systemImage: "tag")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    FlowLayout(spacing: 8) {
                        ForEach(tags, id: \.name) { tag in
                            if let onSelectTag {
                                Button {
                                    onSelectTag(tag.name)
                                } label: {
                                    Text(tag.name)
                                        .font(.caption.weight(.medium))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                                        .foregroundStyle(Color.accentColor)
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("点击跳转到书架按此标签筛选")
                            } else {
                                Text(tag.name)
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color(.secondarySystemBackground), in: Capsule())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct WorkDescriptionSection: View {
    let text: String?
    var horizontalPadding: CGFloat = 20
    @State private var isExpanded = false

    private var normalizedText: String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var canExpand: Bool {
        guard let normalizedText else { return false }
        return normalizedText.count > 100 || normalizedText.filter(\.isNewline).count >= 3
    }

    var body: some View {
        if let normalizedText {
            VStack(alignment: .leading, spacing: 8) {
                Label("作品简介", systemImage: "text.alignleft")
                    .font(.headline)
                Text(normalizedText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
                    .lineLimit(isExpanded ? nil : 5)
                    .fixedSize(horizontal: false, vertical: true)

                if canExpand {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Label(
                            isExpanded ? "收起" : "展开",
                            systemImage: isExpanded ? "chevron.up" : "chevron.down"
                        )
                        .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, horizontalPadding)
        }
    }
}

struct SeriesFilterButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(isSelected ? .white : .primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(isSelected ? Color.accentColor : Color(.systemGray6))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct SeriesItemEditionBar: View {
    let editions: [ComicEditionInfo]
    let activeComicId: String
    let onSelectEdition: (String) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(editions) { edition in
                    let isSelected = edition.comicId == activeComicId
                    Button {
                        onSelectEdition(edition.comicId)
                    } label: {
                        Text(edition.displayChipLabel)
                            .font(.caption2.weight(isSelected ? .bold : .medium))
                            .foregroundStyle(isSelected ? .white : .primary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(isSelected ? Color.accentColor : Color(.systemGray6))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .scrollIndicators(.hidden)
    }
}

struct SeriesUnitCardView: View {
    let item: SeriesItem
    let serverURL: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                AuthenticatedImage(serverURL: serverURL, comicId: item.comic.id, thumbnail: true)
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .bookCoverSource(id: "comic-\(item.comic.id)")
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(.gray.opacity(0.15), lineWidth: 0.5)
                    )

                if item.comic.progress > 0 {
                    VStack {
                        Spacer()
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(.black.opacity(0.3))
                                Rectangle()
                                    .fill(Color.accentColor)
                                    .frame(width: geo.size.width * CGFloat(item.comic.progress) / 100)
                            }
                        }
                        .frame(height: 3)
                        .clipShape(RoundedRectangle(cornerRadius: 1.5))
                    }
                }

                if !item.formatBadge.isEmpty {
                    Text(item.formatBadge)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.72))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }

                if let status = item.comic.readingStatus, !status.isEmpty {
                    Text(ReadingStatus.label(for: status))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(ReadingStatus.color(for: status).opacity(0.9))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .padding(8)
                }
            }

            Text(item.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .padding(.top, 8)
        }
    }
}

struct SeriesUnitListRowView: View {
    let item: SeriesItem
    let serverURL: String

    var body: some View {
        HStack(spacing: 12) {
            AuthenticatedImage(serverURL: serverURL, comicId: item.comic.id, thumbnail: true)
                .aspectRatio(contentMode: .fill)
                .frame(width: 56, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .bookCoverSource(id: "comic-\(item.comic.id)")

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if !item.formatBadge.isEmpty {
                        Text(item.formatBadge)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .fixedSize()
                    }
                }

                if item.comic.pageCount > 0 {
                    Text("\(item.comic.pageCount) 页 · \(item.comic.progress)%")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if let status = item.comic.readingStatus, !status.isEmpty {
                    Text(ReadingStatus.label(for: status))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(ReadingStatus.color(for: status))
                }
            }

            Spacer()

            if item.comic.progress > 0 {
                Text("\(item.comic.progress)%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

@MainActor
@Observable
final class SeriesDetailViewModel {
    static let unsectionedSectionId = "__unsectioned"

    var detail: SeriesDetailResponse?
    var isLoading = false
    var errorMessage: String?
    var isFavorite = false
    var isUpdatingFavorite = false
    private(set) var selectedEditionIdByItemId: [String: String] = [:]
    private(set) var allItems: [SeriesItem] = []
    private(set) var visibleItems: [SeriesItem] = []
    private(set) var selectedSectionId: String?
    private var allItemIds: [String] = []
    private var allItemIndexById: [String: Int] = [:]
    private var sectionItemsById: [String: [SeriesItem]] = [:]
    private var modelContext: ModelContext?

    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }

    var hasReadingProgress: Bool {
        (detail?.series.completedItemCount ?? 0) > 0
            || allItems.contains { hasStarted($0) || $0.comic.readingStatus == "finished" }
    }

    var downloadableUnits: [GroupComicItem] {
        allItems.map { item in
            let edition = activeEdition(for: item)
            let comicId = edition?.comicId ?? item.comic.id
            let fileSize = edition.flatMap { $0.fileSize > 0 ? $0.fileSize : nil } ?? item.comic.fileSize
            let pageCount = edition.flatMap { $0.pageCount > 0 ? $0.pageCount : nil } ?? item.comic.pageCount
            return GroupComicItem(
                id: comicId,
                filename: edition?.fileLocation?.filename ?? item.comic.filename,
                title: item.title,
                pageCount: pageCount,
                fileSize: fileSize,
                lastReadPage: edition?.lastReadPage ?? item.comic.lastReadPage,
                totalReadTime: edition?.totalReadTime ?? item.comic.totalReadTime,
                coverUrl: item.comic.coverUrl,
                sortIndex: item.sortIndex,
                readingStatus: edition?.readingStatus ?? item.comic.readingStatus,
                lastReadAt: edition?.lastReadAt ?? item.comic.lastReadAt,
                type: item.comic.type
            )
        }
    }

    var downloadableUnitIds: [String] {
        downloadableUnits.map(\.id)
    }

    func toggleFavorite() async {
        let targetIds = allItems.flatMap { item in
            [item.comic.id] + item.resolvedEditions.map(\.comicId)
        }
        guard !targetIds.isEmpty, !isUpdatingFavorite else { return }
        let targetFavorite = !isFavorite
        isUpdatingFavorite = true
        defer { isUpdatingFavorite = false }
        do {
            try await APIClient.shared.batchSetFavorite(comicIds: targetIds, isFavorite: targetFavorite)
            isFavorite = targetFavorite
            syncFavoriteToCache(comicIds: targetIds, isFavorite: targetFavorite)
            APIClient.shared.contentMutationRevision += 1
        } catch {
            AppLogger.error("切换目录作品收藏状态失败: \(error.localizedDescription)")
        }
    }

    func downloadAllVolumes() -> (queued: Int, skipped: Int) {
        if let detail {
            let snapshot = detail
            Task.detached(priority: .utility) {
                OfflineFileManager.shared.saveSeries(snapshot)
            }
        }
        cacheSeriesComics()
        return DownloadManager.shared.downloadAll(comics: downloadableUnits)
    }

    func deleteWholeSeries(
        seriesId: String,
        deleteFiles: Bool,
        deleteEditions: Bool
    ) async throws {
        try await APIClient.shared.deleteSeries(
            seriesId: seriesId,
            deleteContent: true,
            deleteFiles: deleteFiles,
            deleteEditions: deleteEditions
        )
        let editionIds = allItems.flatMap { item in
            [item.comic.id] + item.resolvedEditions.map(\.comicId)
        }
        cleanLocalContentCaches(
            comicIds: editionIds + [seriesId, "series-\(seriesId)"],
            modelContext: modelContext
        )
    }

    var continueItem: SeriesItem? {
        if let inProgress = allItems.first(where: { hasStarted($0) && !isFinished($0) }) {
            return inProgress
        }
        return allItems.first(where: { !isFinished($0) }) ?? allItems.first
    }

    func load(seriesId: String) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil

        if APIClient.shared.isOfflineMode || !APIClient.shared.isNetworkReachable {
            await loadOfflineSeries(seriesId: seriesId)
            isLoading = false
            return
        }

        do {
            let loadedDetail = try await APIClient.shared.fetchSeriesDetail(id: seriesId)
            updateDetail(loadedDetail)
            Task.detached(priority: .utility) {
                OfflineFileManager.shared.saveSeries(loadedDetail)
            }
        } catch {
            if await loadOfflineSeries(seriesId: seriesId) {
                errorMessage = nil
            } else {
                updateDetail(nil)
                errorMessage = error.localizedDescription
            }
        }
        isLoading = false
    }

    func refreshSilently(seriesId: String) async {
        guard !isLoading else { return }
        if APIClient.shared.isOfflineMode || !APIClient.shared.isNetworkReachable {
            _ = await loadOfflineSeries(seriesId: seriesId)
            return
        }
        do {
            let loadedDetail = try await APIClient.shared.fetchSeriesDetail(id: seriesId)
            updateDetail(loadedDetail)
            Task.detached(priority: .utility) {
                OfflineFileManager.shared.saveSeries(loadedDetail)
            }
        } catch {
            // 静默刷新失败保持当前视图数据
        }
    }

    @discardableResult
    private func loadOfflineSeries(seriesId: String) async -> Bool {
        let snapshot = await Task.detached(priority: .utility) {
            (
                series: OfflineFileManager.shared.loadSeriesDetail(seriesId: seriesId),
                completed: OfflineFileManager.shared.completedDownloads()
            )
        }.value
        guard !Task.isCancelled else { return false }

        guard let cachedSeries = snapshot.series else {
            updateDetail(nil)
            errorMessage = "离线模式下无法加载目录作品"
            return false
        }

        var cachedById: [String: CachedComic] = [:]
        if let context = modelContext {
            let allCached = context.fetchOrLog(FetchDescriptor<CachedComic>(), label: "离线加载目录作品")
            for c in allCached { cachedById[c.id] = c }
        }

        func mergeOfflineItem(_ item: SeriesItem) -> SeriesItem? {
            let candidateIds = [activeComicId(for: item), item.comic.id] + item.resolvedEditions.map(\.comicId)
            guard let downloadedId = candidateIds.first(where: { snapshot.completed[$0] != nil }) else {
                return nil
            }
            let cached = cachedById[downloadedId] ?? cachedById[item.comic.id]
            let meta = snapshot.completed[downloadedId]
            let base = item.comic
            let mergedComic = Comic(
                id: downloadedId,
                title: cached?.title ?? base.title,
                author: base.author,
                publisher: base.publisher,
                description: base.description,
                genre: base.genre,
                language: base.language,
                year: base.year,
                pageCount: cached?.pageCount ?? meta?.pageCount ?? base.pageCount,
                fileSize: meta?.fileSize ?? base.fileSize,
                lastReadPage: cached?.lastReadPage ?? base.lastReadPage,
                lastReadPositionRatio: base.lastReadPositionRatio,
                totalReadTime: base.totalReadTime,
                readingStatus: cached?.readingStatus ?? base.readingStatus,
                lastReadAt: cached?.lastReadAt?.iso8601String ?? base.lastReadAt,
                metadataSource: base.metadataSource,
                coverUrl: cached?.coverUrl ?? base.coverUrl,
                coverAspectRatio: base.coverAspectRatio,
                rating: cached?.rating ?? base.rating,
                isFavorite: cached?.isFavorite ?? base.isFavorite,
                type: cached?.type ?? base.type,
                filename: base.filename,
                titleSortKey: base.titleSortKey,
                sortOrder: base.sortOrder,
                libraryId: base.libraryId,
                canManage: false,
                canDownload: false,
                comicCount: base.comicCount,
                relativePath: base.relativePath,
                format: base.format,
                editionLabel: base.editionLabel,
                editionGroupId: base.editionGroupId,
                formats: base.formats,
                editionCount: base.editionCount,
                preferredComicId: base.preferredComicId,
                fileLocation: base.fileLocation,
                editions: base.editions,
                tags: base.tags,
                categories: base.categories
            )
            return SeriesItem(
                comic: mergedComic,
                sectionId: item.sectionId,
                sortIndex: item.sortIndex,
                displayLabel: item.displayLabel,
                format: item.format,
                formats: item.formats,
                editionCount: item.editionCount,
                editions: item.editions
            )
        }

        let offlineSections = cachedSeries.sections.compactMap { section -> SeriesSection? in
            let items = section.items.compactMap(mergeOfflineItem)
            guard !items.isEmpty else { return nil }
            return SeriesSection(
                id: section.id,
                title: section.title,
                relativePath: section.relativePath,
                kind: section.kind,
                seasonNumber: section.seasonNumber,
                sortIndex: section.sortIndex,
                manualLocked: section.manualLocked,
                items: items
            )
        }
        let offlineUnsectioned = cachedSeries.unsectioned.compactMap(mergeOfflineItem)
        let totalOfflineCount = offlineSections.reduce(0) { $0 + $1.items.count } + offlineUnsectioned.count
        guard totalOfflineCount > 0 else {
            updateDetail(nil)
            errorMessage = "离线模式下尚无已缓存的分卷"
            return false
        }

        let offlineDetail = SeriesDetailResponse(
            series: cachedSeries.series,
            sections: offlineSections,
            unsectioned: offlineUnsectioned
        )
        updateDetail(offlineDetail)
        isFavorite = offlineSections.flatMap(\.items).contains(where: { $0.comic.isFavorite })
            || offlineUnsectioned.contains(where: { $0.comic.isFavorite })
            || cachedSeries.series.isFavorite
        return true
    }

    private func cacheSeriesComics() {
        guard let modelContext else { return }
        let existing = modelContext.fetchOrLog(FetchDescriptor<CachedComic>(), label: "缓存系列分卷前查询")
        var byId: [String: CachedComic] = [:]
        for item in existing { byId[item.id] = item }
        for item in allItems {
            let comic = item.comic
            let targetId = activeComicId(for: item)
            if let existingCached = byId[targetId] {
                existingCached.title = comic.title
                existingCached.author = comic.author
                existingCached.coverUrl = comic.coverUrl
                existingCached.pageCount = max(existingCached.pageCount, comic.pageCount)
                existingCached.lastReadPage = max(existingCached.lastReadPage, comic.lastReadPage)
                existingCached.isFavorite = existingCached.isFavorite || comic.isFavorite
                existingCached.readingStatus = comic.readingStatus ?? existingCached.readingStatus
                existingCached.type = comic.type
                existingCached.cachedAt = Date()
            } else {
                let c = CachedComic.from(comic)
                c.id = targetId
                modelContext.insert(c)
                byId[targetId] = c
            }
        }
        modelContext.saveOrLog()
    }

    private func syncFavoriteToCache(comicIds: [String], isFavorite: Bool) {
        guard let modelContext else { return }
        let targetSet = Set(comicIds)
        let cached = modelContext.fetchOrLog(FetchDescriptor<CachedComic>(), label: "同步系列收藏状态")
        var changed = false
        for item in cached where targetSet.contains(item.id) {
            item.isFavorite = isFavorite
            changed = true
        }
        if changed { modelContext.saveOrLog() }
    }

    func activeEdition(for item: SeriesItem) -> ComicEditionInfo? {
        let editions = item.resolvedEditions
        guard !editions.isEmpty else { return nil }
        if let selectedId = selectedEditionIdByItemId[item.id],
           let matched = editions.first(where: { $0.comicId == selectedId }) {
            return matched
        }
        return editions.first(where: { $0.isCurrent || $0.isPreferred }) ?? editions.first
    }

    func activeComicId(for item: SeriesItem) -> String {
        activeEdition(for: item)?.comicId ?? item.comic.id
    }

    func switchEdition(itemId: String, to targetComicId: String) {
        selectedEditionIdByItemId[itemId] = targetComicId
    }

    func readingContext(for item: SeriesItem) -> ReadingGroupContext? {
        guard let index = allItemIndexById[item.comic.id] else { return nil }
        return ReadingGroupContext(groupId: 0, volumeIds: allItemIds, currentIndex: index)
    }

    func selectSection(_ sectionId: String?) {
        selectedSectionId = sectionId
        guard let sectionId else {
            visibleItems = allItems
            return
        }
        visibleItems = sectionItemsById[sectionId] ?? []
    }

    private func updateDetail(_ newDetail: SeriesDetailResponse?) {
        detail = newDetail
        isFavorite = newDetail?.series.isFavorite ?? false
        guard let newDetail else {
            allItems = []
            visibleItems = []
            selectedSectionId = nil
            sectionItemsById = [:]
            allItemIds = []
            allItemIndexById = [:]
            return
        }

        let unsectioned = newDetail.unsectioned.sorted { $0.sortIndex < $1.sortIndex }
        let sortedSectionItems = newDetail.sections.map { section in
            (section.id, section.items.sorted { $0.sortIndex < $1.sortIndex })
        }
        sectionItemsById = Dictionary(
            uniqueKeysWithValues: sortedSectionItems
        )
        sectionItemsById[Self.unsectionedSectionId] = unsectioned
        allItems = (unsectioned + sortedSectionItems.flatMap(\.1))
            .sorted { $0.sortIndex < $1.sortIndex }
        selectedSectionId = nil
        visibleItems = allItems
        allItemIds = allItems.map { $0.comic.id }
        allItemIndexById = [:]
        for (index, comicId) in allItemIds.enumerated()
        where allItemIndexById[comicId] == nil {
            allItemIndexById[comicId] = index
        }
    }

    private func isFinished(_ item: SeriesItem) -> Bool {
        if item.comic.readingStatus == "finished" { return true }
        guard hasStarted(item), item.comic.pageCount > 0 else { return false }
        return item.comic.lastReadPage >= item.comic.pageCount - 1
    }

    private func hasStarted(_ item: SeriesItem) -> Bool {
        item.comic.lastReadPage > 0 || item.comic.readingStatus == "reading"
    }
}
