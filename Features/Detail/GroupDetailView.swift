import SwiftUI
import SwiftData

struct GroupDetailView: View {
    let groupId: Int
    @State private var viewModel = GroupDetailViewModel()
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.modelContext) private var modelContext
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
                                    let urlString = cover.hasPrefix("http") ? cover : "\(APIClient.shared.serverURL)\(cover)"
                                    if let url = URL(string: urlString) {
                                        AuthenticatedImage(url: url)
                                    }
                                } else if let first = detail.comics.first {
                                    AuthenticatedImage(
                                        serverURL: APIClient.shared.serverURL,
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
                                    VolumeCardView(comic: comic, serverURL: APIClient.shared.serverURL)
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
                                    VolumeListRowView(comic: comic, serverURL: APIClient.shared.serverURL)
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
