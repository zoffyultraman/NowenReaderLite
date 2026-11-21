import SwiftUI
import SwiftData

struct GroupDetailView: View {
    let groupId: Int
    let contentType: String?
    @State private var viewModel = GroupDetailViewModel()
    @Environment(\.modelContext) private var modelContext
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
        @Bindable var viewModel = viewModel
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

                        WorkMetadataSection(tags: detail.tagItems, categories: detail.categories)
                            .padding(.horizontal, 20)

                        WorkDescriptionSection(text: detail.description)

                        if !readingUnits.isEmpty && !api.isOfflineMode {
                            GroupEditionsAndLocationSection(
                                readingUnits: readingUnits,
                                selectedUnitId: viewModel.selectedUnitId,
                                selectedComic: viewModel.selectedUnitComic,
                                isLoadingUnit: viewModel.isLoadingSelectedUnit,
                                isSwitchingEdition: viewModel.isSwitchingEdition,
                                exportingComicId: viewModel.exportingComicId,
                                onSelectUnit: { unitId in
                                    Task { await viewModel.selectUnit(comicId: unitId) }
                                },
                                onSwitchEdition: { targetId in
                                    Task { await viewModel.switchEdition(to: targetId) }
                                },
                                onExportOriginalFile: { comicId, downloadPath, preferredFilename in
                                    Task {
                                        await viewModel.exportOriginalFile(
                                            comicId: comicId,
                                            downloadPath: downloadPath,
                                            preferredFilename: preferredFilename
                                        )
                                    }
                                }
                            )
                        }
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
        .task {
            DownloadManager.shared.setModelContext(modelContext)
            await viewModel.load(groupId: groupId, contentType: contentType, context: modelContext)
        }
        .alert("下载全部卷", isPresented: $showDownloadAllAlert) {
            Button("取消", role: .cancel) {}
            Button("下载") {
                guard let detail = viewModel.detail else { return }
                let result = DownloadManager.shared.downloadAll(comics: detail.readingUnits, groupDetail: detail)
                downloadQueued = result.queued
                downloadSkipped = result.skipped
                showDownloadResult = true
            }
        } message: {
            if let detail = viewModel.detail {
                let units = detail.readingUnits
                let totalPages = units.reduce(0) { $0 + $1.pageCount }
                let alreadyDownloaded = units.filter { DownloadManager.shared.isDownloaded(comicId: $0.id) }.count
                Text("共 \(units.count) 个阅读单元、\(totalPages) 页。已下载 \(alreadyDownloaded) 个，其余将加入下载队列。")
            }
        }
        .alert("下载结果", isPresented: $showDownloadResult) {
            Button("确定") {}
        } message: {
            Text("已加入 \(downloadQueued) 卷到下载队列，跳过 \(downloadSkipped) 卷（已下载或空间不足）。")
        }
        .alert("操作未完成", isPresented: $viewModel.isActionErrorPresented) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(viewModel.actionErrorMessage ?? "请稍后重试。")
        }
        .sheet(item: $viewModel.exportedFileItem) { item in
            OriginalFileShareSheet(fileURL: item.url)
        }
    }

}

