import SwiftUI

struct FavoritesView: View {
    @StateObject private var viewModel = FavoritesViewModel()
    @ObservedObject private var api = APIClient.shared

    var body: some View {
        if api.isOfflineMode {
            offlineUnavailableView
        } else {
            mainContent
        }
    }

    private var mainContent: some View {
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
                                ComicCardView(comic: comic, serverURL: APIClient.shared.serverURL)
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
        .overlay {
            if viewModel.isLoading && viewModel.comics.isEmpty {
                ProgressView()
            }
        }
    }

    private var offlineUnavailableView: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("离线模式不可用")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("收藏功能需要连接服务器")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
final class FavoritesViewModel: ObservableObject {
    @Published var comics: [Comic] = []
    @Published var isLoading = false

    func loadFavorites() async {
        guard !isLoading else { return }
        isLoading = true
        do {
            let resp = try await APIClient.shared.fetchComics(page: 1, pageSize: 50, favorites: true)
            comics = resp.comics
        } catch {
            AppLogger.error("加载收藏失败: \(error)")
        }
        isLoading = false
    }
}
