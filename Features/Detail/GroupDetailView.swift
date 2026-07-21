import SwiftUI
import SwiftData

struct GroupDetailView: View {
    let groupId: Int
    @State private var viewModel = GroupDetailViewModel()
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.modelContext) private var modelContext
    @Environment(APIClient.self) private var api
    @State private var isGrid = true
    @State private var showDownloadAllAlert = false
    @State private var showDownloadResult = false
    @State private var downloadQueued = 0
    @State private var downloadSkipped = 0

    var body: some View {
        Group {
            if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let detail = viewModel.detail {
                ScrollView {
                    // 头部信息
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 16) {
                            // 封面固定宽度，左对齐
                            Group {
                                if let cover = detail.coverUrl, !cover.isEmpty {
                                    let urlString = cover.hasPrefix("http") ? cover : "\(api.serverURL)\(cover)"
                                    if let url = URL(string: urlString) {
                                        AuthenticatedImage(url: url)
                                    }
                                } else if let first = detail.comics.first {
                                    AuthenticatedImage(
                                        serverURL: api.serverURL,
                                        comicId: first.id,
                                        thumbnail: true
                                    )
                                } else {
                                    Color(.systemGray6)
                                }
                            }
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 110, height: 155)
                            .clipShape(RoundedRectangle(cornerRadius: 10))

                            // 右侧信息
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

                                let totalPages = detail.comics.reduce(0) { $0 + $1.pageCount }
                                let totalSize = detail.comics.reduce(Int64(0)) { $0 + ($1.fileSize ?? 0) }

                                VStack(alignment: .leading, spacing: 5) {
                                    Label("\(detail.comics.count) 卷", systemImage: "books.vertical")
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
                    }

                    // 卷列表
                    let volumeIds = detail.comics.map { $0.id }
                    if isGrid {
                        let cols = Array(repeating: GridItem(.flexible(), spacing: 12), count: sizeClass == .regular ? 5 : 3)
                        LazyVGrid(columns: cols, spacing: 16) {
                            ForEach(Array(detail.comics.enumerated()), id: \.element.id) { index, comic in
                                NavigationLink {
                                    ComicDetailView(
                                        comicId: comic.id,
                                        groupContext: ReadingGroupContext(
                                            groupId: viewModel.detail?.id ?? groupId,
                                            volumeIds: volumeIds,
                                            currentIndex: index
                                        )
                                    )
                                } label: {
                                    VolumeCardView(comic: comic, serverURL: api.serverURL)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 20)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(detail.comics.enumerated()), id: \.element.id) { index, comic in
                                NavigationLink {
                                    ComicDetailView(
                                        comicId: comic.id,
                                        groupContext: ReadingGroupContext(
                                            groupId: viewModel.detail?.id ?? groupId,
                                            volumeIds: volumeIds,
                                            currentIndex: index
                                        )
                                    )
                                } label: {
                                    VolumeListRowView(comic: comic, serverURL: api.serverURL)
                                        .padding(.horizontal, 20)
                                }
                                .buttonStyle(.plain)
                                .contentShape(Rectangle())
                                Divider().padding(.leading, 80)
                            }
                        }
                        .padding(.top, 8)
                    }
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
        .navigationTitle(viewModel.detail?.name ?? "合集")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                // 下载全部按钮
                if let detail = viewModel.detail, !detail.comics.isEmpty {
                    Button {
                        showDownloadAllAlert = true
                    } label: {
                        Image(systemName: "arrow.down.circle")
                    }
                }

                Button {
                    withAnimation { isGrid.toggle() }
                } label: {
                    Image(systemName: isGrid ? "list.bullet" : "square.grid.2x2")
                }
            }
        }
        .task {
            DownloadManager.shared.setModelContext(modelContext)
            await viewModel.load(groupId: groupId, context: modelContext)
        }
        .alert("下载全部卷", isPresented: $showDownloadAllAlert) {
            Button("取消", role: .cancel) {}
            Button("下载") {
                guard let detail = viewModel.detail else { return }
                let result = DownloadManager.shared.downloadAll(comics: detail.comics, groupDetail: detail)
                downloadQueued = result.queued
                downloadSkipped = result.skipped
                showDownloadResult = true
            }
        } message: {
            if let detail = viewModel.detail {
                let totalPages = detail.comics.reduce(0) { $0 + $1.pageCount }
                let alreadyDownloaded = detail.comics.filter { DownloadManager.shared.isDownloaded(comicId: $0.id) }.count
                Text("共 \(detail.comics.count) 卷、\(totalPages) 页。已下载 \(alreadyDownloaded) 卷，其余将加入下载队列。")
            }
        }
        .alert("下载结果", isPresented: $showDownloadResult) {
            Button("确定") {}
        } message: {
            Text("已加入 \(downloadQueued) 卷到下载队列，跳过 \(downloadSkipped) 卷（已下载或空间不足）。")
        }
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
                    .frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
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
            }

            Text(comic.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .padding(.top, 8)
        }
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

            VStack(alignment: .leading, spacing: 4) {
                Text(comic.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

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

@MainActor
@Observable
final class GroupDetailViewModel {
    var detail: GroupDetailResponse?
    var isLoading = false
    var errorMessage: String?

    func load(groupId: Int, context: ModelContext? = nil) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil

        // 离线：从本地加载合集
        if APIClient.shared.isOfflineMode || !APIClient.shared.isNetworkReachable {
            if let local = OfflineFileManager.shared.loadGroupDetail(groupId: groupId) {
                let downloadedIds = Set(OfflineFileManager.shared.downloadedComicIds)
                var comics: [GroupComicItem] = []
                // 尝试从 SwiftData 缓存获取更完整的信息
                var cachedMap: [String: CachedComic] = [:]
                if let context {
                    let allCached = try? context.fetch(FetchDescriptor<CachedComic>())
                    if let allCached {
                        for c in allCached where local.comicIds.contains(c.id) {
                            cachedMap[c.id] = c
                        }
                    }
                }
                for (index, comicId) in local.comicIds.enumerated() {
                    guard downloadedIds.contains(comicId) else { continue }
                    let cached = cachedMap[comicId]
                    let meta = OfflineFileManager.shared.loadMeta(comicId: comicId)
                    comics.append(GroupComicItem(
                        id: comicId,
                        filename: nil,
                        title: cached?.title ?? meta?.title ?? comicId,
                        pageCount: cached?.pageCount ?? meta?.pageCount ?? 0,
                        fileSize: meta?.fileSize,
                        lastReadPage: cached?.lastReadPage ?? 0,
                        totalReadTime: nil,
                        coverUrl: cached?.coverUrl,
                        sortIndex: index,
                        readingStatus: nil
                    ))
                }
                detail = GroupDetailResponse(
                    id: local.id,
                    name: local.name,
                    coverUrl: local.coverUrl,
                    author: local.author,
                    description: local.description,
                    comics: comics
                )
            } else {
                errorMessage = "离线模式下无法加载合集"
            }
            isLoading = false
            return
        }

        do {
            detail = try await APIClient.shared.fetchGroupDetail(id: groupId)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - 目录作品详情

struct SeriesDetailView: View {
    let seriesId: String
    @State private var viewModel = SeriesDetailViewModel()
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(APIClient.self) private var api
    @State private var isGrid = true
    @State private var selectedSectionId: String?

    private static let unsectionedSectionId = "__unsectioned"

    private var visibleItems: [SeriesItem] {
        guard let detail = viewModel.detail else { return [] }
        guard let selectedSectionId else { return viewModel.allItems }
        if selectedSectionId == Self.unsectionedSectionId {
            return detail.unsectioned.sorted { $0.sortIndex < $1.sortIndex }
        }
        return detail.sections
            .first { $0.id == selectedSectionId }?
            .items
            .sorted { $0.sortIndex < $1.sortIndex } ?? []
    }

    var body: some View {
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

                        if !detail.sections.isEmpty || !detail.unsectioned.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    SeriesFilterButton(
                                        title: "全部 \(viewModel.allItems.count)",
                                        isSelected: selectedSectionId == nil
                                    ) {
                                        selectedSectionId = nil
                                    }

                                    if !detail.unsectioned.isEmpty {
                                        SeriesFilterButton(
                                            title: "未分季 \(detail.unsectioned.count)",
                                            isSelected: selectedSectionId == Self.unsectionedSectionId
                                        ) {
                                            selectedSectionId = Self.unsectionedSectionId
                                        }
                                    }

                                    ForEach(detail.sections) { section in
                                        SeriesFilterButton(
                                            title: "\(section.title) \(section.items.count)",
                                            isSelected: selectedSectionId == section.id
                                        ) {
                                            selectedSectionId = section.id
                                        }
                                    }
                                }
                                .padding(.horizontal, 20)
                            }
                        }

                        if isGrid {
                            let cols = Array(repeating: GridItem(.flexible(), spacing: 12), count: sizeClass == .regular ? 5 : 3)
                            LazyVGrid(columns: cols, spacing: 16) {
                                ForEach(visibleItems) { item in
                                    NavigationLink {
                                        ComicDetailView(
                                            comicId: item.comic.id,
                                            groupContext: viewModel.readingContext(for: item)
                                        )
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
                                ForEach(visibleItems) { item in
                                    NavigationLink {
                                        ComicDetailView(
                                            comicId: item.comic.id,
                                            groupContext: viewModel.readingContext(for: item)
                                        )
                                    } label: {
                                        SeriesUnitListRowView(item: item, serverURL: api.serverURL)
                                            .padding(.horizontal, 20)
                                    }
                                    .buttonStyle(.plain)
                                    .contentShape(Rectangle())
                                    Divider().padding(.leading, 80)
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
        .navigationTitle(viewModel.detail?.series.title ?? "目录作品")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation { isGrid.toggle() }
                } label: {
                    Image(systemName: isGrid ? "list.bullet" : "square.grid.2x2")
                }
            }
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

                VStack(alignment: .leading, spacing: 10) {
                    Text(series.title)
                        .font(.title3.weight(.bold))
                        .lineLimit(2)

                    if !series.rootRelativePath.isEmpty {
                        Text(series.rootRelativePath)
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
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let continueItem {
                NavigationLink {
                    continueItem.comic.readerView(groupContext: contextProvider(continueItem))
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

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

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
    var detail: SeriesDetailResponse?
    var isLoading = false
    var errorMessage: String?

    var allItems: [SeriesItem] {
        guard let detail else { return [] }
        return (detail.unsectioned + detail.sections.flatMap { $0.items })
            .sorted { $0.sortIndex < $1.sortIndex }
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
            detail = try await APIClient.shared.fetchSeriesDetail(id: seriesId)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func readingContext(for item: SeriesItem) -> ReadingGroupContext? {
        let ids = allItems.map { $0.comic.id }
        guard let index = ids.firstIndex(of: item.comic.id) else { return nil }
        return ReadingGroupContext(groupId: 0, volumeIds: ids, currentIndex: index)
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