struct GroupEditionsAndLocationSection: View {
    let readingUnits: [GroupComicItem]
    let selectedUnitId: String?
    let selectedComic: Comic?
    let isLoadingUnit: Bool
    let isSwitchingEdition: Bool
    let exportingComicId: String?
    let onSelectUnit: (String) -> Void
    let onSwitchEdition: (String) -> Void
    let onExportOriginalFile: (String, String?, String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if readingUnits.count > 1 {
                VStack(alignment: .leading, spacing: 8) {
                    Label("版本与文件位置", systemImage: "square.stack.3d.up")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)

                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(readingUnits) { unit in
                                let isSelected = unit.id == selectedUnitId
                                Button {
                                    onSelectUnit(unit.id)
                                } label: {
                                    HStack(spacing: 5) {
                                        Text(unit.title)
                                            .lineLimit(1)
                                        if !unit.formatBadge.isEmpty {
                                            Text(unit.formatBadge)
                                                .font(.caption2.weight(.bold))
                                                .opacity(0.85)
                                        }
                                    }
                                    .font(.caption.weight(isSelected ? .semibold : .regular))
                                    .foregroundStyle(isSelected ? .white : .primary)
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 6)
                                    .background(isSelected ? Color.accentColor : Color(.systemGray6))
                                    .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                    .scrollIndicators(.hidden)
                }
            }

            if isLoadingUnit && selectedComic == nil {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在加载版本与文件位置…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
            } else if let comic = selectedComic {
                ComicEditionsSection(
                    activeComicId: comic.id,
                    editions: comic.resolvedEditions,
                    isNovelLibrary: comic.isNovel,
                    isSwitchingEdition: isSwitchingEdition,
                    exportingComicId: exportingComicId,
                    onSelectEdition: onSwitchEdition,
                    onExportEdition: { edition in
                        onExportOriginalFile(
                            edition.comicId,
                            edition.downloadUrl,
                            edition.fileLocation?.filename
                        )
                    }
                )

                ComicFileLocationSection(
                    comicId: comic.id,
                    filename: comic.filename,
                    relativePath: comic.relativePath,
                    formatBadge: comic.formatBadge,
                    fileLocation: comic.fileLocation,
                    canDownload: comic.canDownloadOriginalFile,
                    isImageFolder: comic.isImageFolder,
                    isExporting: exportingComicId == comic.id,
                    onExportOriginalFile: {
                        onExportOriginalFile(
                            comic.id,
                            nil,
                            comic.fileLocation?.filename ?? comic.filename
                        )
                    }
                )
            }
        }
        .padding(.top, 4)
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
    var selectedUnitId: String?
    var selectedUnitComic: Comic?
    var isLoadingSelectedUnit = false
    var isSwitchingEdition = false
    var exportingComicId: String?
    var exportedFileItem: ExportedOriginalFileItem?
    var actionErrorMessage: String?
    var isActionErrorPresented = false
    private var readingUnitIds: [String] = []
    private var readingUnitIndexById: [String: Int] = [:]
    private var unitLoadVersion = 0

    func load(groupId: Int, contentType: String? = nil, context: ModelContext? = nil) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil

        // 离线：从本地加载合集
        if APIClient.shared.isOfflineMode || !APIClient.shared.isNetworkReachable {
            let offlineSnapshot = await Task.detached(priority: .utility) {
                OfflineGroupDetailLoadSnapshot(
                    group: OfflineFileManager.shared.loadGroupDetail(groupId: groupId),
                    completedMetas: OfflineFileManager.shared.completedDownloads()
                )
            }.value
            guard !Task.isCancelled else {
                isLoading = false
                return
            }
            if let local = offlineSnapshot.group {
                var comics: [GroupComicItem] = []
                let localComicIds = Set(local.comicIds)
                // 尝试从 SwiftData 缓存获取更完整的信息
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
                        readingStatus: nil,
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
            } else {
                updateDetail(nil)
                errorMessage = "离线模式下无法加载合集"
            }
            isLoading = false
            return
        }

