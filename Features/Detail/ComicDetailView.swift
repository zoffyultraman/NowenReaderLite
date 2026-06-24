import SwiftUI
import SwiftData

struct ComicDetailView: View {
    let comicId: String
    var groupContext: ReadingGroupContext? = nil
    @State private var viewModel = DetailViewModel()
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        ScrollView {
            if let comic = viewModel.comic {
                ComicDetailContent(
                    comic: comic,
                    groupContext: groupContext,
                    viewModel: viewModel
                )
            } else if viewModel.isLoading {
                ProgressView()
                    .padding(.top, 100)
            } else if let error = viewModel.errorMessage {
                ErrorStateView(message: error) {
                    Task { await viewModel.load(id: comicId) }
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            viewModel.setModelContext(modelContext)
            DownloadManager.shared.setModelContext(modelContext)
            await viewModel.load(id: comicId)
        }
    }
}

// MARK: - 漫画详情内容

struct ComicDetailContent: View {
    let comic: Comic
    let groupContext: ReadingGroupContext?
    let viewModel: DetailViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ComicCoverInfoSection(
                comicId: comic.id,
                title: comic.title,
                author: comic.author,
                pageCount: comic.pageCount,
                isNovel: comic.isNovel,
                fileSize: comic.fileSize,
                rating: comic.rating
            )

            ComicActionButtonsSection(
                comic: comic,
                groupContext: groupContext,
                viewModel: viewModel
            )

            ComicProgressSection(
                progress: comic.progress,
                lastReadPage: comic.lastReadPage,
                pageCount: comic.pageCount,
                isNovel: comic.isNovel
            )

            ReadingStatusSection(
                currentStatus: comic.readingStatus,
                onSelect: { status in
                    Task { await viewModel.updateReadingStatus(status) }
                }
            )

            ComicTagsSection(tags: comic.tags)

            ComicDescriptionSection(description: comic.description)

            Spacer(minLength: 40)
        }
    }
}

// MARK: - 错误状态
// 轻量视图：retry 闭包每次 body 求值时重建，但视图简单，不会引起可见问题

struct ErrorStateView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button(action: retry) {
                Label("重试", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.bordered)
        }
        .padding(.top, 100)
    }
}

// MARK: - 简易流式布局

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: ProposedViewSize(result.sizes[index]))
        }
    }

    private func arrangeSubviews(proposal: ProposedViewSize, subviews: Subviews) -> (positions: [CGPoint], sizes: [CGSize], size: CGSize) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var sizes: [CGSize] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            sizes.append(size)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            totalHeight = max(totalHeight, y + rowHeight)
        }

        return (positions, sizes, CGSize(width: maxWidth, height: totalHeight))
    }
}

// MARK: - 封面 + 信息段落

