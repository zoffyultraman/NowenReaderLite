import SwiftUI

struct ComicDetailView: View {
    let comicId: String
    var groupContext: ReadingGroupContext? = nil
    @StateObject private var viewModel = DetailViewModel()

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
                        Label("\(comic.pageCount) 页", systemImage: "doc.text")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if let size = comic.fileSize, size > 0 {
                        Label(formatFileSize(Int64(size)), systemImage: "internaldrive")
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

                // 阅读按钮
                NavigationLink {
                    readerView(for: comic)
                } label: {
                    Label(
                        comic.lastReadPage > 0 ? "继续阅读 (\(comic.lastReadPage + 1)/\(comic.pageCount))" : "开始阅读",
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
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("阅读进度")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(comic.progress)%")
                            .font(.caption.weight(.medium))
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color(.systemGray5))
                            Capsule()
                                .fill(Color.accentColor)
                                .frame(width: geo.size.width * CGFloat(comic.progress) / 100)
                        }
                    }
                    .frame(height: 6)
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

    @ViewBuilder
    private func readerView(for comic: Comic) -> some View {
        if comic.isNovel {
            NovelReaderView(comicId: comic.id, initialChapter: comic.lastReadPage, groupContext: groupContext)
        } else {
            ComicReaderView(comicId: comic.id, initialPage: comic.lastReadPage, groupContext: groupContext)
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

    func load(id: String) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            comic = try await api.fetchComic(id: id)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func toggleFavorite() async {
        guard let comic else { return }
        do {
            let resp = try await api.toggleFavorite(comicId: comic.id)
            self.comic = comic.withFavorite(resp["isFavorite"] ?? !(comic.isFavorite))
        } catch {
            AppLogger.error("收藏失败: \(error)")
        }
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