        do {
            let loadedDetail = try await APIClient.shared.fetchGroupDetail(id: groupId, contentType: contentType)
            updateDetail(loadedDetail)
            if let initialUnitId = selectedUnitId ?? loadedDetail.readingUnits.first?.id {
                await selectUnit(comicId: initialUnitId)
            }
        } catch {
            updateDetail(nil)
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func selectUnit(comicId: String) async {
        selectedUnitId = comicId
        guard !APIClient.shared.isOfflineMode, APIClient.shared.isNetworkReachable else {
            selectedUnitComic = nil
            isLoadingSelectedUnit = false
            return
        }
        unitLoadVersion += 1
        let version = unitLoadVersion
        isLoadingSelectedUnit = true
        defer {
            if version == unitLoadVersion {
                isLoadingSelectedUnit = false
            }
        }
        do {
            let loaded = try await APIClient.shared.fetchComic(id: comicId)
            guard !Task.isCancelled, version == unitLoadVersion else { return }
            selectedUnitComic = loaded
        } catch {
            guard !Task.isCancelled, version == unitLoadVersion else { return }
            AppLogger.error("加载合集分卷详情失败: \(error)")
        }
    }

    func switchEdition(to targetComicId: String) async {
        guard targetComicId != selectedUnitComic?.id, !isSwitchingEdition else { return }
        unitLoadVersion += 1
        let version = unitLoadVersion
        isSwitchingEdition = true
        defer { isSwitchingEdition = false }
        do {
            let loaded = try await APIClient.shared.fetchComic(id: targetComicId)
            guard !Task.isCancelled, version == unitLoadVersion else { return }
            selectedUnitComic = loaded
        } catch {
            guard !Task.isCancelled else { return }
            actionErrorMessage = "切换格式版本失败：\(error.localizedDescription)"
            isActionErrorPresented = true
        }
    }

    func exportOriginalFile(
        comicId: String,
        downloadPath: String? = nil,
        preferredFilename: String? = nil
    ) async {
        guard exportingComicId == nil else { return }
        exportingComicId = comicId
        defer { exportingComicId = nil }
        do {
            let fileURL = try await APIClient.shared.downloadOriginalComicFile(
                comicId: comicId,
                downloadPath: downloadPath,
                preferredFilename: preferredFilename
            )
            exportedFileItem = ExportedOriginalFileItem(url: fileURL)
        } catch {
            guard !Task.isCancelled else { return }
            actionErrorMessage = "下载原文件失败：\(error.localizedDescription)"
            isActionErrorPresented = true
        }
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
        if let current = selectedUnitId, readingUnitIndexById[current] != nil {
            // keep current selection
        } else {
            selectedUnitId = readingUnitIds.first
            selectedUnitComic = nil
        }
    }
}

// MARK: - 目录作品详情

struct SeriesDetailView: View {
    let seriesId: String
    @State private var viewModel = SeriesDetailViewModel()
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(APIClient.self) private var api
    @State private var isGrid = true

    var body: some View {
        @Bindable var viewModel = viewModel
        Group {
            if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let detail = viewModel.detail {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        SeriesHeaderView(
                            series: detail.series,
                            continueItem: viewModel.continueItem,
                            serverURL: api.serverURL,
                            contextProvider: { viewModel.readingContext(for: $0) }
                        )
                        .padding(.horizontal, 20)
                        .padding(.top, 12)

                        if !viewModel.allItems.isEmpty && !api.isOfflineMode {
                            SeriesEditionsAndLocationSection(
                                items: viewModel.allItems,
                                focusedItem: viewModel.focusedItem,
                                selectedComic: viewModel.selectedUnitComic,
                                activeEdition: viewModel.focusedItem.flatMap { viewModel.activeEdition(for: $0) },
                                isLoadingUnit: viewModel.isLoadingSelectedUnit,
                                isSwitchingEdition: viewModel.isSwitchingEdition,
                                exportingComicId: viewModel.exportingComicId,
                                onSelectItem: { itemId in
                                    Task { await viewModel.selectFocusItem(id: itemId) }
                                },
                                onSelectEdition: { itemId, editionComicId in
                                    Task { await viewModel.switchEdition(itemId: itemId, to: editionComicId) }
                                },
                                onExportOriginalFile: { comicId, downloadPath, preferredFilename in
                                    Task {
                                        await viewModel.exportOriginalFile(
                                            comicId: comicId,
                                            downloadPath: downloadPath,
                                            preferredFilename: preferredFilename
                                        )
                                    }
                                }
                            )
                        }

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
                                                isNovelLibrary: item.comic.isNovel,
                                                exportingComicId: viewModel.exportingComicId,
                                                onSelectEdition: { editionComicId in
                                                    Task {
                                                        await viewModel.switchEdition(itemId: item.id, to: editionComicId)
                                                    }
                                                },
                                                onExportEdition: { edition in
                                                    Task {
                                                        await viewModel.exportOriginalFile(
                                                            comicId: edition.comicId,
                                                            downloadPath: edition.downloadUrl,
                                                            preferredFilename: edition.fileLocation?.filename
                                                        )
                                                    }
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
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation { isGrid.toggle() }
                } label: {
                    Image(systemName: isGrid ? "list.bullet" : "square.grid.2x2")
                }
            }
        }
        .alert("操作未完成", isPresented: $viewModel.isActionErrorPresented) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(viewModel.actionErrorMessage ?? "请稍后重试。")
        }
        .sheet(item: $viewModel.exportedFileItem) { item in
            OriginalFileShareSheet(fileURL: item.url)
        }
        .task {
            await viewModel.load(seriesId: seriesId)
        }
    }
}