struct ComicCoverInfoSection: View {
    let comicId: String
    let title: String
    let author: String?
    let pageCount: Int
    let isNovel: Bool
    let fileSize: Int64?
    let rating: Double?
    @Environment(APIClient.self) private var api

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            AuthenticatedImage(serverURL: api.serverURL, comicId: comicId, thumbnail: true)
                .frame(width: 130, height: 190)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.1), radius: 8, y: 4)

            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .lineLimit(3)

                if let author, !author.isEmpty {
                    Label(author, systemImage: "person")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if pageCount > 0 {
                    Label("\(pageCount) \(isNovel ? "章" : "页")", systemImage: "doc.text")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let size = fileSize, size > 0 {
                    Label(formatFileSize(size), systemImage: "internaldrive")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let rating, rating > 0 {
                    HStack(spacing: 2) {
                        ForEach(1...5, id: \.self) { i in
                            Image(systemName: i <= Int(rating) ? "star.fill" : "star")
                                .font(.caption2)
                                .foregroundStyle(.yellow)
                        }
                    }
                }

                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }
}

// MARK: - 操作按钮段落

struct ComicActionButtonsSection: View {
    let comic: Comic
    let groupContext: ReadingGroupContext?
    let viewModel: DetailViewModel

    var body: some View {
        HStack(spacing: 12) {
            // 收藏按钮
            Button {
                Task { await viewModel.toggleFavorite() }
            } label: {
                Label(
                    comic.isFavorite ? "已收藏" : "收藏",
                    systemImage: comic.isFavorite ? "heart.fill" : "heart"
                )
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(comic.isFavorite ? Color.red.opacity(0.1) : Color(.systemGray6))
                .foregroundStyle(comic.isFavorite ? .red : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            // 下载按钮
            DownloadButton(comic: comic)

            // 阅读按钮
            NavigationLink {
                comic.readerView(groupContext: groupContext)
            } label: {
                Label(
                    comic.lastReadPage > 0 ? "继续阅读" : "开始阅读",
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
        .padding(.horizontal, 20)
    }
}

// MARK: - 下载按钮

struct DownloadButton: View {
    let comic: Comic
    private let downloadManager = DownloadManager.shared

    var body: some View {
        let task = downloadManager.task(for: comic.id)
        let hasActiveTask = task != nil
        let isDownloaded = task?.state == .completed || (!hasActiveTask && downloadManager.isDownloaded(comicId: comic.id))
        let isDownloading = task?.state == .downloading || task?.state == .waiting
        let isPaused = task?.state == .paused

        if isDownloaded {
            Button {} label: {
                Label("已下载", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.green.opacity(0.1))
                    .foregroundStyle(.green)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .disabled(true)
        } else if isDownloading {
            Button {
                downloadManager.pause(comicId: comic.id)
            } label: {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("\(Int((task?.progress ?? 0) * 100))%")
                        .font(.subheadline.weight(.medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.orange.opacity(0.1))
                .foregroundStyle(.orange)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        } else if isPaused {
            Button {
                downloadManager.resume(comicId: comic.id)
            } label: {
                Label("继续", systemImage: "play.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.orange.opacity(0.1))
                    .foregroundStyle(.orange)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        } else if downloadManager.wouldExceedLimit(pageCount: comic.pageCount) {
            Button {} label: {
                Label("空间不足", systemImage: "exclamationmark.circle")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.orange.opacity(0.1))
                    .foregroundStyle(.orange)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .disabled(true)
        } else {
            Button {
                downloadManager.download(
                    comicId: comic.id,
                    title: comic.title,
                    pageCount: comic.pageCount,
                    fileSize: comic.fileSize,
                    isNovel: comic.isNovel
                )
            } label: {
                Label("下载", systemImage: "arrow.down.circle")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color(.systemGray6))
                    .foregroundStyle(.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

// MARK: - 进度段落

struct ComicProgressSection: View {
    let progress: Int
    let lastReadPage: Int
    let pageCount: Int
    let isNovel: Bool

    var body: some View {
        if progress > 0 {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("阅读进度")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(lastReadPage + 1)/\(pageCount)\(isNovel ? "章" : "页")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color(.systemGray5))
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: geo.size.width * CGFloat(progress) / 100)
                        Text("\(progress)%")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.3), radius: 1)
                            .frame(width: geo.size.width, height: 14)
                    }
                }
                .frame(height: 14)
            }
            .padding(.horizontal, 20)
        }
    }
}

// MARK: - 阅读状态

struct ReadingStatusSection: View {
    let currentStatus: String?
    let onSelect: (String?) -> Void

    private let statuses: [(key: String, label: String, icon: String)] = [
        ("want", "想看", "heart"),
        ("reading", "在读", "book.fill"),
        ("finished", "已读", "checkmark.circle.fill"),
        ("shelved", "搁置", "archivebox"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("阅读状态")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(statuses, id: \.key) { status in
                        let isSelected = currentStatus == status.key
                        Button {
                            onSelect(isSelected ? nil : status.key)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: status.icon)
                                    .font(.system(size: 11))
                                Text(status.label)
                                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                            }
                            .foregroundStyle(isSelected ? .white : .primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(isSelected ? Color.accentColor : Color(.systemGray6))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - 标签段落

struct ComicTagsSection: View {
    let tags: [TagItem]?

    var body: some View {
        if let tags, !tags.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("标签")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                FlowLayout(spacing: 8) {
                    ForEach(tags, id: \.name) { tag in
                        Text(tag.name)
                            .font(.caption2)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.accentColor.opacity(0.1))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }
}

// MARK: - 简介段落

struct ComicDescriptionSection: View {
    let description: String?

    var body: some View {
        if let desc = description, !desc.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("简介")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(desc)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
        }
    }
}

// MARK: - ViewModel

@MainActor
@Observable
final class DetailViewModel {
    var comic: Comic?
    var isLoading = false
    var errorMessage: String?

    private let api = APIClient.shared
    private var modelContext: ModelContext?

    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }

    func load(id: String) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            comic = try await api.fetchComic(id: id)
        } catch {
            // 离线 fallback：从本地已下载数据构造 Comic
            if let meta = OfflineFileManager.shared.loadMeta(comicId: id) {
                comic = Comic(
                    id: meta.comicId,
                    title: meta.title,
                    author: nil,
                    publisher: nil,
                    description: nil,
                    genre: nil,
                    language: nil,
                    year: nil,
                    pageCount: meta.pageCount,
                    fileSize: meta.fileSize,
                    lastReadPage: 0,
                    totalReadTime: nil,
                    readingStatus: nil,
                    lastReadAt: nil,
                    metadataSource: nil,
                    coverUrl: nil,
                    coverAspectRatio: nil,
                    rating: nil,
                    isFavorite: false,
                    type: "comic",
                    filename: nil,
                    sortOrder: nil,
                    tags: nil,
                    categories: nil
                )
            } else {
                errorMessage = error.localizedDescription
            }
        }
        isLoading = false
    }

    func toggleFavorite() async {
        guard let comic else { return }
        do {
            let resp = try await api.toggleFavorite(comicId: comic.id)
            let newFav = resp["isFavorite"] ?? !(comic.isFavorite)
            self.comic = comic.withFavorite(newFav)
            // 同步到本地缓存
            syncFavoriteToCache(comicId: comic.id, isFavorite: newFav)
        } catch {
            AppLogger.error("收藏失败: \(error)")
        }
    }

    func updateReadingStatus(_ status: String?) async {
        guard let comic else { return }
        do {
            try await api.updateReadingStatus(comicId: comic.id, status: status ?? "")
            self.comic = comic.withReadingStatus(status)
            syncReadingStatusToCache(comicId: comic.id, status: status)
        } catch {
            AppLogger.error("更新阅读状态失败: \(error)")
        }
    }

    private func syncReadingStatusToCache(comicId: String, status: String?) {
        guard let context = modelContext else { return }
        let id = comicId
        let descriptor = FetchDescriptor<CachedComic>(predicate: #Predicate { $0.id == id })
        guard let first = context.fetchOrLog(descriptor, label: "同步阅读状态").first else { return }
        first.readingStatus = status
        context.saveOrLog()
    }

    private func syncFavoriteToCache(comicId: String, isFavorite: Bool) {
        guard let context = modelContext else { return }
        let id = comicId
        let descriptor = FetchDescriptor<CachedComic>(predicate: #Predicate { $0.id == id })
        guard let first = context.fetchOrLog(descriptor, label: "同步收藏状态").first else { return }
        first.isFavorite = isFavorite
        context.saveOrLog()
    }
}

extension Comic {
    func withReadingStatus(_ status: String?) -> Comic {
        Comic(
            id: id, title: title, author: author, publisher: publisher,
            description: description, genre: genre, language: language,
            year: year, pageCount: pageCount, fileSize: fileSize,
            lastReadPage: lastReadPage, totalReadTime: totalReadTime,
            readingStatus: status, lastReadAt: lastReadAt,
            metadataSource: metadataSource, coverUrl: coverUrl,
            coverAspectRatio: coverAspectRatio, rating: rating,
            isFavorite: isFavorite, type: type, filename: filename,
            sortOrder: sortOrder, tags: tags, categories: categories
        )
    }

    func withFavorite(_ fav: Bool) -> Comic {
        Comic(
            id: id, title: title, author: author, publisher: publisher,
            description: description, genre: genre, language: language,
            year: year, pageCount: pageCount, fileSize: fileSize,
            lastReadPage: lastReadPage, totalReadTime: totalReadTime,
            readingStatus: readingStatus, lastReadAt: lastReadAt,
            metadataSource: metadataSource, coverUrl: coverUrl,
            coverAspectRatio: coverAspectRatio, rating: rating,
            isFavorite: fav, type: type, filename: filename,
            sortOrder: sortOrder, tags: tags, categories: categories
        )
    }
}
