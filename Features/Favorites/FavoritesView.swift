import SwiftUI

struct FavoritesView: View {
    @State private var viewModel = FavoritesViewModel()
    @Environment(APIClient.self) private var api

    var body: some View {
        if api.isOfflineMode {
            OfflineUnavailableView(
                icon: "wifi.slash",
                title: "离线模式不可用",
                subtitle: "收藏功能需要连接服务器"
            )
        } else {
            FavoritesMainContent(viewModel: viewModel)
        }
    }
}

// MARK: - 收藏主内容

struct FavoritesMainContent: View {
    let viewModel: FavoritesViewModel
    @Environment(APIClient.self) private var api

    var body: some View {
        Group {
            if viewModel.comics.isEmpty && !viewModel.isLoading {
                VStack(spacing: 12) {
                    Image(systemName: "heart")
                        .font(.system(size: 44))
                        .foregroundStyle(.tertiary)
                    Text("还没有收藏")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("在详情页点击心形收藏喜欢的漫画")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12),
                    ], spacing: 16) {
                        ForEach(viewModel.comics) { comic in
                            NavigationLink(value: comic.id) {
                                ComicCardView(id: comic.id, title: comic.title, isFavorite: comic.isFavorite, isNovel: comic.isNovel, progress: comic.progress, serverURL: api.serverURL, readingStatus: comic.readingStatus)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .refreshable {
                    await viewModel.loadFavorites()
                }
            }
        }
        .navigationTitle("收藏")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(for: String.self) { comicId in
            ComicDetailView(comicId: comicId)
        }
        .task {
            await viewModel.loadFavorites()
        }
        .onChange(of: api.isOfflineMode) { _, isOffline in
            if isOffline {
                viewModel.comics = []
                viewModel.isLoading = false
            }
        }
        .onChange(of: api.selectedLibraryId) { _, _ in
            Task { await viewModel.loadFavorites() }
        }
        .overlay {
            if viewModel.isLoading && viewModel.comics.isEmpty {
                ProgressView()
            }
        }
    }
}

// MARK: - 离线不可用视图（复用）

struct OfflineUnavailableView: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
@Observable
final class FavoritesViewModel {
    var comics: [Comic] = []
    var isLoading = false

    func loadFavorites() async {
        // 离线或网络不可达：立即返回，不挂起等超时
        guard !APIClient.shared.isOfflineMode, APIClient.shared.isNetworkReachable else {
            comics = []
            isLoading = false
            return
        }
        guard !isLoading else { return }
        isLoading = true
        do {
            let resp = try await APIClient.shared.fetchComics(page: 1, pageSize: 50, favorites: true)
            comics = resp.comics
        } catch {
            AppLogger.error("加载收藏失败: \(error)")
            if APIClient.shared.isOfflineMode { comics = [] }
        }
        isLoading = false
    }
}