struct SeriesHeaderView: View {
    let series: SeriesSummary
    let continueItem: SeriesItem?
    let serverURL: String
    let contextProvider: (SeriesItem) -> ReadingGroupContext?

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

            if let continueItem {
                NavigationLink {
                    continueItem.comic.readerView(groupContext: contextProvider(continueItem))
                        .bookCoverDestination(id: "series-reader-\(series.id)")
                } label: {
                    let hasStarted = continueItem.comic.lastReadPage > 0 || continueItem.comic.readingStatus == "reading"
                    Label(hasStarted ? "继续阅读" : "开始阅读", systemImage: "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
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

            WorkMetadataSection(tags: series.tags, categories: series.categories)

            WorkDescriptionSection(text: series.description, horizontalPadding: 0)
        }
    }
}

struct WorkMetadataSection: View {
    let tags: [TagItem]?
    let categories: [CategoryItem]?

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

struct SeriesEditionsAndLocationSection: View {
    let items: [SeriesItem]
    let focusedItem: SeriesItem?
    let selectedComic: Comic?
    let activeEdition: ComicEditionInfo?
    let isLoadingUnit: Bool
    let isSwitchingEdition: Bool
    let exportingComicId: String?
    let onSelectItem: (String) -> Void
    let onSelectEdition: (String, String) -> Void
    let onExportOriginalFile: (String, String?, String?) -> Void

    private var displayedEditions: [ComicEditionInfo] {
        if let comicEditions = selectedComic?.resolvedEditions, !comicEditions.isEmpty {
            return comicEditions
        }
        return focusedItem?.resolvedEditions ?? []
    }

    private var activeComicId: String {
        selectedComic?.id ?? activeEdition?.comicId ?? focusedItem?.comic.id ?? ""
    }

    private var displayedLocation: ComicFileLocation? {
        selectedComic?.fileLocation ?? activeEdition?.fileLocation ?? focusedItem?.comic.fileLocation
    }

    private var canDownloadActive: Bool {
        if let selectedComic {
            return selectedComic.canDownloadOriginalFile
        }
        if let activeEdition {
            return activeEdition.canDownloadOriginalFile
        }
        return focusedItem?.comic.canDownloadOriginalFile ?? false
    }

    private var activeIsImageFolder: Bool {
        selectedComic?.isImageFolder ?? activeEdition?.isImageFolder ?? focusedItem?.comic.isImageFolder ?? false
    }

    private var activeIsNovel: Bool {
        selectedComic?.isNovel ?? focusedItem?.comic.isNovel ?? false
    }

    private var activeFormatBadge: String {
        selectedComic?.formatBadge ?? activeEdition?.displayFormat ?? focusedItem?.formatBadge ?? ""
    }

    private var activeFilename: String? {
        selectedComic?.filename ?? activeEdition?.fileLocation?.filename ?? focusedItem?.comic.filename
    }

    private var activeRelativePath: String? {
        selectedComic?.relativePath ?? activeEdition?.fileLocation?.relativePath ?? focusedItem?.comic.relativePath
    }

