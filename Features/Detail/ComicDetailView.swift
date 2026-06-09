import SwiftUI
import SwiftData

struct ComicDetailView: View {
    let comicId: String
    var groupContext: ReadingGroupContext? = nil
    @StateObject private var viewModel = DetailViewModel()
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var downloadManager = DownloadManager.shared

    var body: some View {
        ScrollView {
            if let comic = viewModel.comic {
                detailContent(comic: comic)
            } else if viewModel.isLoading {
                ProgressView()
                    .padding(.top, 100)
            } else if let error = viewModel.errorMessage {
                errorState(message: error) {
                    Task { await viewModel.load(id: comicId) }
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            viewModel.setModelContext(modelContext)
            downloadManager.setModelContext(modelContext)
            await viewModel.load(id: comicId)
        }
    }

    private func detailContent(comic: Comic) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            // 封面 + 信息
            HStack(alignment: .top, spacing: 16) {
                AuthenticatedImage(serverURL: APIClient.shared.serverURL, comicId: comic.id, thumbnail: true)
                    .frame(width: 130, height: 190)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.1), radius: 8, y: 4)

                VStack(alignment: .leading, spacing: 10) {
                    Text(comic.title)
                        .font(.title3.weight(.bold))
                        .lineLimit(3)

                    if let author = comic.author, !author.isEmpty {
                        Label(author, systemImage: "person")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if comic.pageCount > 0 {
                        Label("\(comic.pageCount) \(comic.isNovel ? "章" : "页")", systemImage: "doc.text")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if let size = comic.fileSize, size > 0 {
                        Label(formatFileSize(size), systemImage: "internaldrive")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if let rating = comic.rating, rating > 0 {
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

            // 操作按钮
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
                downloadButton(comic: comic)

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

            // 进度
            if comic.progress > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("阅读进度")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(comic.lastReadPage + 1)/\(comic.pageCount)\(comic.isNovel ? "章" : "页")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color(.systemGray5))
                            Capsule()
                                .fill(Color.accentColor)
                                .frame(width: geo.size.width * CGFloat(comic.progress) / 100)
                            // 百分比居中显示在进度条上
                            Text("\(comic.progress)%")
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

            // 标签
            if let tags = comic.tags, !tags.isEmpty {
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

            // 简介
            if let desc = comic.description, !desc.isEmpty {
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

            Spacer(minLength: 40)
        }
    }

    private func errorState(message: String, retry: @escaping () -> Void) -> some View {
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

    // MARK: - 下载按钮

    @ViewBuilder
    private func downloadButton(comic: Comic) -> some View {
        let task = downloadManager.task(for: comic.id)
        let isDownloaded = task?.state == .completed || downloadManager.isDownloaded(comicId: comic.id)
        let isDownloading = task?.state == .downloading || task?.state == .waiting
        let isPaused = task?.state == .paused

        if isDownloaded {
            // 已下载完成
            Button {
                // 无需操作，可考虑跳转到已下载列表
            } label: {
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
            // 下载中 — 显示进度
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
            // 已暂停
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
            // 存储空间不足
            Button {
                // 无操作，仅提示
            } label: {
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
            // 未下载
            Button {
                downloadManager.download(
                    comicId: comic.id,
                    title: comic.title,
                    pageCount: comic.pageCount,
                    fileSize: comic.fileSize
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

// MARK: - ViewModel

@MainActor
final class DetailViewModel: ObservableObject {
    @Published var comic: Comic?
    @Published var isLoading = false
    @Published var errorMessage: String?

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
