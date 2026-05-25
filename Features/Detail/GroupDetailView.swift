import SwiftUI

struct GroupDetailView: View {
    let groupId: Int
    @StateObject private var viewModel = GroupDetailViewModel()
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var isGrid = true

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
                                if let first = detail.comics.first {
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
                    if isGrid {
                        let cols = Array(repeating: GridItem(.flexible(), spacing: 12), count: sizeClass == .regular ? 5 : 3)
                        LazyVGrid(columns: cols, spacing: 16) {
                            ForEach(Array(detail.comics.enumerated()), id: \.element.id) { index, comic in
                                NavigationLink {
                                    ComicDetailView(
                                        comicId: comic.id,
                                        groupContext: ReadingGroupContext(
                                            groupId: viewModel.detail?.id ?? groupId,
                                            volumeIds: detail.comics.map { $0.id },
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
                                            volumeIds: detail.comics.map { $0.id },
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
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation { isGrid.toggle() }
                } label: {
                    Image(systemName: isGrid ? "list.bullet" : "square.grid.2x2")
                }
            }
        }
        .task {
            await viewModel.load(groupId: groupId)
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
final class GroupDetailViewModel: ObservableObject {
    @Published var detail: GroupDetailResponse?
    @Published var isLoading = false
    @Published var errorMessage: String?

    func load(groupId: Int) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            detail = try await APIClient.shared.fetchGroupDetail(id: groupId)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