    var body: some View {
        if focusedItem != nil || selectedComic != nil {
            VStack(alignment: .leading, spacing: 12) {
                if items.count > 1 {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("版本与文件位置", systemImage: "square.stack.3d.up")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 20)

                        ScrollView(.horizontal) {
                            HStack(spacing: 8) {
                                ForEach(items) { item in
                                    let isSelected = item.id == focusedItem?.id
                                    Button {
                                        onSelectItem(item.id)
                                    } label: {
                                        HStack(spacing: 5) {
                                            Text(item.title)
                                                .lineLimit(1)
                                            if !item.formatBadge.isEmpty {
                                                Text(item.formatBadge)
                                                    .font(.caption2.weight(.bold))
                                                    .opacity(0.85)
                                            }
                                        }
                                        .font(.caption.weight(isSelected ? .semibold : .regular))
                                        .foregroundStyle(isSelected ? .white : .primary)
                                        .padding(.horizontal, 11)
                                        .padding(.vertical, 6)
                                        .background(isSelected ? Color.accentColor : Color(.systemGray6))
                                        .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                        .scrollIndicators(.hidden)
                    }
                }

                if isLoadingUnit && selectedComic == nil && displayedEditions.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在加载版本与文件位置…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 20)
                } else {
                    if let itemId = focusedItem?.id {
                        ComicEditionsSection(
                            activeComicId: activeComicId,
                            editions: displayedEditions,
                            isNovelLibrary: activeIsNovel,
                            isSwitchingEdition: isSwitchingEdition,
                            exportingComicId: exportingComicId,
                            onSelectEdition: { targetComicId in
                                onSelectEdition(itemId, targetComicId)
                            },
                            onExportEdition: { edition in
                                onExportOriginalFile(
                                    edition.comicId,
                                    edition.downloadUrl,
                                    edition.fileLocation?.filename
                                )
                            }
                        )
                    }

                    if !activeComicId.isEmpty {
                        ComicFileLocationSection(
                            comicId: activeComicId,
                            filename: activeFilename,
                            relativePath: activeRelativePath,
                            formatBadge: activeFormatBadge,
                            fileLocation: displayedLocation,
                            canDownload: canDownloadActive,
                            isImageFolder: activeIsImageFolder,
                            isExporting: exportingComicId == activeComicId,
                            onExportOriginalFile: {
                                onExportOriginalFile(
                                    activeComicId,
                                    activeEdition?.downloadUrl,
                                    displayedLocation?.filename ?? activeFilename
                                )
                            }
                        )
                    }
                }
            }
        }
    }
}

struct SeriesItemEditionBar: View {
    let editions: [ComicEditionInfo]
    let activeComicId: String
    let isNovelLibrary: Bool
    let exportingComicId: String?
    let onSelectEdition: (String) -> Void
    let onExportEdition: (ComicEditionInfo) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(editions) { edition in
                    let isSelected = edition.comicId == activeComicId
                    HStack(spacing: 4) {
                        Button {
                            onSelectEdition(edition.comicId)
                        } label: {
                            Text(edition.displayChipLabel)
                                .font(.caption2.weight(isSelected ? .bold : .medium))
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            edition.readerView(isNovelLibrary: isNovelLibrary)
                                .bookCoverDestination(id: "reader-\(edition.comicId)")
                        } label: {
                            Image(systemName: "book")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("以 \(edition.displayFormat) 格式阅读")

                        if edition.canDownloadOriginalFile {
                            Button {
                                onExportEdition(edition)
                            } label: {
                                if exportingComicId == edition.comicId {
                                    ProgressView()
                                        .controlSize(.mini)
                                } else {
                                    Image(systemName: "arrow.down.doc")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(exportingComicId == edition.comicId)
                            .accessibilityLabel("下载 \(edition.displayFormat) 原文件")
                        }
                    }
                    .foregroundStyle(isSelected ? .white : .primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(isSelected ? Color.accentColor : Color(.systemGray6))
                    .clipShape(Capsule())
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
    var focusedItemId: String?
    var selectedUnitComic: Comic?
    var isLoadingSelectedUnit = false
    var isSwitchingEdition = false
    var exportingComicId: String?
    var exportedFileItem: ExportedOriginalFileItem?
    var actionErrorMessage: String?
    var isActionErrorPresented = false
    private(set) var selectedEditionIdByItemId: [String: String] = [:]
    private(set) var allItems: [SeriesItem] = []
    private(set) var visibleItems: [SeriesItem] = []
    private(set) var selectedSectionId: String?
    private var allItemIds: [String] = []
    private var allItemIndexById: [String: Int] = [:]
    private var sectionItemsById: [String: [SeriesItem]] = [:]
    private var unitLoadVersion = 0

    var focusedItem: SeriesItem? {
        if let focusedItemId, let matched = allItems.first(where: { $0.id == focusedItemId }) {
            return matched
        }
        return continueItem ?? allItems.first
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
        do {
            let loadedDetail = try await APIClient.shared.fetchSeriesDetail(id: seriesId)
            updateDetail(loadedDetail)
            if let initialId = focusedItem?.id {
                await selectFocusItem(id: initialId)
            }
        } catch {
            updateDetail(nil)
            errorMessage = error.localizedDescription
        }
        isLoading = false
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

    func selectFocusItem(id itemId: String) async {
        focusedItemId = itemId
        guard let item = allItems.first(where: { $0.id == itemId }) else { return }
        let targetComicId = activeComicId(for: item)
        await fetchFocusedComic(comicId: targetComicId)
    }

    func switchEdition(itemId: String, to targetComicId: String) async {
        selectedEditionIdByItemId[itemId] = targetComicId
        if focusedItem?.id == itemId {
            guard targetComicId != selectedUnitComic?.id, !isSwitchingEdition else { return }
            isSwitchingEdition = true
            defer { isSwitchingEdition = false }
            await fetchFocusedComic(comicId: targetComicId)
        }
    }

    private func fetchFocusedComic(comicId: String) async {
        guard !APIClient.shared.isOfflineMode, APIClient.shared.isNetworkReachable else {
            selectedUnitComic = nil
            isLoadingSelectedUnit = false
            return
        }
        unitLoadVersion += 1
        let version = unitLoadVersion
        isLoadingSelectedUnit = true
        defer {
            if version == unitLoadVersion {
                isLoadingSelectedUnit = false
            }
        }
        do {
            let loaded = try await APIClient.shared.fetchComic(id: comicId)
            guard !Task.isCancelled, version == unitLoadVersion else { return }
            selectedUnitComic = loaded
        } catch {
            guard !Task.isCancelled, version == unitLoadVersion else { return }
            AppLogger.error("加载目录作品分卷详情失败: \(error)")
        }
    }

    func exportOriginalFile(
        comicId: String,
        downloadPath: String? = nil,
        preferredFilename: String? = nil
    ) async {
        guard exportingComicId == nil else { return }
        exportingComicId = comicId
        defer { exportingComicId = nil }
        do {
            let fileURL = try await APIClient.shared.downloadOriginalComicFile(
                comicId: comicId,
                downloadPath: downloadPath,
                preferredFilename: preferredFilename
            )
            exportedFileItem = ExportedOriginalFileItem(url: fileURL)
        } catch {
            guard !Task.isCancelled else { return }
            actionErrorMessage = "下载原文件失败：\(error.localizedDescription)"
            isActionErrorPresented = true
        }
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
        guard let newDetail else {
            allItems = []
            visibleItems = []
            selectedSectionId = nil
            sectionItemsById = [:]
            allItemIds = []
            allItemIndexById = [:]
            focusedItemId = nil
            selectedUnitComic = nil
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
        if let current = focusedItemId, allItems.contains(where: { $0.id == current }) {
            // keep selection
        } else {
            focusedItemId = continueItem?.id ?? allItems.first?.id
            selectedUnitComic = nil
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
